// lib/mock_battery_selector.dart
import 'package:flutter/material.dart';
import '../mock_battery_states.dart';

class MockBatterySelector extends StatefulWidget {
  const MockBatterySelector({super.key});

  @override
  State<MockBatterySelector> createState() => _MockBatterySelectorState();
}

class _MockBatterySelectorState extends State<MockBatterySelector> {
  @override
  Widget build(BuildContext context) {
    return Container(
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
            'Mock Battery State:',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          DropdownButton<String>(
            isExpanded: true,
            value: MockBatteryStates.currentState,
            items: MockBatteryStates.states.keys.map((String state) {
              return DropdownMenuItem<String>(
                value: state,
                child: Text(state),
              );
            }).toList(),
            onChanged: (String? newValue) {
              if (newValue != null) {
                setState(() {
                  MockBatteryStates.currentState = newValue;
                });
              }
            },
          ),
        ],
      ),
    );
  }
}
