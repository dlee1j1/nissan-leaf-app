import 'package:flutter/material.dart';

import 'obd/obd_command.dart';
import 'obd/mock_obd_controller.dart';
import 'components/dashboard_page.dart';
import 'background_service.dart';

// Web-specific home page that doesn't require Bluetooth
class WebHomePage extends StatefulWidget {
  const WebHomePage({super.key});

  @override
  State<WebHomePage> createState() => _WebHomePageState();
}

class _WebHomePageState extends State<WebHomePage> {
  // Mock data for different battery states
  final Map<String, String> mockResponses = {
    'High Battery (86%)': '''7BB10356101FFFFF060
7BB210289FFFFE763FF
7BB22FFCA4A09584650
7BB239608383E038700
7BB24017000239A000C
7BB25814C00191FB580
7BB260005FFFFE763FF
7BB27FFE56501AEFFFF''',
    'Medium Battery (64%)': '''7BB10356101FFFFEC78
7BB210289FFFFE536FF
7BB22FFC5E51B584650
7BB238CFD3850038800
7BB24017000239A0009
7BB25962300191FB580
7BB260005FFFFE536FF
7BB27FFE48A01AEFFFF''',
    'Low Battery (30%)': '''7BB10356101FFFFF050
7BB210289FFFFE763FF
7BB22FFCA4A09584650
7BB239608383E038700
7BB24017000239A0003
7BB25814C00191FB580
7BB260005FFFFE763FF
7BB27FFE56501AEFFFF''',
    'Critical Battery (10%)': '''7BB10356101FFFFF040
7BB210289FFFFE763FF
7BB22FFCA4A09584650
7BB239608383E038700
7BB24017000239A0001
7BB25814C00191FB580
7BB260005FFFFE763FF
7BB27FFE56501AEFFFF''',
  };

  final Map<String, String> mockRangeResponses = {
    'High Battery (86%)': '7BB 03 62 0E 24 05 DC', // 150 km
    'Medium Battery (64%)': '7BB 03 62 0E 24 04 B0', // 120 km
    'Low Battery (30%)': '7BB 03 62 0E 24 03 2A', // 81 km
    'Critical Battery (10%)': '7BB 03 62 0E 24 01 68', // 36 km
  };

  String currentBatteryState = 'High Battery (86%)';
  MockObdController? mockController;

  @override
  void initState() {
    super.initState();
    _setupMockController();
  }

  void _setupMockController() {
    // Create mock controller with current battery state
    final batteryResponse = mockResponses[currentBatteryState]!;
    final rangeResponse = mockRangeResponses[currentBatteryState]!;

    mockController = MockObdController(batteryResponse);
    mockController!.mockRangeResponse = rangeResponse;

    // Initialize OBD commands with the mock controller
    OBDCommand.setObdController(mockController!);
    // Also set the controller for the background service
    BackgroundService.setObdController(mockController!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nissan Leaf Battery Tracker (Web Demo)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () {
              _showHelpDialog(context);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Battery state selector
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            margin: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Select Battery State:',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                DropdownButton<String>(
                  isExpanded: true,
                  value: currentBatteryState,
                  items: mockResponses.keys.map((String state) {
                    return DropdownMenuItem<String>(
                      value: state,
                      child: Text(state),
                    );
                  }).toList(),
                  onChanged: (String? newValue) {
                    if (newValue != null) {
                      setState(() {
                        currentBatteryState = newValue;
                        _setupMockController();
                      });
                    }
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.dashboard),
                      label: const Text('View Dashboard'),
                      onPressed: () {
                        Navigator.pushNamed(
                          context,
                          '/dashboard',
                          arguments: mockController,
                        );
                      },
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.code),
                      label: const Text('OBD Test Console'),
                      onPressed: () {
                        Navigator.pushNamed(context, '/obd_test');
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Preview of battery status
          Expanded(
            child: DashboardPage(obdController: mockController),
          ),
        ],
      ),
    );
  }

  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('About Web Demo Mode'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text('This is a web demonstration of the Nissan Leaf Battery Tracker app.'),
                SizedBox(height: 8),
                Text(
                    'Since web browsers cannot access Bluetooth OBD devices, this demo uses simulated data to showcase the app\'s UI and functionality.'),
                SizedBox(height: 8),
                Text(
                    'You can select different battery states from the dropdown to see how the app responds to various charge levels.'),
                SizedBox(height: 16),
                Text('Features:', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text('• View the dashboard with simulated battery data'),
                Text('• Test different battery charge levels'),
                Text('• Explore the OBD test console'),
                SizedBox(height: 16),
                Text(
                    'Note: This demo uses the MockObdController to simulate responses from a vehicle. In the actual app, this data would come from a real Nissan Leaf via Bluetooth.'),
              ],
            ),
          ),
          actions: [
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }
}
