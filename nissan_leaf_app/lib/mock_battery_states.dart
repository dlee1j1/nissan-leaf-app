// lib/mock_battery_states.dart
import 'data/reading_model.dart';

class MockBatteryStates {
  static final Map<String, MockBatteryState> states = {
    'High Battery (86%)': MockBatteryState(
      name: 'High Battery (86%)',
      stateOfCharge: 86.0,
      batteryHealth: 95.0,
      estimatedRange: 150.0,
      batteryVoltage: 364.5,
      batteryCapacity: 56.0,
    ),
    'Medium Battery (64%)': MockBatteryState(
      name: 'Medium Battery (64%)',
      stateOfCharge: 64.0,
      batteryHealth: 92.0,
      estimatedRange: 120.0,
      batteryVoltage: 355.0,
      batteryCapacity: 50.0,
    ),
    'Low Battery (30%)': MockBatteryState(
      name: 'Low Battery (30%)',
      stateOfCharge: 30.0,
      batteryHealth: 90.0,
      estimatedRange: 81.0,
      batteryVoltage: 340.0,
      batteryCapacity: 45.0,
    ),
    'Critical Battery (10%)': MockBatteryState(
      name: 'Critical Battery (10%)',
      stateOfCharge: 10.0,
      batteryHealth: 88.0,
      estimatedRange: 36.0,
      batteryVoltage: 320.0,
      batteryCapacity: 40.0,
    ),
  };

  // Current state with default value
  static String currentState = 'Medium Battery (64%)';

  // Get the current battery state
  static MockBatteryState getCurrent() {
    return states[currentState]!;
  }

  // Generate a Reading object from current state
  static Reading generateReading() {
    final state = getCurrent();
    return Reading(
      timestamp: DateTime.now(),
      stateOfCharge: state.stateOfCharge,
      batteryHealth: state.batteryHealth,
      estimatedRange: state.estimatedRange,
      batteryVoltage: state.batteryVoltage,
      batteryCapacity: state.batteryCapacity,
    );
  }
}

class MockBatteryState {
  final String name;
  final double stateOfCharge;
  final double batteryHealth;
  final double estimatedRange;
  final double batteryVoltage;
  final double batteryCapacity;

  MockBatteryState({
    required this.name,
    required this.stateOfCharge,
    required this.batteryHealth,
    required this.estimatedRange,
    required this.batteryVoltage,
    required this.batteryCapacity,
  });
}
