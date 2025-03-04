import 'package:flutter/material.dart';
import '../obd/obd_command.dart';
import '../obd/mock_obd_controller.dart';
import '../components/log_viewer.dart';

class ObdTestPage extends StatefulWidget {
  const ObdTestPage({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _ObdTestPageState createState() => _ObdTestPageState();
}

class _ObdTestPageState extends State<ObdTestPage> {
  final _controller = TextEditingController();
  String _result = '';

  final String _frame64Percent = '''7BB10356101FFFFEC78
7BB210289FFFFE536FF
7BB22FFC5E51B584650
7BB238CFD3850038800
7BB24017000239A0009
7BB25962300191FB580
7BB260005FFFFE536FF
7BB27FFE48A01AEFFFF''';

  final String _frame86Percent = '''7BB10356101FFFFF060
7BB210289FFFFE763FF
7BB22FFCA4A09584650
7BB239608383E038700
7BB24017000239A000C
7BB25814C00191FB580
7BB260005FFFFE763FF
7BB27FFE56501AEFFFF''';

  void _set64PercentFrame() {
    _controller.text = _frame64Percent;
  }

  void _set86PercentFrame() {
    _controller.text = _frame86Percent;
  }

  void _runCommand() async {
    final response = _controller.text.trim();

    // Set up mock controller with input response
    OBDCommand.setObdController(MockObdController(response));

    try {
      // Run all commands
      final lbcResult = await OBDCommand.lbc.run();
      /*     final probeResult = await OBDCommand.probe.run();
      final powerResult = await OBDCommand.powerSwitch.run();
      final gearResult = await OBDCommand.gearPosition.run();
      final batteryResult = await OBDCommand.battery12v.run();
      final odometerResult = await OBDCommand.odometer.run();
*/
      setState(() {
        _result = '''
LBC: $lbcResult
''';
/*
Probe: $probeResult
Power: $powerResult
Gear: $gearResult
12V: $batteryResult
Odometer: $odometerResult
''';
*/
      });
    } catch (e) {
      setState(() {
        _result = 'Error: $e';
      });
    }
  }

  void _clearResults() {
    setState(() {
      _result = '';
    });
    LogViewer.clearLogs();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('OBD Command Tester')),
      body: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                labelText: 'Enter CAN Frame Response',
                hintText: 'e.g., 00 00 07 E8 10 20...',
              ),
              maxLines: 8,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _runCommand,
                  child: Text('Run Commands'),
                ),
                ElevatedButton(
                  onPressed: _clearResults,
                  child: Text('Clear Results'),
                ),
                ElevatedButton(
                  onPressed: _set64PercentFrame,
                  child: Text('64% Frame'),
                ),
                ElevatedButton(
                  onPressed: _set86PercentFrame,
                  child: Text('86% Frame'),
                ),
              ],
            ),
            SizedBox(height: 20),
            Text('Results:'),
            Expanded(
              child: SingleChildScrollView(
                child: Text(_result),
              ),
            ),
            Expanded(
              flex: 1,
              child: LogViewer(),
            ),
          ],
        ),
      ),
    );
  }
}
