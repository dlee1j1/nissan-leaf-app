import 'package:test/test.dart';
import 'package:nissan_leaf_app/services/obd/can_protocol_handler.dart';

void main() {
  group('CANProtocolHandler', () {
    test('parses single frame message correctly', () {
      var hexResponse = '7E8 03 41 0C 1F';
      var result = CANProtocolHandler.parseMessage(hexResponse);
      expect(result, equals([0x41, 0x0C, 0x1F]));
    });

    test('parses multi frame message with correct sequence', () {
      var hexResponse = '''
7E8 10 0B 49 04 01
7E8 21 02 03 04 05
7E8 22 06 07 08 09''';
      var result = CANProtocolHandler.parseMessage(hexResponse);
      expect(result.length, equals(11));
      expect(result.sublist(0, 5), equals([0x49, 0x04, 0x01, 0x02, 0x03]));
    });

    test('throws on invalid frame length', () {
      var hexResponse = '7E8 41'; // Too short
      expect(() => CANProtocolHandler.parseMessage(hexResponse), throwsA(isA<FormatException>()));
    });

    test('throws on invalid frame sequence', () {
      var hexResponse = '''
7E8 10 20 49 04 01
7E8 21 02 03 04 05
7E8 23 06 07 08 09'''; // Sequence jumps from 1 to 3
      expect(() => CANProtocolHandler.parseMessage(hexResponse), throwsA(isA<FormatException>()));
    });

    test('handles empty lines in input', () {
      var hexResponse = '''
7E8 03 41 0C 1F

''';
      var result = CANProtocolHandler.parseMessage(hexResponse);
      expect(result, equals([0x41, 0x0C, 0x1F]));
    });

    test('throws on unknown frame type', () {
      var hexResponse = '7E8 30 41 0C 1F'; // Invalid frame type 0x30
      expect(() => CANProtocolHandler.parseMessage(hexResponse), throwsA(isA<FormatException>()));
    });
  });
}
