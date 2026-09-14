// lib/components/live_drive_check_widget.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../obd/obd_command.dart';

/// A purpose-built, glanceable live readout for verifying speed/odometer/
/// ambient-temp decoding against the real car while driving.
///
/// Not part of the production collection pipeline - this is a temporary
/// verification tool (see plan: "Data pipeline: charge-cap check-in +
/// analytics groundwork", Phase A). [ObdCommandsPanel] already exposes all
/// registered commands, but re-runs all ~25 of them per tap and renders
/// small scrolling text, which isn't safe or fast enough to read at a
/// glance while driving.
///
/// Polls are strictly sequential (the OBD dongle is a single BLE link) and
/// self-guarding against overlap if a poll ever takes longer than
/// [pollInterval].
class LiveDriveCheckWidget extends StatefulWidget {
  final Duration pollInterval;

  const LiveDriveCheckWidget({super.key, this.pollInterval = const Duration(seconds: 1)});

  @override
  // ignore: library_private_types_in_public_api
  _LiveDriveCheckWidgetState createState() => _LiveDriveCheckWidgetState();
}

class _LiveDriveCheckWidgetState extends State<LiveDriveCheckWidget> {
  Timer? _timer;
  bool _active = false;
  bool _polling = false;
  double? _speed;
  int? _odometer;
  double? _ambientTemp;
  String? _error;

  void _toggle() => _active ? _stop() : _start();

  void _start() {
    setState(() {
      _active = true;
      _error = null;
    });
    _pollOnce();
    _timer = Timer.periodic(widget.pollInterval, (_) => _pollOnce());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    setState(() => _active = false);
  }

  Future<void> _pollOnce() async {
    if (_polling) return; // don't overlap polls on the single BLE link
    _polling = true;
    try {
      final speedResult = await OBDCommand.speed.run();
      final odometerResult = await OBDCommand.odometer.run();
      final ambientResult = await OBDCommand.ambientTemp.run();
      if (!mounted) return;
      setState(() {
        _speed = (speedResult['speed'] as num?)?.toDouble();
        _odometer = (odometerResult['odometer'] as num?)?.toInt();
        _ambientTemp = (ambientResult['ambient_temp'] as num?)?.toDouble();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Error: $e');
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Live Drive Check',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                ElevatedButton(
                  onPressed: _toggle,
                  child: Text(_active ? 'Stop' : 'Start'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                _speed != null ? '${_speed!.toStringAsFixed(0)} km/h' : '--',
                style: const TextStyle(fontSize: 72, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Text('Odometer: ${_odometer != null ? '$_odometer km' : '--'}'),
                Text(
                    'Ambient: ${_ambientTemp != null ? '${_ambientTemp!.toStringAsFixed(1)}°C' : '--'}'),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}
