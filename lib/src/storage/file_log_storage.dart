import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

// import 'package:archive/archive.dart';
import 'package:dragon_logs/src/storage/log_storage.dart';
import 'package:dragon_logs/src/storage/queue_mixin.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class FileLogStorage with QueueMixin implements LogStorage {
  FileLogStorage._internal();

  static final FileLogStorage _instance = FileLogStorage._internal();

  factory FileLogStorage() {
    return _instance;
  }

  IOSink? _logFileSink;
  File? _currentFile;
  String? _logFolderPath;
  bool _isInitialized = false;

  @override
  Future<void> init() async {
    _logFolderPath = await getLogFolderPath();
    _isInitialized = true;

    initQueueFlusher();
  }

  @override
  Future<void> writeToTextFile(String logs, {bool batchWrite = true}) async {
    if (!_isInitialized) {
      throw Exception("FileLogStorage has not been initialized.");
    }

    final now = DateTime.now();

    // On some platforms, it appears that this doesn't make a difference as the
    // OS writes the appended data in batches anyway.
    if (batchWrite) return _writeTextToFile(now, logs);

    // Split logs by newline and process each line individually
    final logEntries = logs.split('\n');
    for (final logEntry in logEntries) {
      if (logEntry.trim().isNotEmpty) {
        await _writeTextToFile(now, logEntry);
      }
    }
  }

  Future<void> _writeTextToFile(DateTime logFileDay, String text) async {
    final file = await getLogFile(logFileDay);

    if (_currentFile?.path != file.path || _logFileSink == null) {
      if (_logFileSink != null) {
        await closeLogFile();
      }

      _currentFile =
          !file.existsSync() ? await file.create(recursive: true) : file;
      _logFileSink = file.openWrite(mode: FileMode.append);
    }

    _logFileSink!.writeln(text);
  }

  @override
  Future<void> appendLog(DateTime date, String text) async {
    enqueue(text);
  }

  @override
  Future<void> deleteOldLogs(int size) async {
    while (await getLogFolderSize() > size) {
      final files = await getLogFiles();
      final sortedFiles = files.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      await sortedFiles.first.value.delete();
    }
  }

  @override
  Future<int> getLogFolderSize() async {
    final files = await getLogFiles();
    int totalSize = 0;

    for (final file in files.values) {
      final stats = file.statSync();
      totalSize += stats.size;
    }

    return totalSize;
  }

  @override
  Stream<String> exportLogsStream() async* {
    final files = await getLogFiles();

    for (final file in files.values) {
      final stats = file.statSync();
      final sizeKb = stats.size / 1024;
      print("File ${file.path} size: $sizeKb KB");

      final fileContents = file.openRead().transform<String>(utf8.decoder);
      yield* fileContents;
    }

    return;
  }

  @override
  Future<void> closeLogFile() async {
    if (_logFileSink == null || !(_currentFile?.existsSync() ?? false)) return;

    await _logFileSink?.flush();
    await _logFileSink?.close();
    _logFileSink = null;
    _currentFile = null;
  }

  @override
  Future<void> deleteExportedArchives() async {
    final archives = Directory(_logFolderPath!)
        .listSync(followLinks: false, recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.g.zip'))
        .toList();

    for (var archive in archives) {
      await archive.delete();
    }
  }

  Future<File> getLogFile(DateTime date) async {
    final path = getLogFileName(date);
    return File('$logFolderPath/$path');
  }

  // TODO? Move to shared code to get file name?
  String getLogFileName(DateTime date) {
    return '${date.year}-${date.month}-${date.day}.log';
  }

  Future<LinkedHashMap<DateTime, File>> getLogFiles() async {
    try {
      return await compute(_getLogsInIsolate, {
        'logFolderPath': _instance.logFolderPath,
      });
    } catch (e) {
      rethrow;
    }
  }

  static Future<LinkedHashMap<DateTime, File>> _getLogsInIsolate(
    Map<String, dynamic> params,
  ) async {
    final logPath = params['logFolderPath'] as String;
    final logDirectory = Directory(logPath);
    final logFilesMap = <DateTime, File>{} as LinkedHashMap<DateTime, File>;

    if (!logDirectory.existsSync()) {
      return logFilesMap;
    }

    final logFiles = logDirectory
        .listSync(followLinks: false, recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList();

    for (final logFile in logFiles) {
      final date = DateTime.tryParse(
        p.basenameWithoutExtension(logFile.path),
      );

      if (date != null) {
        logFilesMap.addAll({date: logFile});
      } else {
        final errorString = 'Error parsing log file date: ${logFile.path}';
        throw Exception(errorString);
      }
    }

    return logFilesMap;
  }

  String get logFolderPath {
    assert(_isInitialized, 'LogStorage must be initialized first');
    return _logFolderPath!;
  }

  @override
  Future<void> exportLogsToDownload() async {
    final stream = exportLogsStream();

    final formatter = DateFormat('yyyyMMdd_HHmmss');
    final filename = 'log_${formatter.format(DateTime.now())}.txt';
    final dir = await getApplicationCacheDirectory();
    final downloadFolder = '${dir.path}/dragon_logs_export/';
    final folder = Directory(downloadFolder);

    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    final logFilePath = '$downloadFolder$filename';
    final logFile = File(logFilePath);
    final raf = logFile.openSync(mode: FileMode.writeOnly);

    await for (final data in stream) {
      raf.writeStringSync(data);
    }

    await raf.close();

    // Use share_plus to share the log file
    await Share.shareXFiles(
      [XFile(logFilePath, mimeType: 'text/plain')],
      text: 'App log file export',
    );
  }

  static Future<String> getLogFolderPath() async {
    if (_instance._logFolderPath != null) return _instance._logFolderPath!;

    final documentsDirectory = await getApplicationDocumentsDirectory();
    return '${documentsDirectory.path}/dragon_logs';
  }
}
