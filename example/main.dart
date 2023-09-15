import 'package:flutter/material.dart';
import 'package:stored_logs/src/logger/logger.dart';
import 'package:stored_logs/stored_logs.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  final logStorage = LogStorage()..init();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () {
              final timer = Stopwatch()..start();
              for (var i = 0; i < 100000; i++) sLog('This is a log');
              timer.stop();

              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      'Logged 100k items in ${timer.elapsedMilliseconds}ms')));

              timer.reset();
            },
            child: Text('Log 100k items'),
          ),
          TextButton(
            onPressed: () {
              // StoredLogs.clear();
              final timer = Stopwatch()..start();

              final string = logStorage
                  .exportLogsStringBuffer()
                  .asyncMap((event) => event)
                  .join('\n');

              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content:
                      Text('Read logs in ${timer.elapsedMilliseconds}ms')));

              print('Read logs in ${timer.elapsedMilliseconds}ms');
            },
            child: Text('Read logs'),
          ),
        ],
      ),
    );
  }
}
