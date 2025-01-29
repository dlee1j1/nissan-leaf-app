import 'package:flutter/material.dart';

class LogViewer extends StatelessWidget {
  final List<String> logs;

  const LogViewer({Key? key, required this.logs}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey),
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: ListView.builder(
        itemCount: logs.length,
        itemBuilder: (context, index) {
          return Text(logs[index]);
        },
      ),
    );
  }
}