import 'obd_controller.dart';
import 'dart:typed_data';
import 'dart:convert';


  // Utility functions
  int extractInt(List<int> bytes, int start, int end) {
    return ByteData.view(Uint8List.fromList(bytes.sublist(start, end)).buffer).getUint32(0);
  }

  List<int> hexStringToBytes(String hexString) {
    // Remove any whitespace or non-hex characters
    hexString = hexString.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');

    // Ensure the hex string has an even length
    if (hexString.length % 2 != 0) {
        hexString = '0$hexString';
    }

    // Convert the hex string to bytes
    var bytes = <int>[];
    for (var i = 0; i < hexString.length; i += 2) {
        var byte = int.parse(hexString.substring(i, i + 2), radix: 16);
        bytes.add(byte);
    }

    return bytes;
  }


/// Abstract base class for OBD (On-Board Diagnostics) commands.
/// 
/// This class provides a common interface for sending OBD commands to a vehicle's
/// on-board computer and decoding the responses. Subclasses of `OBDCommand` define
/// the specific details of each command, such as the command string, header, and
/// how to decode the response.
///
/// Usage: 
///   1. Initialize the `ObdController` by calling `OBDCommand.initialize(ODBController)`.
///   2. Use the `run()` method on specific commands, e.g.,
///      `var response = await OBDCommand.lbc.run();` // Send the Li-ion Battery Controller command
/// 
/// *Creating a new OBD command:*
/// 
/// To create a new OBD command, subclass `OBDCommand` and implement the `decode()` method
/// to parse the response from the vehicle and return the relevant data as a `Map<String, dynamic>`.
///
/// Subclasses should add a static instance of themselves to the end of the `OBDCommand` class. 
///
/// Clients can then use these instances to send commands to the vehicle. For example:
///    var response = await OBDCommand.lbc.run(); // Send the Li-ion Battery Controller command
///
/// *The run method:*
/// The run method coordinates the process of sending the OBD command, handling any errors, and returning the decoded response.
///  It leverages the specific/overridden data - header, command, and decode provided by the subclasses to send the command.
///
abstract class OBDCommand {
  // Static instance of ObdController
  static ObdController? _obdController;

/*
  // Initialize the ObdController
  static Future<void> initialize(BluetoothCharacteristic characteristic) async {
    _obdController = ObdController(characteristic);
    await _obdController!.initialize();
  }
*/

  // Setter for injecting a mock ObdController (for testing)
  static void setObdController(ObdController mockController) {
    _obdController = mockController;
  }

  // Command details (set by subclasses via constructor)
  final String name;
  final String description;
  final String command;
  final String header;

  // Constructor for subclasses to set the data
  OBDCommand({
    required this.name,
    required this.description,
    required this.command,
    required this.header,
  });

  // Send the command and return the response
  Future<Map<String, dynamic>> run() async {
    if (_obdController == null) {
      throw Exception('ObdController not initialized. Call OBDCommand.initialize() first.');
    }

    // Step 1: Set the header (AT command)
    await _obdController!.sendCommand('ATSH $header', expectOk: true);

    // Step 2: Send the OBD command
    var response = await _obdController!.sendCommand(command, expectOk: false);

    // Step 3: validation checks 
    if (response.isEmpty) {
        print('No valid OBD Messages returned');
        return {};
    }

    if (response == 'NO DATA' || response == 'CAN ERROR') {
        print('Vehicle not responding');
        return {};
    }

    // Step 4: decode the valid response
    return decode(response);
  }

  // Decode the response (must be implemented by subclasses)
  Map<String, dynamic> decode(String response);

  // Static instances of commands
  static final OBDCommand lbc = _LBCCommand();
  static final OBDCommand probe = _ProbeCommand();
}



class _LBCCommand extends OBDCommand {
  _LBCCommand()
      : super(
          name: 'lbc',
          description: 'Li-ion Battery Controller',
          command: '022101',
          header: '79B',
        );

  @override
  Map<String, dynamic> decode(String hexResponse) {
    // Convert the hex string to bytes
    var response = hexStringToBytes(hexResponse);
    if (response.isEmpty) {
      return {};
    }

    // Extract SOC, SOH, and other data (adjust byte ranges as needed)
    var soc = extractInt(response, 33, 37) / 10000; // SOC in bytes 33-36
    var soh = extractInt(response, 30, 32) / 102.4; // SOH in bytes 30-32
    var batteryAh = extractInt(response, 37, 40) / 10000; // Battery capacity in bytes 37-40
    var hvBatteryVoltage = extractInt(response, 20, 22) / 100; // HV battery voltage in bytes 20-22

    return {
      'state_of_charge': soc,
      'hv_battery_health': soh,
      'hv_battery_Ah': batteryAh,
      'hv_battery_voltage': hvBatteryVoltage,
    };
  }

}

/// Probe command - it's a mystery command that we use to probe the vehicle for OBD data. 
/// if it returns an error, then we know the rest of the data will not work as expected. 
class _ProbeCommand extends OBDCommand {
  _ProbeCommand()
      : super(
          name: 'unknown',
          description: 'Mystery command',
          command: '0210C0 1',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(String response) {
    return {
      'raw_response': response,
    };
  }
}
