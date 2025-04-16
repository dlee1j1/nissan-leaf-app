// lib/main.dart (updated version)
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:nissan_leaf_app/components/mqtt_settings_widget.dart';
import 'package:simple_logger/simple_logger.dart';
import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'pages/connection_page.dart';
import 'pages/dashboard_page.dart';
import 'components/log_viewer.dart';
import 'background_service_controller.dart';

// Global logger instance
final _log = SimpleLogger();

void main() {
  // This needs to be called before anything else
  WidgetsFlutterBinding.ensureInitialized();

  _log.onLogged = (log, info) {
    // Capture logs for UI here
    LogViewer.log(log);
  };

  runZonedGuarded(
    () {
      runApp(const NissanLeafApp());
    },
    (error, stack) {
      _log.severe('Error: $error\n$stack');
    },
  );
}

class NissanLeafApp extends StatelessWidget {
  const NissanLeafApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nissan Leaf Battery Tracker',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      themeMode: ThemeMode.system,
      home: const MainScreen(),
      routes: {
        '/connection': (context) => const ConnectionPage(),
        '/dashboard': (context) => const DashboardPage(),
        '/mqtt_settings': (context) => Scaffold(
              appBar: AppBar(title: const Text('MQTT Settings')),
              body: SingleChildScrollView(child: MqttSettingsWidget()),
            ),
        '/obd_test': (context) => const ConnectionPage(), // Redirects to the new connection page
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();

    // Then mark as ready to start after the first frame is rendered
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeApp();
    });
  }

  Future<void> _initializeApp() async {
    // Check if service was enabled previously
    if (!kIsWeb) {
      try {
        await BackgroundServiceController.initialize();
        // Initialize the communication port for foreground task
        FlutterForegroundTask.initCommunicationPort();
        await BackgroundServiceController.startService();

        // Set up service health check to run every 30 minutes
        BackgroundServiceController.setupServiceHealthCheck(
            checkInterval: const Duration(minutes: 30));
      } catch (e) {
        _log.severe('Error during app initialization: $e');
        // Continue app startup even if background service fails
      }
    }

    setState(() {
      _isInitializing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Initializing...'),
            ],
          ),
        ),
      );
    }

    // Once initialized, show the dashboard
    return WithForegroundTask(
      child: const DashboardPage(),
    );
  }
}
