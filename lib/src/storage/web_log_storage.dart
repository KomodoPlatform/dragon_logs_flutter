import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart';

import 'package:dragon_logs/src/storage/input_output_mixin.dart';
import 'package:dragon_logs/src/storage/log_storage.dart';
import 'package:dragon_logs/src/storage/queue_mixin.dart';

class WebLogStorage
    with QueueMixin, CommonLogStorageOperations
    implements LogStorage {
  // TODO: Multi-day support
  // final List<FileSystemFileHandle> _logHandles = [];
  FileSystemDirectoryHandle? _logDirectory;
  FileSystemDirectoryReader? _logDirectoryReader;
  FileSystemWritableFileStream? _currentLogStream;
  String _currentLogFileName = "";

  late Timer _flushTimer;

  late final StorageManager? storage;

  @override
  Future<void> init() async {
    storage = window.navigator.storage;

    final now = DateTime.now();
    _currentLogFileName = logFileNameOfDate(now);

    FileSystemDirectoryHandle? root;

    if (storage == null) {
      throw Exception("Could not get storage manager");
    }
    try {
      root = await storage!.getDirectory().toDart;
    } catch (e) {
      throw Exception("Error getting directory handle: $e");
    }

    try {
      _logDirectory = await root
          .getDirectoryHandle(
            "dragon_logs",
            FileSystemGetDirectoryOptions(create: true),
          )
          .toDart;
    } catch (e) {
      throw Exception("Error getting directory handle");
    }

    // // Call the JS method to get the directory reader
    // _logDirectoryReader =

    await initWriteDate(now);

    initQueueFlusher();
  }

  @override
  Future<void> writeToTextFile(String logs) async {
    if (_currentLogStream == null) {
      await initWriteDate(DateTime.now());
    }

    try {
      String content = logs + '\n';
      await _currentLogStream!.write(content.toJS).toDart;

      await closeLogFile();
      await initWriteDate(DateTime.now());
    } catch (e) {
      rethrow;
    }
  }

  @override
  // TODO: implement so that we don't have to delete the whole file
  @override
  Future<void> deleteOldLogs(int size) async {
    if (_logDirectory == null) return;

    await startFlush();

    try {
      while (await getLogFolderSize() > size) {
        final files = await _getLogFiles();

        final sortedFiles = files
            .where(
              (handle) =>
                  CommonLogStorageOperations.isLogFileNameValid(handle.name),
            )
            .toList()
          ..sort((a, b) {
            final aDate =
                CommonLogStorageOperations.tryParseLogFileDate(a.name);
            final bDate =
                CommonLogStorageOperations.tryParseLogFileDate(b.name);

            if (aDate == null || bDate == null) {
              return 0;
            }

            return aDate.compareTo(bDate);
          });

        if (sortedFiles.isNotEmpty) {
          await sortedFiles.first.getFile().toDart.then((file) async {
            // TODO: Implement file.remove
            // await file.remove().toDart;
          });
        }
      }
    } catch (e) {
      rethrow;
    } finally {
      endFlush();
    }
  }

  Future<void> initWriteDate(DateTime date) async {
    await closeLogFile(); // Ensure any previous log file is closed

    _currentLogFileName = logFileNameOfDate(date);

    if (_logDirectory == null) return;

    FileSystemFileHandle _currentLogFile;
    try {
      // Get the file handle, create the file if it doesn't exist
      _currentLogFile = await _logDirectory!
          .getFileHandle(
            _currentLogFileName,
            FileSystemGetFileOptions(create: true),
          )
          .toDart;
    } catch (e) {
      throw Exception("Error getting file handle: $e");
    }

    try {
      // Open a writable stream for the file, allowing for data to be appended
      _currentLogStream = await _currentLogFile
          .createWritable(
            FileSystemCreateWritableOptions(keepExistingData: true),
          )
          .toDart;
    } catch (e) {
      throw Exception("Error creating writable file stream: $e");
    }

    if (_currentLogStream == null) return;

    // Move the write pointer to the end of the file
    int sizeBytes = 0;
    try {
      final file = await _currentLogFile.getFile().toDart;
      sizeBytes = file.size; // Get the size of the file in bytes
    } catch (e) {
      throw Exception("Error getting file size: $e");
    }

    try {
      // Seek to the end of the file to append data
      await _currentLogStream!.seek(sizeBytes).toDart;
    } catch (e) {
      throw Exception("Error seeking file stream: $e");
    }
  }

  @override
  Future<int> getLogFolderSize() async {
    final files = await _getLogFiles();

    final htmlFileObjects = await Future.wait<File>(
      files.map((e) => e.getFile().toDart),
    );

    final int totalSize = htmlFileObjects.fold(
      0,
      (int? previousValue, File file) => (previousValue ?? 0) + file.size,
    );

    return totalSize;
  }

  //TODO! Move to web worker for web so we can access sync flush method instead
  // of this workaround
  @override
  Future<void> closeLogFile() async {
    if (_currentLogStream != null) {
      await _currentLogStream!.close().toDart;
      _currentLogStream = null;
    }
  }

  @override
  Stream<String> exportLogsStream() async* {
    for (final file in await _getLogFiles()) {
      String content = await _readFileContent(
        await file.getFile().toDart,
      );
      yield content;
    }
  }

  /// Returns a list of OPFS file handles for all log files EXCLUDING any
  /// temporary write file (if it exists) identified by the `.crswap` extension.
  Future<List<FileSystemFileHandle>> _getLogFiles() async {
    final List<FileSystemFileHandle> logFiles = [];

    if (_logDirectory == null) {
      throw Exception("Log directory is not initialized");
    }

    // Retrieve the entries iterator from the directory
    final entriesAsyncIterator =
        _logDirectory!.callMethod<JSObject>('entries'.toJS);

    final entriesCompleter = Completer<void>();

    try {
      // Loop over the iterator asynchronously to process the entries
      while (true) {
        final result = await entriesAsyncIterator
            .callMethod<JSPromise>('next'.toJS)
            .toDart as JSObject;

        final done = result.getProperty('done'.toJS) as bool;
        final value = result.getProperty('value'.toJS) as List?;

        // If the iteration is done, break the loop
        if (done) {
          break;
        }

        // Get the key and value from the iterator result (value is the [key, entry] pair)
        final entry = value?[1];

        // Check if the entry is a file and not a temporary file
        if (entry is FileSystemFileHandle && !entry.name.endsWith('.crswap')) {
          logFiles.add(entry);
        }
      }

      // Mark the completer as complete when done
      if (!entriesCompleter.isCompleted) {
        entriesCompleter.complete();
      }
    } catch (e) {
      if (!entriesCompleter.isCompleted) {
        entriesCompleter.completeError(
          Exception("Error reading log directory entries: $e"),
        );
      }
    }

    // Wait for the completion of the directory read before returning the list
    await entriesCompleter.future;

    // Sort files by their names
    logFiles.sort((a, b) => a.name.compareTo(b.name));

    print("Log files: ${logFiles.map((e) => e.name)}");

    return logFiles;
  }

  Future<String> _readFileContent(File file) async {
    final completer = Completer<String>();
    final reader = FileReader();

    try {
      // Read the file content as text
      reader.readAsText(file);

      // Listen for the load end event to complete the completer
      reader.onLoadEnd.listen((event) {
        if (reader.error == null) {
          completer.complete(reader.result as String);
        } else {
          completer.completeError(reader.error!);
        }
      });
    } catch (e) {
      // Handle any synchronous errors that may occur
      completer.completeError(Exception("Error reading file: $e"));
    }

    return completer.future;
  }

  @override
  Future<void> deleteExportedFiles() async {
    // Since it's a web implementation, we just need to ensure necessary permissions.
    // Note: Real-world applications should handle permissions gracefully, prompting users as needed.
  }

  @override
  // TODO: Multi-threading support in web worker
  Future<void> exportLogsToDownload() async {
    final bytesStream = exportLogsStream().asyncExpand((event) {
      return Stream.fromIterable(event.codeUnits);
    });

    final formatter = DateFormat('yyyyMMdd_HHmmss');
    final filename = 'log_${formatter.format(DateTime.now())}.txt';

    List<int> bytes = await bytesStream.toList();
    // final blob = Blob(Uint8List.fromList(bytes).);
    final url = Uri.dataFromBytes(Uint8List.fromList(bytes));
    // ignore: unused_local_variable
    // Download the file

    final anchor = HTMLAnchorElement()
      ..href = url.toString()
      ..target = 'blank'
      ..download = filename
      ..click();

    anchor.remove();
  }

  void dispose() async {
    _flushTimer?.cancel(); // Safeguard for null timer
    await closeLogFile(); // Close the log file once during the dispose method
  }
}

//TODO!
Future<void> flushInWebWorker() async {
  // final logStorage = WebLogStorage();
  // await logStorage.init();
  // await logStorage.flushLogQueue();
}
