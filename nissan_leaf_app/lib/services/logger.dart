class MyLogger {
  static final List<String> _logs = [];

  // Add a log message
  static void log(String message) {
    _logs.add(message);
  }

  // Get all logs (for UI display)
  static List<String> get logs => _logs;
}
