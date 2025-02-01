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

    // Step 3: Decode the response
    return decode(response);
  }

  // Decode the response (must be implemented by subclasses)
  Map<String, dynamic> decode(String response);

  // Static instances of commands
  static final OBDCommand lbc = _LBCCommand();
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
