import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/obd_command.dart';
import 'package:nissan_leaf_app/mock_obd_controller.dart';

void main() {
  group('OBDCommand Flow Tests', () {

    test('Gear Position Command sequence and response', () async {
      final mockController = MockObdController('7EC 03 62 11 56 04');
      OBDCommand.setObdController(mockController);
      
      final result = await OBDCommand.gearPosition.run();

      expect(mockController.sentCommands, containsAllInOrder([
        'ATSH 797',
        'ATFCSH 797',
        'ATFCSM1',
        '03221156'
      ]));
      expect(result, equals({'gear_position': 'Drive'}));
    });

    test('12V Battery Command sequence and response', () async {
      final mockController = MockObdController('7EC 03 62 11 03 96');
      OBDCommand.setObdController(mockController);
      
      final result = await OBDCommand.battery12v.run();

      expect(mockController.sentCommands, containsAllInOrder([
        'ATSH 797',
        'ATFCSH 797',
        'ATFCSM1',
        '03221103'
      ]));
      expect(result, equals({'bat_12v_voltage': 12.0}));
    });

    test('Error response handling', () async {
      final mockController = MockObdController('NO DATA');
      OBDCommand.setObdController(mockController);
      
      final result = await OBDCommand.lbc.run();

      // Commands should still be sent even if response fails
      expect(mockController.sentCommands, containsAllInOrder([
        'ATSH 79B',
        'ATFCSH 79B',
        'ATFCSM1',
        '022101'
      ]));
      expect(result, equals({}));
    });

    test('CAN error handling', () async {
      final mockController = MockObdController('CAN ERROR');
      OBDCommand.setObdController(mockController);
      
      final result = await OBDCommand.lbc.run();
      expect(result, equals({}));
    });

    test('Empty response handling', () async {
      final mockController = MockObdController('');
      OBDCommand.setObdController(mockController);
      
      final result = await OBDCommand.lbc.run();
      expect(result, equals({}));
    });

    test('LBC decode function parses raw bytes correctly', () {
        // Test data representing:
        // - SOC: 85%
        // - Battery Health: 92%
        // - Battery capacity: 56Ah
        // - Battery voltage: 364V
        final testData = [
            0x62, 0x21,                         // 0-1: Header bytes
            0x00, 0x00, 0x00, 0x00,            // 2-5: Current1 (0A)
            0x00, 0x00,                         // 6-7: Padding
            0x00, 0x00, 0x00, 0x00,            // 8-11: Current2 (0A)
            0x00, 0x00, 0x00, 0x00,            // 12-15: Padding
            0x00, 0x00, 0x00, 0x00,            // 16-19: Padding
            0x8E, 0x30,                         // 20-21: Voltage (364V = 36400)
            0x00, 0x00, 0x00, 0x00,            // 22-25: Padding
            0x00, 0x00,                         // 26-27: Padding
            0x25, 0x1C,                         // 28-29: SOH (92% = 9500)
            0x00,                               // 30: Padding
            0x0C, 0xF8, 0x50,                   // 31-33: SOC (85% = 850000)
            0x08, 0x8B, 0x80,                   // 34-36: Battery Ah (56Ah = 560000)
            0x00                                // 37: Padding
        ];
        final result = OBDCommand.lbc.decode(testData);

        expect(result, equals({
            'state_of_charge': 85,
            'hv_battery_health': 92,
            'hv_battery_Ah': 56,
            'hv_battery_voltage': 364,
            'hv_battery_current_1': 0,
            'hv_battery_current_2': 0,
        }));
    });

    test('Odometer decode function parses raw bytes correctly', () {
        // Test data for 123456 
        final testData = [
            0x62, 0x0E, 0x01,  // Header bytes
            0x01, 0xE2, 0x40,  // 123456 in hex
            0x00, 0x00, 0x00  // Padding
        ];

        final result = OBDCommand.odometer.decode(testData);

        expect(result, equals({
            'odometer': 123456,
        }));
    });
    test('LBC Command handles multi-frame response end-to-end', () async {
        // Multi-frame response following ISO-TP format
        // First frame (0x10) indicates total length
        // Subsequent frames (0x21, 0x22, etc.) contain continuation data
        final mockResponse = '''
        7EC 10 26 62 21 00 00 00 00 
        7EC 21 00 00 00 00 00 00 00  
        7EC 22 00 00 00 00 00 00 00 
        7EC 23 8E 30 00 00 00 00 00 
        7EC 24 00 25 1C 00 0C F8 50 
        7EC 25 08 8B 80 00
        ''';

        final mockController = MockObdController(mockResponse);
        OBDCommand.setObdController(mockController);
        
        final result = await OBDCommand.lbc.run();

        // Verify command sequence
        expect(mockController.sentCommands, containsAllInOrder([
            'ATSH 79B',
            'ATFCSH 79B',
            'ATFCSM1',
            '022101'
        ]));

        // Verify decoded data
        expect(result, equals({
            'state_of_charge': 85,
            'hv_battery_health': 92,
            'hv_battery_Ah': 56,
            'hv_battery_voltage': 364,
            'hv_battery_current_1': 0,
            'hv_battery_current_2': 0,
        }));
    });
    test('LBC decode function handles longer response format', () {
        // Test data representing a longer response (>41 bytes):
        // - SOC: 85%
        // - Battery Health: 92%
        // - Battery capacity: 56Ah
        // - Battery voltage: 364V
        // - Current1: 0A
        // - Current2: 0A
        final testData = [
            0x62, 0x21,                         // 0-1: Header bytes
            0x00, 0x00, 0x00, 0x00,            // 2-5: Current1 (0A)
            0x00, 0x00,                         // 6-7: Padding
            0x00, 0x00, 0x00, 0x00,            // 8-11: Current2 (0A)
            0x00, 0x00, 0x00, 0x00,            // 12-15: Padding
            0x00, 0x00, 0x00, 0x00,            // 16-19: Padding
            0x8E, 0x30,                         // 20-21: Voltage (364V = 36400)
            0x00, 0x00, 0x00, 0x00,            // 22-25: Padding
            0x00, 0x00, 0x00, 0x00,            // 26-29: Padding
            0x25, 0x1C,                         // 30-31: SOH (92% = 9500)
            0x00,                               // 32: Padding
            0x0C, 0xF8, 0x50,                   // 33-35: SOC (85% = 850000)
            0x00,                               // 36: Padding
            0x08, 0x8B, 0x80,                   // 37-39: Battery Ah (56Ah = 560000)
            0x00,                               // 40: Padding
            0x00, 0x00, 0x00, 0x00             // 41-44: Additional padding to make length > 41
        ];

        final result = OBDCommand.lbc.decode(testData);

        expect(result, equals({
            'state_of_charge': 85,
            'hv_battery_health': 92,
            'hv_battery_Ah': 56,
            'hv_battery_voltage': 364,
            'hv_battery_current_1': 0,
            'hv_battery_current_2': 0,
        }));

        // Verify length is actually > 41
        expect(testData.length, greaterThan(41));
    });

    test('LBC Command handles longer multi-frame response end-to-end', () async {
        // Multi-frame response for longer data format
        // First frame (0x10) indicates total length of 44 bytes (0x2C)
        final mockResponse = '''
        7EC 10 2C 62 21 00 00 00 00 
        7EC 21 00 00 00 00 00 00 00 
        7EC 22 00 00 00 00 00 00 00 
        7EC 23 8E 30 00 00 00 00 00 
        7EC 24 00 00 00 25 1C 00 0C 
        7EC 25 F8 50 00 08 8B 80 00 
        7EC 26 00 00 00 00''';

        final mockController = MockObdController(mockResponse);
        OBDCommand.setObdController(mockController);
        
        final result = await OBDCommand.lbc.run();

        // Verify command sequence
        expect(mockController.sentCommands, containsAllInOrder([
            'ATSH 79B',
            'ATFCSH 79B',
            'ATFCSM1',
            '022101'
        ]));

        // Verify decoded data
        expect(result, equals({
            'state_of_charge': 85,
            'hv_battery_health': 92,
            'hv_battery_Ah': 56,
            'hv_battery_voltage': 364,
            'hv_battery_current_1': 0,
            'hv_battery_current_2': 0,
        }));
    });
  }); // End of group
} // End of main()
