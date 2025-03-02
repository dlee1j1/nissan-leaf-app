import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:collection';
import 'package:simple_logger/simple_logger.dart';

class ObdCommandError extends Error {
  final String command;
  final String response;

  ObdCommandError(this.command, this.response);

  @override
  String toString() => 'OBD Command Error: $command returned $response';
}

class ObdController {
  final BluetoothCharacteristic? characteristic;
  final _responseQueue = Queue<String>();

  bool _initialized = false;

  ObdController(this.characteristic) {
    _setupNotifications();
  }

  // Test constructor
  ObdController.test() : characteristic = null;

  void _handleNotification(List<int> value) {
    var response = utf8.decode(value).replaceAll('\x00', '');
    _log.fine('Received notification: $response');
    _responseQueue.add(response);
  }

  Future<void> _setupNotifications() async {
    _log.info('Setting up notifications...');
    await characteristic?.setNotifyValue(true);
    characteristic?.lastValueStream.listen(_handleNotification);
    _log.info('Notifications set up.');
  }

  Future<String> sendCommand(String command, {bool expectOk = false}) async {
    // Inner function to send the command
    //  this function sends the command, waits for >, cleans out the > and returns the response
    //  OK handling and retries are done by the outer function
    Future<String> sendCommandInner(String command) async {
      // ignore: constant_identifier_names
      const ELM_PROMPT = '>';
      final timeOut = Duration(seconds: 5);

      var buffer = '';
      var startTime = DateTime.now();

      await Future.delayed(
          Duration(milliseconds: 100)); // Wait for the notification to be processed
      _responseQueue.clear(); // Clear the queue

      // Send the command
      _log.info('Sending command: $command');
      await characteristic?.write(utf8.encode('$command\r'));

      // Wait for the response
      _log.info('Waiting for response...');

      while (true) {
        // while we don't see the ELM_PROMPT

        // Wait for a response
        while (_responseQueue.isEmpty) {
          // Check for timeout
          if (DateTime.now().difference(startTime) > timeOut) {
            _log.warning('Timeout waiting for response to command: $command');
            throw ObdCommandError(command, 'Timeout waiting for response');
          }
          await Future.delayed(Duration(milliseconds: 100));
        }

        // Process the response
        while (_responseQueue.isNotEmpty) {
          var chunk = _responseQueue.removeFirst();
          _log.fine('Received chunk: $chunk');
          if (chunk.trim() == command) continue; // Skip the command echo
          if (chunk.contains(ELM_PROMPT)) {
            buffer += chunk.replaceAll(ELM_PROMPT, '').trim();
            return buffer;
          }
          buffer += chunk;
          // Debug: Print the buffer content
          _log.info('Buffer content: $buffer');
        }
      } // end of ELM_PROMPT loop

      // we should never get here
      // ignore: dead_code
      throw Exception("BUG BUG BUG - should never get here");
    } // End of sendCommandInner()

    // ----
    // main body of sendCommand() here. Really most of the work is done in _sendCommandInner()
    // But we do retries and "OK" checking here
    final retryDelay = Duration(milliseconds: 100);
    final maxRetries = 3;

    for (var retryCount = 0; retryCount < maxRetries; retryCount++) {
      // Send the command
      var response = await sendCommandInner(command);

      // Check for "OK" if required
      if (!expectOk || response.contains('OK')) {
        _log.info('Command successful: $command');
        return response;
      }

      // If we expected "OK" but didn't get it, retry
      _log.warning('Retrying command: $command (attempt ${retryCount + 1}/$maxRetries)');
      await Future.delayed(retryDelay);
    } // end retry loop

    _log.severe('Max retries reached for command: $command');
    throw ObdCommandError(command, 'Max retries reached');
  } // End of sendCommand()

  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _log.info('Initializing OBD controller...');
      await sendCommand('ATZ', expectOk: false); // ATZ can return junk
      await Future.delayed(Duration(seconds: 1));

      await sendCommand('ATE0', expectOk: true); // Echo off
      await sendCommand('ATSP6', expectOk: true); // Protocol 6
      await sendCommand('ATH1', expectOk: true); // Headers on
      await sendCommand('ATL0', expectOk: true); // Linefeeds off
      await sendCommand('ATS0', expectOk: true); // Spaces off
      await sendCommand('ATCAF0', expectOk: true); // CAN formatting off
      await sendCommand('ATFCSD300000', expectOk: true); //set flow control

      _initialized = true;
      _log.info('OBD controller initialized.');
    } catch (e) {
      _initialized = false;
      _log.severe('Initialization failed: $e');
      rethrow;
    }
  }

  static final _log = SimpleLogger();
} // End of OBDController class
