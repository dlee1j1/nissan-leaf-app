import 'obd_controller.dart';
import 'dart:typed_data';
import 'dart:convert';


  // Utility functions
  int extractInt(List<int> bytes, int start, int end) {
    print('Calling extractInt on $bytes. Length - ${bytes.length}. Start - $start, End - $end');
    print('Offset - $start = ${bytes[start]}, Offset - $end minus 1 = ${bytes[end-1]}');
    final sublist = bytes.sublist(start, end);
    // Ensure at least 4 bytes by padding with zeros
    final paddedBytes = Uint8List(4)..setRange(0, sublist.length, sublist);

    // Read as uint32
    final result = ByteData.view(paddedBytes.buffer).getUint32(0);
    return result;
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
        print('No valid OBD Messages returned');
        return {};
    }

    if (response == 'NO DATA' || response == 'CAN ERROR') {
        print('Vehicle not responding');
        return {};
    }

    // Step 4: Parse CAN protocol only for vehicle commands
    final canMessage = CANProtocolHandler.parseMessage(response);

    // Step 4: decode the valid response
    return decode(canMessage);
  }

  // Decode the response (must be implemented by subclasses)
  Map<String, dynamic> decode(List<int> response);


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
        'hv_battery_current_1': hvBatteryCurrent1 / 1024,
        'hv_battery_current_2': hvBatteryCurrent2 / 1024,
        'hv_battery_voltage': extractInt(data, 20, 22) / 100,
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




/// Handles CAN protocol messages from vehicle OBD responses
/// 
/// The CAN protocol splits long messages into multiple frames:
/// - Single Frame (SF): Complete message in one frame
/// - First Frame (FF): First part of multi-frame message, contains total length
/// - Consecutive Frame (CF): Remaining parts of message with sequence numbers
/// 
/// Frame Structure:
/// [00 00 07 E8] - CAN ID/Header (4 bytes)
///   - Priority and addressing information
///   - Identifies source/destination ECUs
/// [10] - Protocol Control Information (PCI) byte
///   - 0x00: Single Frame
///   - 0x10: First Frame  
///   - 0x20-0x2F: Consecutive Frames (with sequence number)
/// [...] - Data bytes
/// 
/// Usage:
/// ```
/// var messageData = CANProtocolHandler.parseMessage(hexResponse);
/// // messageData contains assembled bytes from all frames
/// ```
class CANProtocolHandler {
  static const FRAME_TYPE_SF = 0x00;  // Single Frame
  static const FRAME_TYPE_FF = 0x10;  // First Frame
  static const FRAME_TYPE_CF = 0x20;  // Consecutive Frame
  
  static const MAX_FRAME_LENGTH = 12;
  static const MIN_FRAME_LENGTH = 6;

  static List<int> parseMessage(String hexResponse) {
    var frames = hexResponse.split(RegExp(r'[\n\r]'))
        .where((f) => f.isNotEmpty) // Remove empty lines
        .map((f) => "00000" + f)  // Always pad for Protocol 6 
        .map((f) => hexStringToBytes(f)) // Convert to hex to bytes
        .toList();

    print('hexResponse: $hexResponse');
    print('Frames: $frames');


    // Validate each frame
    for (var frame in frames) {
      if (frame.length < MIN_FRAME_LENGTH || frame.length > MAX_FRAME_LENGTH) {
        print('Invalid frame length: $frame has length ${frame.length}');
        throw ObdCommandError('CAN Frame', 'Invalid frame length');
      }
    }

    // Get frame type from first frame
    var frameType = frames[0][4] & 0xF0;

    switch (frameType) {
      case FRAME_TYPE_SF:
        return _parseSingleFrame(frames[0]);
      case FRAME_TYPE_FF:
        return _parseMultiFrame(frames);
      default:
        throw ObdCommandError('CAN Frame', 'Unknown frame type');
    }
  }

  static List<int> _parseSingleFrame(List<int> frame) {
    var length = frame[4] & 0x0F;
    final messageData = frame.sublist(5); // not sure if this should be 5 or 4 //XXXX
    print('Single Frame: $messageData; Length: $length');
    return messageData;
  }

  static List<int> _parseMultiFrame(List<List<int>> frames) {
  /* 
   CAN protocol specified that the First Frame (FF) uses 12 bits for length encoding.
    1. frames[0][4] - Gets PCI byte from first frame (0x10)
    2. & 0x0F - Masks lower nibble to get length bits (0x0)
    3. << 8 - Shifts those bits left by 8 positions (0x000) 
    4. frames[0][5] - Gets next byte containing rest of length (0x20)
    5. adds the two to get total length (0x0020)

     Example FF: 00 00 07 E8 10 20 49 04...
                             ^^ ^^ PCI and length bytes
      PCI byte: 0x10
      Length byte: 0x20
      Calculation: ((0x0) << 8) + 0x20 = 32
  */
    var totalLength = ((frames[0][4] & 0x0F) << 8) + frames[0][5];
    print('Expected Length: $totalLength');    

    // Sort and validate consecutive frames (CF)
    var cfFrames = frames.sublist(1);
    var sortedCF = _sortConsecutiveFrames(cfFrames);
    
    if (!_validateSequence(sortedCF)) {
      throw ObdCommandError('CAN Frame', 'Invalid frame sequence');
    }

    // Initialize message data with first frame (FF) payload
    var messageData = frames[0].sublist(5);  // should this be sublist(5 or 4)?

    // Combine CF data
    for (var frame in sortedCF) {
       // Skip the first 5 bytes of each frame which contain:
       // 3 bytes CAN ID
       //  1 byte length
       //  1 byte PCI (Protocol Control Information) The remaining bytes are actual data
      messageData.addAll(frame.sublist(5));
    }

    print('Multi Frame: $messageData. Length: ${messageData.length}. Expected Length: $totalLength');

    // Trim to specified length
    messageData = messageData.sublist(0, totalLength);

    return messageData;
  }

  static List<List<int>> _sortConsecutiveFrames(List<List<int>> frames) {
    return frames..sort((a, b) => (a[4] & 0x0F).compareTo(b[4] & 0x0F));
  }

  static bool _validateSequence(List<List<int>> frames) {
    for (var i = 0; i < frames.length - 1; i++) {
      var current = frames[i][4] & 0x0F;
      var next = frames[i + 1][4] & 0x0F;
      if (next != (current + 1) % 16) {
        return false;
      }
    }
    return true;
  }
}
