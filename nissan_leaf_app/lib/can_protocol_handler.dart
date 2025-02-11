import 'package:simple_logger/simple_logger.dart';


/// 
/// Handles CAN protocol messages from vehicle OBD responses
/// 
/// Usage:
/// ```
/// var messageData = CANProtocolHandler.parseMessage(hexResponse);
///   // messageData contains assembled bytes from all frames
/// ```    
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
/// 
class CANProtocolHandler {
  static const FRAME_TYPE_SF = 0x00;  // Single Frame
  static const FRAME_TYPE_FF = 0x10;  // First Frame
  static const FRAME_TYPE_CF = 0x20;  // Consecutive Frame
  
  static const MAX_FRAME_LENGTH = 12;
  static const MIN_FRAME_LENGTH = 6;

  static List<int> parseMessage(String hexResponse) {
    var frames = hexResponse.split(RegExp(r'[\n\r]'))
        .map((f) => f.trim()) // Remove leading/trailing whitespace
        .where((f) => f.isNotEmpty) // Remove empty lines
        .map((f) => "00000" + f)  // Always pad for Protocol 6 
        .map((f) => _hexStringToBytes(f)) // Convert to hex to bytes
        .toList();

    _log.fine('hexResponse: $hexResponse');
    _log.fine('Frames: $frames');

    // Validate each frame
    for (var frame in frames) {
      if (frame.length < MIN_FRAME_LENGTH || frame.length > MAX_FRAME_LENGTH) {
        _log.severe('Invalid frame length: $frame has length ${frame.length}');
        throw FormatException('CAN Frame: Invalid frame length');
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
        throw FormatException('CAN Frame: Unknown frame type');
    }
  }

  static List<int> _parseSingleFrame(List<int> frame) {
    var length = frame[4] & 0x0F;
    final messageData = frame.sublist(5); // not sure if this should be 5 or 4 //XXXX
    _log.fine('Single Frame: $messageData; Length: $length');
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
    _log.fine('Expected Length: $totalLength');    

    // Initialize message data with first frame (FF) payload
    //   Data bytes start after PCI and length bytes which are 
    //     4 bytes - PCI 
    //      + 1 nibble for type (in this case the FF type)
    //      + 12 bits (1 nibble + 1 byte) for length of frame
    //   so total of 6 bytes to skip
    var messageData = frames[0].sublist(6); 

    // Sort and validate consecutive frames (CF)
    var cfFrames = frames.sublist(1);
    // print('Consecutive Frames: $cfFrames');
    var sortedCF = _sortConsecutiveFrames(cfFrames);
    if (!_validateSequence(sortedCF)) {
      throw FormatException('CAN Frame: Invalid frame sequence');
    }


    // Combine CF data
    for (var frame in sortedCF) {
       // example: 00 00 07 BB 22 49 04...
       // Skip the first 5 bytes of each frame which contain:
       //  4 bytes CAN ID - e.g., 00 00 07 BB
       //  5th byte 
       //    - 1 nibble frame type identifier - e.g., 2 to define Consecutive Frame (CF)
       //    - 1 nibble sequence number (for consecutive frames CF)
      messageData.addAll(frame.sublist(5));
    }

    _log.info('Multi Frame: $messageData. Length: ${messageData.length}. Expected Length: $totalLength');

    // Trim to specified length
    // messageData = messageData.sublist(0, totalLength);

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

  static final _log = SimpleLogger();
}

List<int> _hexStringToBytes(String hexString) {
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


