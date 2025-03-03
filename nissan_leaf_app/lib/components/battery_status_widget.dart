import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class BatteryStatusWidget extends StatelessWidget {
  final double stateOfCharge;
  final double batteryHealth;
  final double? estimatedRange;
  final DateTime? lastUpdated;
  final bool isLoading;
  final VoidCallback? onRefresh;

  /// Widget that displays current battery status information
  ///
  /// Shows state of charge, battery health, estimated range, and last updated time
  /// in a visually appealing card format
  const BatteryStatusWidget({
    super.key,
    required this.stateOfCharge,
    required this.batteryHealth,
    this.estimatedRange,
    this.lastUpdated,
    this.isLoading = false,
    this.onRefresh,
  });

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
                  'Battery Status',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (onRefresh != null)
                  IconButton(
                    icon: isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    onPressed: isLoading ? null : onRefresh,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildBatteryIndicator(),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildStatusRow(
                        'State of Charge',
                        '$stateOfCharge%',
                        Icons.battery_charging_full,
                        stateOfCharge / 100,
                        Colors.green,
                      ),
                      const SizedBox(height: 12),
                      _buildStatusRow(
                        'Battery Health',
                        '$batteryHealth%',
                        Icons.favorite,
                        batteryHealth / 100,
                        Colors.red,
                      ),
                      if (estimatedRange != null) ...[
                        const SizedBox(height: 12),
                        _buildStatusRow(
                          'Est. Range',
                          '${estimatedRange!.toStringAsFixed(1)} km',
                          Icons.map,
                          null,
                          Colors.blue,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (lastUpdated != null) ...[
              const SizedBox(height: 12),
              Text(
                'Last updated: ${DateFormat('MMM d, y - HH:mm').format(lastUpdated!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBatteryIndicator() {
    final color = stateOfCharge > 50
        ? Colors.green
        : stateOfCharge > 20
            ? Colors.orange
            : Colors.red;

    return Container(
      width: 50,
      height: 100,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey, width: 2),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        children: [
          Container(
            height: 10,
            width: 20,
            decoration: const BoxDecoration(
              color: Colors.grey,
              borderRadius: BorderRadius.vertical(top: Radius.circular(2)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(2.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Container(
                    height: (92 * stateOfCharge / 100).clamp(0, 92),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusRow(
      String label, String value, IconData icon, double? progressValue, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(value),
                ],
              ),
              if (progressValue != null) ...[
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: progressValue,
                  backgroundColor: Colors.grey[300],
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
