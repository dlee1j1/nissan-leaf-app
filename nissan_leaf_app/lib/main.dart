import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:simple_logger/simple_logger.dart';
import 'dart:async';

import 'web_home_page.dart';
import 'ble_scan_page.dart';
import 'obd_test_page.dart';
import 'components/log_viewer.dart';
import 'components/dashboard_page.dart';
import 'obd/obd_command.dart';
import 'obd/obd_controller.dart';

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

  final commands = OBDCommand.getAllCommands();
  _log.info('There are ${commands.length} commands');
  _log.info(
      'Registered commands before panel: ${OBDCommand.lbc.name}'); // Force static initialization
  _log.info('Available commands: ${OBDCommand.getAllCommands().length}');
}

class NissanLeafApp extends StatelessWidget {
  const NissanLeafApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nissan Leaf OBD',
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
      home: kIsWeb ? const WebHomePage() : const BleScanPage(), // Use different home page for web
      routes: {
        '/obd_test': (context) => const ObdTestPage(),
        '/dashboard': (context) {
          // Get the controller from the arguments if available
          final args = ModalRoute.of(context)?.settings.arguments;
          ObdController? controller;
          if (args is ObdController) {
            controller = args;
          }
          return DashboardPage(obdController: controller);
        },
      },
    );
  }
}
