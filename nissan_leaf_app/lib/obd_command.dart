import 'obd_controller.dart';
import 'can_protocol_handler.dart';
import 'package:simple_logger/simple_logger.dart';

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

  // Static instances of commands
  static final OBDCommand lbc = _LBCCommand();
  static final OBDCommand probe = _ProbeCommand();
  static final OBDCommand powerSwitch = _PowerSwitchCommand();
  static final OBDCommand gearPosition = _GearPositionCommand();
  static final OBDCommand battery12v = _12VBatteryCommand();
  static final OBDCommand odometer = _OdometerCommand();
  

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
    await _obdController!.sendCommand('ATFCSH $header', expectOk: true);
    await _obdController!.sendCommand('ATFCSM1', expectOk: true); // flow control

    // Step 2: Send the OBD command
    final response = await _obdController!.sendCommand(command, expectOk: false);
    // Step 3: validation checks 
    if (response.isEmpty) {
        _log.warning('No valid OBD Messages returned');
        return {};
    }

    if (response == 'NO DATA' || response == 'CAN ERROR') {
        _log.severe('Vehicle not responding');
        return {};
    }

    // Step 4: Parse CAN protocol only for vehicle commands
    final canMessage = CANProtocolHandler.parseMessage(response);

    // Step 4: decode the valid response
    return decode(canMessage);
  }

  // Decode the response (must be implemented by subclasses)
  Map<String, dynamic> decode(List<int> response);
  static final _log = SimpleLogger();
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
  Map<String, dynamic> decode(List<int> data) {
    if (data.isEmpty) return {};

    var hvBatteryCurrent1 = extractInt(data, 2, 6);
    var hvBatteryCurrent2 = extractInt(data, 8, 12);
    
    // Handle signed values
    if (hvBatteryCurrent1 & 0x8000000 == 0x8000000) {
        hvBatteryCurrent1 |= -0x100000000;
    }
    if (hvBatteryCurrent2 & 0x8000000 == 0x8000000) {
        hvBatteryCurrent2 |= -0x100000000;
    }

    int stateOfCharge;
    int stateOfHealth;
    int batteryAh;

    if (data.length > 41) {
        stateOfCharge = extractInt(data, 33, 36) ~/ 10000;
        stateOfHealth = extractInt(data, 30, 32) ~/ 102.4;
        batteryAh = extractInt(data, 37, 40) ~/ 10000;
    } else {
        stateOfCharge = extractInt(data, 31, 34) ~/ 10000;
        stateOfHealth = extractInt(data, 28, 30) ~/ 102.4;
        batteryAh = extractInt(data, 34, 37) ~/ 10000;
    }

    return {
        'state_of_charge': stateOfCharge,
        'hv_battery_health': stateOfHealth,
        'hv_battery_Ah': batteryAh,
        'hv_battery_current_1': hvBatteryCurrent1 ~/ 1024,
        'hv_battery_current_2': hvBatteryCurrent2 ~/ 1024,
        'hv_battery_voltage': extractInt(data, 20, 22) ~/ 100,
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
  Map<String, dynamic> decode(List<int> response) {
    return {
      'raw_response': response,
    };
  }
}

class _PowerSwitchCommand extends OBDCommand {
  _PowerSwitchCommand()
      : super(
          name: 'power_switch',
          description: 'Power Switch Status',
          command: '03221304',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'power_switch': (data[3] & 0x80) == 0x80,
    };
  }
}

class _GearPositionCommand extends OBDCommand {
  _GearPositionCommand()
      : super(
          name: 'gear_position',
          description: 'Current Gear Position',
          command: '03221156',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    String position;
    switch (data[3]) {
      case 1: position = "Park"; break;
      case 2: position = "Reverse"; break;
      case 3: position = "Neutral"; break;
      case 4: position = "Drive"; break;
      case 5: position = "Eco"; break;
      default: position = "Unknown";
    }
    return {'gear_position': position};
  }
}

class _12VBatteryCommand extends OBDCommand {
  _12VBatteryCommand()
      : super(
          name: '12v_battery',
          description: '12V Battery Voltage',
          command: '03221103',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'bat_12v_voltage': data[3] * 0.08,
    };
  }
}

class _OdometerCommand extends OBDCommand {
  _OdometerCommand()
      : super(
          name: 'odometer',
          description: 'Total odometer reading',
          command: '03220e01',
          header: '743',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'odometer': extractInt(data, 3, 6),
    };
  }
}

// Utility functions
int extractInt(List<int> bytes, int start, int end) {
  // bigEndian
  if (end - start > 4) {
    throw Exception('Cannot extract more than 4 bytes (32 bits)');
  }

  int result = 0;
  for (int i = start; i < end; i++) {
    result = (result << 8) + bytes[i];
  }
  return result;
}
