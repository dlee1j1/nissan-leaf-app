import 'package:test/test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nissan_leaf_app/obd/obd_controller.dart';
import 'dart:convert';
import 'dart:async';
import 'package:fake_async/fake_async.dart';
import '../utils/fake_async_utils.dart';
import 'package:mocktail/mocktail.dart';

class MockBluetoothCharacteristic extends Mock implements BluetoothCharacteristic {
  final _lastValueController = StreamController<List<int>>.broadcast();
  List<List<int>> writtenValues = [];
  Function(List<int>)? responseHandler;

  @override
  Stream<List<int>> get lastValueStream => _lastValueController.stream;

  // Set FakeAsync instance for time control
  FakeAsync? _fakeAsync;
  void setFakeAsync(FakeAsync fake) {
    _fakeAsync = fake;
  }

  void addResponse(String response) {
    _lastValueController.add(utf8.encode(response));
  }

  @override
  Future<void> write(List<int> value,
      {bool withoutResponse = false, bool allowLongWrite = false, int timeout = 15}) async {
    writtenValues.add(value);

    // Helper method to handle command response logic
    void delayedCommandResponse(List<int> value) {
      Future.delayed(Duration(milliseconds: 10), () {
        final command = utf8.decode(value).trim();
        if (command == 'ATZ') {
          addResponse('ELM327 v1.5\r\r>');
        } else if (responseHandler != null) {
          responseHandler!(value);
        } else {
          addResponse('OK\r\r>');
        }
      });
    }

    // Use FakeAsync for controlled timing if available
    if (_fakeAsync != null) {
      _fakeAsync!.run((fake) {
        delayedCommandResponse(value);
      });
    } else {
      delayedCommandResponse(value);
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
      mockCharacteristic._lastValueController.close();
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

    test('sendCommand times out after 5 seconds if no response received', () {
      runWithFakeAsync((fake) async {
        // Set up the mock characteristic with FakeAsync
        mockCharacteristic.setFakeAsync(fake);

        // Clear any existing mock behavior
        reset(mockCharacteristic);

        // Create a new characteristic that doesn't respond
        final nonRespondingCharacteristic = MockBluetoothCharacteristic();
        nonRespondingCharacteristic.setFakeAsync(fake);

        // Create a new controller with this characteristic
        final timeoutController = ObdController(nonRespondingCharacteristic);

        // Override the write method to do nothing (no response)
        when(() => nonRespondingCharacteristic.write(any(),
            withoutResponse: any(named: 'withoutResponse'),
            allowLongWrite: any(named: 'allowLongWrite'),
            timeout: any(named: 'timeout'))).thenAnswer((_) async {
          // Don't send any response - this will cause a timeout
          return Future.value();
        });

        // Send a command that should time out
        final commandFuture = timeoutController.sendCommand('TEST');

        // Advance time past the 5 second timeout
        fake.elapse(Duration(seconds: 6));

        // The command should throw an error due to timeout
        await expectLater(
            commandFuture,
            throwsA(isA<ObdCommandError>()
                .having((e) => e.response, 'response', 'Timeout waiting for response')));
      });
    });
    group('OBD Controller Timeout Tests with FakeAsync', () {
      test('sendCommand times out after 5 seconds if no response received', () {
        runWithFakeAsync((fake) async {
          // Set up the mock characteristic with FakeAsync
          mockCharacteristic.setFakeAsync(fake);

          // Clear any existing mock behavior
          reset(mockCharacteristic);

          // Create a new characteristic that doesn't respond
          final nonRespondingCharacteristic = MockBluetoothCharacteristic();
          nonRespondingCharacteristic.setFakeAsync(fake);

          // Create a new controller with this characteristic
          final timeoutController = ObdController(nonRespondingCharacteristic);

          // Override the write method to do nothing (no response)
          when(() => nonRespondingCharacteristic.write(any(),
              withoutResponse: any(named: 'withoutResponse'),
              allowLongWrite: any(named: 'allowLongWrite'),
              timeout: any(named: 'timeout'))).thenAnswer((_) async {
            // Don't send any response - this will cause a timeout
            return Future.value();
          });

          // Send a command that should time out
          final commandFuture = timeoutController.sendCommand('TEST');

          // Advance time past the 5 second timeout
          fake.elapse(Duration(seconds: 6));

          // The command should throw an error due to timeout
          await expectLater(
              commandFuture,
              throwsA(isA<ObdCommandError>()
                  .having((e) => e.response, 'response', 'Timeout waiting for response')));
        });
      });

      test('initialization retries commands that fail to get OK response', () {
        runWithFakeAsync((fake) async {
          // Set up the mock characteristic with FakeAsync
          mockCharacteristic.setFakeAsync(fake);

          int attemptCount = 0;

          // Override write to fail for a specific command then succeed
          mockCharacteristic.responseHandler = (value) {
            final command = utf8.decode(value).trim();
            if (command == 'ATE0') {
              attemptCount++;
              if (attemptCount < 3) {
                // First two attempts fail
                mockCharacteristic.addResponse('ERROR\r\r>');
              } else {
                // Third attempt succeeds
                mockCharacteristic.addResponse('OK\r\r>');
              }
            } else {
              // All other commands succeed
              mockCharacteristic.addResponse('OK\r\r>');
            }
          };

          // Initialize the controller
          await controller.initialize();

          // Verify retry attempts
          expect(attemptCount, 3);

          // Verify all commands were sent
          expect(mockCharacteristic.writtenValues.length, 8);
          expect(utf8.decode(mockCharacteristic.writtenValues[0]), contains('ATZ'));
          expect(utf8.decode(mockCharacteristic.writtenValues[1]), contains('ATE0'));
          expect(utf8.decode(mockCharacteristic.writtenValues[2]), contains('ATE0'));
          expect(utf8.decode(mockCharacteristic.writtenValues[3]), contains('ATE0'));
          expect(utf8.decode(mockCharacteristic.writtenValues[4]), contains('ATSP6'));
        });
      });
    });
  });
}
