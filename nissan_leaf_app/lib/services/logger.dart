class Logger {
  static final Logger _instance = Logger._internal();
  final List<String> _logs = [];

  // Private constructor
  Logger._internal();

  // Singleton instance
  static Logger get instance => _instance;

  // Add a log message
  void log(String message) {
    _logs.add(message);
  }

  // Get all logs (for UI display)
  List<String> get logs => _logs;
}
