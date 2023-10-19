import 'dart:async';
import 'dart:html' as html;
import 'dart:html';
import 'dart:typed_data';

import 'package:dragon_logs/src/storage/log_storage.dart';
import 'package:dragon_logs/src/storage/queue_mixin.dart';
import 'package:file_system_access_api/file_system_access_api.dart';
import 'package:intl/intl.dart';
import 'package:js/js.dart';
import 'package:js/js_util.dart' as js;

/// Declare navigator like in a Web Worker context.
@JS()
external dynamic get navigator;

class WebLogStorage with QueueMixin implements LogStorage {
  // final List<FileSystemFileHandle> _logHandles = [];
  FileSystemDirectoryHandle? _logDirectory;

  // TODO: Multi-day support
  FileSystemFileHandle? _currentLogFile;
  FileSystemWritableFileStream? _currentLogStream;
  String _currentLogFileName = "";

  late Timer _flushTimer;

  late final StorageManager? storage =
      js.getProperty(navigator, "storage") as StorageManager?;

  @override
  Future<void> init() async {
    final now = DateTime.now();
    _currentLogFileName = logDayFileName(now);

    FileSystemDirectoryHandle? root = await storage?.getDirectory();

    if (root != null) {
      _logDirectory =
          await root.getDirectoryHandle("dragon_logs", create: true);

      // await initWriteDate(now);
    } else {
      throw Exception("Could not get root directory");
    }

    initQueueFlusher();
  }

  @override
  Future<void> writeToTextFile(String logs) async {
    if (_currentLogStream == null) {
      await initWriteDate(DateTime.now());
    }

    try {
      await _currentLogStream!.writeAsText(logs + '\n');

      await closeLogFile();
      await initWriteDate(DateTime.now());
    } catch (e) {
      enqueue(logs);
      rethrow;
    }
  }

  @override
  // TODO: implement so that we don't have to delete the whole file
  Future<void> deleteOldLogs(int sizeMb) async {
    while (await getLogFolderSize() > sizeMb * 1024 * 1024) {
      final files = await _getLogFiles();

      final sortedFiles = files.toList()
        ..sort((a, b) {
          // Extract date from name in format yyyy-mm-dd.txt
          final reg = RegExp(r'(\d{4}-\d{2}-\d{2})');

          final aDate = reg.firstMatch(a.name)?.group(1);
          final bDate = reg.firstMatch(b.name)?.group(1);

          if (aDate == null || bDate == null) {
            return 0;
          }

          return aDate.compareTo(bDate);
        });
      await sortedFiles.first.remove();
    }
  }

  Future<void> initWriteDate(DateTime date) async {
    await closeLogFile();

    _currentLogFileName = logDayFileName(date);

    _currentLogFile ??= await _logDirectory?.getFileHandle(
      _currentLogFileName,
      create: true,
    );

    final sizeBytes = (await _currentLogFile?.getFile())?.size ?? 0;

    _currentLogStream = await _currentLogFile?.createWritable(
      keepExistingData: true,
    );

    await _currentLogStream?.seek(sizeBytes);
  }

  @override
  Future<int> getLogFolderSize() async {
    final files = await _getLogFiles();

    final htmlFileObjects =
        await Future.wait<File>(files.map((e) => e.getFile()));

    final int totalSize = htmlFileObjects.fold(
      0,
      (int? previousValue, File file) => (previousValue ?? 0) + file.size,
    );

    return totalSize;
  }

  String logDayFileName(DateTime date) {
    return "${date.year}-${date.month}-${date.day}.txt";
  }

  Future<FileSystemWritableFileStream> _getLogStream(DateTime date) async {
    String fileName = logDayFileName(date);
    FileSystemFileHandle handle =
        await _logDirectory!.getFileHandle(fileName, create: true);

    // _logHandles.add(handle);
    final writable = await handle.createWritable(keepExistingData: true);

    return writable;
  }

  @override
  Future<void> appendLog(DateTime date, String text) async {
    String logEntry = '${date.toIso8601String()}: $text\n';
    enqueue(logEntry);
  }

  //TODO! Move to web worker for web so we can access sync flush method instead
  // of this workaround
  @override
  Future<void> closeLogFile() async {
    if (_currentLogStream != null) {
      // await _currentLogStream?.flush();
      await _currentLogStream!.close();

      await _currentLogStream!.abort();

      _currentLogStream = null;
    }
  }

  @override
  Stream<String> exportLogsStream() async* {
    for (final file in await _getLogFiles()) {
      String content = await _readFileContent(await file.getFile());
      yield content;
    }
  }

  /// Returns a list of OPFS file handles for all log files EXCLUDING any
  /// temporary write file (if it exists) identified by the `.crswap` extension.
  Future<List<FileSystemFileHandle>> _getLogFiles() async {
    final files = await _logDirectory?.values
            .where((handle) => handle.kind == FileSystemKind.file)
            .cast<FileSystemFileHandle>()
            .where((handle) => !handle.name.endsWith('.crswap'))
            // .asyncMap((handle) => handle.getFile())
            .toList() ??
        [];

    print('_getLogFiles: ${files.map((e) => e.name).join(',\n')}');

    return files;
  }

  Future<String> _readFileContent(html.File file) async {
    final completer = Completer<String>();
    final reader = html.FileReader();

    StreamSubscription? loadEndSubscription;
    StreamSubscription? errorSubscription;

    loadEndSubscription = reader.onLoadEnd.listen((event) {
      completer.complete(reader.result as String);
    });

    errorSubscription = reader.onError.listen((error) {
      completer.completeError("Error reading file: $error");
    });

    reader.readAsText(file);

    return completer.future.whenComplete(() {
      loadEndSubscription?.cancel();
      errorSubscription?.cancel();
    });
  }

  @override
  Future<void> deleteExportedArchives() async {
    // Since it's a web implementation, we just need to ensure necessary permissions.
    // Note: Real-world applications should handle permissions gracefully, prompting users as needed.
  }

  @override
  Future<void> exportLogsToDownload() async {
    final bytesStream = exportLogsStream().asyncExpand((event) {
      return Stream.fromIterable(event.codeUnits);
    });

    final formatter = DateFormat('yyyyMMdd_HHmmss');
    final filename = 'log_${formatter.format(DateTime.now())}.txt';

    List<int> bytes = await bytesStream.toList();
    final blob = html.Blob([Uint8List.fromList(bytes)]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    // ignore: unused_local_variable
    final anchor = html.AnchorElement(href: url)
      ..target = 'blank'
      ..download = filename
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  void dispose() async {
    _flushTimer.cancel();
    await closeLogFile(); // Close the log file once during the dispose method
  }
}

//TODO!
Future<void> flushInWebWorker() async {
  // final logStorage = WebLogStorage();
  // await logStorage.init();
  // await logStorage.flushLogQueue();
}
