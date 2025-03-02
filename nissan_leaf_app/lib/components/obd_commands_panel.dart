// ignore_for_file: library_private_types_in_public_api

import 'package:flutter/material.dart';
import '../services/obd/obd_command.dart';
import 'package:simple_logger/simple_logger.dart';

class ObdCommandsPanel extends StatefulWidget {
  const ObdCommandsPanel({super.key});

  @override
  _ObdCommandsPanelState createState() => _ObdCommandsPanelState();
}

class _ObdCommandsPanelState extends State<ObdCommandsPanel> {
  Map<String, dynamic> commandResults = {};
  bool isRefreshing = false;
  final _log = SimpleLogger();

  @override
  void initState() {
    _log.info('Initializing ObdCommandsPanel');
    super.initState();
    // Defer the initial refresh to let widget fully initialize
    Future.microtask(() => refreshAllCommands());
    _log.info('ObdCommandsPanel initialized');
  }

  Future<void> refreshAllCommands() async {
    setState(() => isRefreshing = true);

    final commands = OBDCommand.getAllCommands();

    for (var command in commands) {
      try {
        final result = await command.run();
        setState(() {
          commandResults[command.description] = result;
        });
        _log.info('${command.description}: $result');
      } catch (e) {
        _log.warning('Error running ${command.name}: $e');
      }
    }

    setState(() => isRefreshing = false);
  }

  Widget _buildResultCard(String title, Map<String, dynamic> values) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Divider(),
            ...values.entries.map((e) => Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(e.key.replaceAll('_', ' ').toUpperCase()),
                      Text(e.value.toString()),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(8),
          child: ElevatedButton.icon(
            onPressed: isRefreshing ? null : refreshAllCommands,
            icon: Icon(isRefreshing ? Icons.sync : Icons.refresh),
            label: Text(isRefreshing ? 'Refreshing...' : 'Refresh All'),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: refreshAllCommands,
            child: ListView.builder(
              physics: AlwaysScrollableScrollPhysics(),
              itemCount: commandResults.length,
              itemBuilder: (context, index) {
                final entry = commandResults.entries.elementAt(index);
                return _buildResultCard(
                    entry.key, entry.value is Map ? entry.value : {'value': entry.value});
              },
            ),
          ),
        ),
      ],
    );
  }
}
