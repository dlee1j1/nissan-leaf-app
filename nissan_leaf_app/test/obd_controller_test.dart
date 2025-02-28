import 'package:test/test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nissan_leaf_app/obd_controller.dart';
import 'dart:convert';
import 'dart:async';

class MockBluetoothCharacteristic extends BluetoothCharacteristic {
  final _controller = StreamController<List<int>>.broadcast();
  List<List<int>> writtenValues = [];
  Function(List<int>)? responseHandler;

  MockBluetoothCharacteristic()
      : super(
            remoteId: DeviceIdentifier("mock_device"),
            serviceUuid: Guid("00000000-0000-0000-0000-000000000000"),
            characteristicUuid: Guid("00000000-0000-0000-0000-000000000000"));

  @override
  Stream<List<int>> get value => _controller.stream;

  void addResponse(String response) {
    _controller.add(utf8.encode(response));
  }

  @override
  Future<void> write(List<int> value,
      {bool withoutResponse = false, bool allowLongWrite = false, int timeout = 15}) async {
    writtenValues.add(value);

    // Use response handler if set, otherwise default behavior
    if (responseHandler != null) {
      Future.delayed(Duration(milliseconds: 10)).then((_) => responseHandler!(value));
    } else {
      Future.delayed(Duration(milliseconds: 10)).then((_) {
        if (utf8.decode(value).trim() == 'ATZ') {
          addResponse('ELM327 v1.5\r\r>');
        } else {
          addResponse('OK\r\r>');
        }
      });
    }
    return Future.value();
  }

  @override
  Future<bool> setNotifyValue(bool notify,
      {int timeout = 15, bool forceIndications = false}) async {
    return Future.value(true);
  }
}

void main() {
  group('ObdController Tests', () {
    late MockBluetoothCharacteristic mockCharacteristic;
    late ObdController controller;

    setUp(() {
      mockCharacteristic = MockBluetoothCharacteristic();
      controller = ObdController(mockCharacteristic);
    });

    tearDown(() {
      mockCharacteristic._controller.close();
      mockCharacteristic.responseHandler = null;
    });

    test('initialization sequence completes successfully', () async {
      await controller.initialize();

      expect(mockCharacteristic.writtenValues.length, 8);
      expect(utf8.decode(mockCharacteristic.writtenValues[0]), contains('ATZ'));
    });

    test('sendCommand handles command echo correctly', () async {
      final response = await controller.sendCommand('0100');
      expect(response, 'OK');
      expect(mockCharacteristic.writtenValues.last, utf8.encode('0100\r'));
    });

    test('sendCommand retries on non-OK response when expectOk is true', () async {
      var attemptCount = 0;

      mockCharacteristic.responseHandler = (value) {
        attemptCount++;
        if (attemptCount < 3) {
          mockCharacteristic.addResponse('ERROR\r\r>');
        } else {
          mockCharacteristic.addResponse('OK\r\r>');
        }
      };

      final response = await controller.sendCommand('TEST', expectOk: true);
      expect(response, 'OK');
      expect(mockCharacteristic.writtenValues.length, 3);
    });
  });
}
