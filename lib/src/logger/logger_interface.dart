import 'package:intl/intl.dart';

abstract class LoggerInterface {
  void log(String key, String message, {Map<String, dynamic>? metadata});

  Future<void> init();

  Stream<String> exportLogsStream();

  // Future<void> appendRawLog(String message);

  String formatMessage(
    String key,
    String message,
    DateTime date, {
    Map<String, dynamic>? metadata,
    Duration? appRunDuration,
  }) {
    final formattedMetadata = metadata == null || metadata.isEmpty
        ? ''
        : '__metadata: ${metadata.toString()}';
    final appRunDurationString =
        appRunDuration == null ? null : 'T+:$appRunDuration';
    final dateString = DateFormat('HH:mm:ss.SSS').format(date);
    return '$dateString$appRunDurationString [$key] $message$formattedMetadata';
  }
}
