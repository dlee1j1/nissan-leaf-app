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
`connectToDevice()` only reports success once `OBDCommand.probe` gets a non-empty response - a BLE-level connection
isn't enough on its own to mean the vehicle bus is actually answering (see Troubleshooting below).

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

5. **`probe` is a real vehicle command, not a self-test**: `OBDCommand.probe`
   (header `797`, command `0210C0 1`) is a diagnostic-session-shaped command
   sent to the car's BMS ECU, used to confirm the vehicle bus - not just the
   BLE link - is actually answering. Don't call it twice back to back (e.g.
   once to validate a connection, then again to double-check) - a real ECU
   may not answer the same session-control-shaped request the same way
   twice in quick succession, and BLE-level "connected" plus an
   immediately-repeated probe was observed to reliably produce an empty
   response on the second call even though the dongle and vehicle were both
   fine (issue #3). `connectToDevice()` is the only place that should call
   it per connection attempt.

## Model Year Differences

The Nissan Leaf has evolved across model years, with significant changes to the OBD system. Known differences:

- **2011-2017 (Gen 1)**: Many commands use different PIDs
- **2018 (Gen 2 early)**: Most commands in this codebase are optimized for this model year
- **2019+ (Gen 2 later)**: Several commands need adjustment, particularly battery-related ones
- **2022+ (Gen 3)**: Substantial differences, limited testing done

Contributors are encouraged to document their findings for specific model years in the comments of `obd_command.dart`.

## Where the PID/decode definitions came from

Most of `obd_command.dart`'s registry (everything except `lbc` and
`rangeRemaining`, the two that were exercised in production before
2026-09) was bulk-copied from another project's command table in one
Feb 2025 commit, with no source preserved in the repo. Dennis has since
confirmed several of those formulas don't hold up on his actual 2018
Gen2 Leaf.

**Validated against the real car, byte-exact (2026-09):**
`speed`, `odometer`, `ambientTemp`, `l1l2Charges`, `quickCharges` - checked
against `ze1_polling.pdf`, a byte-exact "Nissan Leaf 2018" UDS PID
reference (same `03 22 <PID>` / header `797`/`743` scheme this codebase
uses), then confirmed live via the OBD Test Page. Source:
<https://drive.google.com/file/d/1jH9cgm5v23qnqVnmZN3p4TvdaokWKPjM/view>,
linked from
[dalathegreat/leaf_can_bus_messages](https://github.com/dalathegreat/leaf_can_bus_messages)'s
README under "What about active CAN-polling?". That repo's own DBC files
(broadcast CAN, a different addressing scheme) independently corroborate
at least the `ambientTemp` scale factor.

**Everything else in the registry**: unverified. Copied from
[pbutterworth/py-nissan-leaf-obd-ble](https://github.com/pbutterworth/py-nissan-leaf-obd-ble)
(itself the likely origin of the Feb 2025 bulk copy here), which is a
reasonable starting point for a new command but not a source to trust
without checking against `ze1_polling.pdf` and/or the real car first -
that's exactly what caught `ambientTemp` being off by a constant and
ruled out `rangeRemaining` entirely (removed - see the note in
`obd_command.dart` near `extractInt`).

**LeafSpy** (the commercial Turbo3 app) is known-good and worth
cross-checking against if a command still doesn't make sense after the
above - it has no public PID list, but its own Settings → Server export
pushes already-decoded values that can serve as ground truth.
