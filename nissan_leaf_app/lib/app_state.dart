import 'package:simple_logger/simple_logger.dart';

/// Global application state for the Nissan Leaf Battery Tracker
///
/// Provides centralized state management for app-wide settings
/// such as mock mode that affect multiple components
class AppState {
  // Singleton pattern
  static final AppState _instance = AppState._internal();
  static AppState get instance => _instance;
  AppState._internal();

  final _log = SimpleLogger();

  // Mock mode flag
  bool _mockMode = false;
  bool get mockMode => _mockMode;

  // Enable mock mode for the entire app
  void enableMockMode() {
    _mockMode = true;
    _log.info('App-wide mock mode enabled');
  }

  // Disable mock mode for the entire app
  void disableMockMode() {
    _mockMode = false;
    _log.info('App-wide mock mode disabled');
  }

  // Toggle mock mode
  void toggleMockMode() {
    _mockMode = !_mockMode;
    _log.info('App-wide mock mode ${_mockMode ? "enabled" : "disabled"}');
  }
}
