import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../background_service.dart';

class ServiceControlWidget extends StatefulWidget {
  const ServiceControlWidget({super.key});

  @override
  State<ServiceControlWidget> createState() => _ServiceControlWidgetState();
}

class _ServiceControlWidgetState extends State<ServiceControlWidget> {
  bool _isServiceRunning = false;
  bool _isCollecting = false;
  DateTime? _lastCollectionTime;
  String? _errorMessage;
  int _collectionFrequencyMinutes = 15;
  StreamSubscription? _serviceStatusSubscription;

  @override
  void initState() {
    super.initState();
    _initializeService();
  }

  Future<void> _initializeService() async {
    // Initialize the service
    await BackgroundService.initialize();

    // Check if the service is running
    _isServiceRunning = await BackgroundService.isServiceRunning();

    // Get the current collection frequency
    _collectionFrequencyMinutes = await BackgroundService.getCollectionFrequency();

    // Listen to service status updates
    _serviceStatusSubscription = BackgroundService.getStatusStream().listen((event) {
      if (event == null) return;

      setState(() {
        _isCollecting = event['collecting'] == true;

        if (event['lastCollection'] != null) {
          _lastCollectionTime = DateTime.parse(event['lastCollection']);
        }

        if (event['error'] != null) {
          _errorMessage = event['error'];
        } else {
          _errorMessage = null;
        }
      });
    });

    setState(() {});
  }

  Future<void> _toggleService() async {
    setState(() {
      _errorMessage = null;
    });

    try {
      if (_isServiceRunning) {
        await BackgroundService.stopService();
      } else {
        await BackgroundService.startService();
      }

      // Update the service state
      _isServiceRunning = await BackgroundService.isServiceRunning();
      setState(() {});
    } catch (e) {
      setState(() {
        _errorMessage = 'Error toggling service: $e';
      });
    }
  }

  Future<void> _updateFrequency(int minutes) async {
    try {
      await BackgroundService.setCollectionFrequency(minutes);
      setState(() {
        _collectionFrequencyMinutes = minutes;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error updating frequency: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Background Service',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Switch(
                  value: _isServiceRunning,
                  onChanged: (value) => _toggleService(),
                  activeColor: Colors.green,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Collection frequency slider
            Row(
              children: [
                const Icon(Icons.timer, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Collection Frequency'),
                          Text('$_collectionFrequencyMinutes minutes'),
                        ],
                      ),
                      Slider(
                        min: 1,
                        max: 60,
                        divisions: 59,
                        value: _collectionFrequencyMinutes.toDouble(),
                        onChanged: (value) => _updateFrequency(value.round()),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Status indicators
            Row(
              children: [
                Icon(
                  _isServiceRunning ? Icons.circle : Icons.circle_outlined,
                  color: _isServiceRunning ? Colors.green : Colors.grey,
                  size: 12,
                ),
                const SizedBox(width: 8),
                Text(
                  _isServiceRunning ? 'Service running' : 'Service stopped',
                  style: TextStyle(
                    color: _isServiceRunning ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            ),

            if (_isCollecting) ...[
              const SizedBox(height: 8),
              Row(
                children: const [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  ),
                  SizedBox(width: 8),
                  Text('Collecting data...'),
                ],
              ),
            ],

            if (_lastCollectionTime != null) ...[
              const SizedBox(height: 8),
              Text(
                'Last collection: ${DateFormat('MMM d, y - HH:mm:ss').format(_lastCollectionTime!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],

            if (_errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _serviceStatusSubscription?.cancel();
    super.dispose();
  }
}
