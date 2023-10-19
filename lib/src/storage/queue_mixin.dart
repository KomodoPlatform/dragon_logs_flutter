import 'dart:async';

mixin QueueMixin {
  final _logQueue = <String>[];
  Completer<void>? _flushCompleter;
  bool _isQueueEnabled = false;

  void initQueueFlusher() {
    if (_isQueueEnabled) return;

    _isQueueEnabled = true;

    scheduleMicrotask(() async {
      while (_isQueueEnabled) {
        await Future.delayed(const Duration(seconds: 5));
        await flushQueue();
      }
    });
  }

  bool get isFlushing => _flushCompleter != null;

  void enqueue(String log) {
    _logQueue.add(log);
  }

  Future<void> startFlush() async {
    assert(_flushCompleter == null, 'Flush already in progress');

    while (isFlushing) {
      await (_flushCompleter?.future ?? Future.delayed(Duration(seconds: 1)));
    }

    _flushCompleter ??= Completer<void>();
  }

  void endFlush() {
    _flushCompleter?.complete();
    _flushCompleter = null;
  }

  Future<void> flushQueue() async {
    if (_logQueue.isEmpty) return;

    startFlush();
    final logs = StringBuffer();

    logs.writeAll(_logQueue, '\n');

    await writeToTextFile('\n' + logs.toString() + '\n');
    endFlush();
  }

  /// Writes a String to the log text file for today.
  Future<void> writeToTextFile(String logs);
}
