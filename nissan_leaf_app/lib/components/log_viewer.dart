import 'package:flutter/material.dart';

//
class LogViewer extends StatelessWidget {
  static final List<String> _logs = [];

  // Add a log message
  static void log(String message) {
    _logs.add(message.replaceAll(RegExp(r'\[caller info not available\] '), ''));
  }

  static void addLogFromService(String message) {
    // Add "[Service]" prefix to distinguish service logs
    log("[Service] $message");
  }

  static void clearLogs() {
    _logs.clear();
  }

  const LogViewer({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey),
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: ListView.builder(
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          return Text(_logs[index]);
        },
      ),
    );
  }
}
