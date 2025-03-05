// lib/main.dart (updated version)
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:nissan_leaf_app/components/mqtt_settings_widget.dart';
import 'package:simple_logger/simple_logger.dart';
import 'dart:async';

import 'pages/web_home_page.dart';
import 'pages/connection_page.dart';
import 'pages/dashboard_page.dart';
import 'components/log_viewer.dart';
import 'obd/bluetooth_device_manager.dart';
import 'background_service.dart';

// Global logger instance
final _log = SimpleLogger();

void main() {
  _log.onLogged = (log, info) {
    // Capture logs for UI here
    LogViewer.log(log.replaceAll(RegExp(r'\[caller info not available\] '), ''));
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
      home: kIsWeb ? const WebHomePage() : const MainScreen(),
      routes: {
        '/connection': (context) => const ConnectionPage(),
        '/connection_config': (context) => const ConnectionPage(forConfiguration: true),
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
  final _deviceManager = BluetoothDeviceManager.instance;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Initialize the device manager
    await _deviceManager.initialize();

    // Initialize the background service
    await BackgroundService.initialize();

    // Check if service was enabled previously
    if (await BackgroundService.isServiceEnabled()) {
      await BackgroundService.startService();
    }

    // Try to reconnect to the last device
    await _deviceManager.reconnectToSavedDevice();

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
    return const DashboardPage();
  }
}
