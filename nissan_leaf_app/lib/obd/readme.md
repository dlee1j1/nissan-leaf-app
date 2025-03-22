# Nissan Leaf OBD Communication Layer

This directory contains the components responsible for communicating with the Nissan Leaf's on-board diagnostics (OBD) system via Bluetooth.

*[Return to main documentation](../../README.md)*

## Architecture

The OBD communication layer follows a pragmatic design:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     OBDConnector│────▶│BluetoothDevice  │────▶│  OBDController  │
│    (Facade)     │     │   Manager       │     │                 │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                         │
                                                         ▼
                                                ┌─────────────────┐
                                                │   OBDCommand    │
                                                │                 │
                                                └────────┬────────┘
                                                         │
                                                         ▼
                                                ┌─────────────────┐
                                                │ CANProtocol     │
                                                │  Handler        │
                                                └─────────────────┘
```

## Key Components

### `obd_connector.dart`

A simplified facade for application code to interact with the OBD system. This is the primary entry point for other parts of the application.

```dart
// Example usage
final connector = OBDConnector();
await connector.initialize();
final isConnected = await connector.autoConnectToObd();
final data = await connector.collectCarData();
```

### `bluetooth_device_manager.dart`

Manages Bluetooth device discovery, connection, and communication. Handles retry logic and error recovery.

### `obd_controller.dart`

Manages low-level OBD communication with the vehicle's ECUs, including initialization, command formatting, and response parsing.

### `obd_command.dart`

Defines all vehicle-specific OBD commands and their decoding logic. This is the primary file that needs to be extended or modified for different Leaf model years.

### `can_protocol_handler.dart`

Handles parsing of CAN bus protocol messages, including multi-frame reassembly of longer responses.

## Adding New OBD Commands

To add a new OBD command:

1. Identify the command parameters:
   - Service: Usually 03 (diagnostic) or 02 (data)
   - PID: The parameter ID
   - Header: The ECU address (e.g., 7BB for LBC, 797 for VCM)

2. Add a new command class in `obd_command.dart`:

```dart
class _NewCommandName extends OBDCommand {
  _NewCommandName()
      : super(
          name: 'command_name',         // Unique identifier
          description: 'Description',   // Human-readable description
          command: '03220123',          // OBD command string
          header: '7BB',                // ECU address
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    // Implement decoding logic here
    return {
      'metric_name': calculateValue(data),
    };
  }
}
```

3. Register the command in the static instances at the top of the `OBDCommand` class:

```dart
static final OBDCommand newCommand = _NewCommandName();
```

4. Add the command to the `_registry` list to make it available for batch operations.

## Testing OBD Commands

The easiest way to test a new command is with the OBD Test Page in the app, which allows you to:

1. Connect to your vehicle
2. Test individual commands
3. View raw responses for debugging

Alternatively, use the `MockObdController` in your tests:

```dart
final mockController = MockObdController('7EC 03 62 01 23 45');
OBDCommand.setObdController(mockController);
final result = await OBDCommand.yourCommand.run();
```

## Troubleshooting OBD Communication

Common issues:

1. **Connection failures**: Check Bluetooth permissions and ensure the OBD adapter is compatible (ELM327 v1.5 or higher recommended)

2. **No response**: Some commands may not be supported by your specific vehicle model/year

3. **Invalid data**: The decoding logic may need to be adjusted for your vehicle. Print raw responses using:
   ```dart
   final debugCommand = _DebugCommand(command: '03220123', header: '7BB');
   debugCommand.setController(_obdController);
   final result = await debugCommand.run();
   print('Raw response: ${result['raw_data']}');
   ```

4. **Timeouts**: Increase the timeout value in the `ObdController` if commands take too long

## Model Year Differences

The Nissan Leaf has evolved across model years, with significant changes to the OBD system. Known differences:

- **2011-2017 (Gen 1)**: Many commands use different PIDs
- **2018 (Gen 2 early)**: Most commands in this codebase are optimized for this model year
- **2019+ (Gen 2 later)**: Several commands need adjustment, particularly battery-related ones
- **2022+ (Gen 3)**: Substantial differences, limited testing done

Contributors are encouraged to document their findings for specific model years in the comments of `obd_command.dart`.
