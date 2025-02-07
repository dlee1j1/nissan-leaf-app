import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:collection';

class ObdCommandError extends Error {
  final String command;
  final String response;
  
  ObdCommandError(this.command, this.response);
  
  @override
  String toString() => 'OBD Command Error: $command returned $response';
}

class ObdController {
  final BluetoothCharacteristic characteristic;
  final _responseQueue = Queue<String>();

  bool _initialized = false;

  ObdController(this.characteristic) {
    _setupNotifications();
  }

  void _handleNotification(List<int> value) {
    var response = utf8.decode(value).replaceAll('\x00', '').trim();
    print('Received notification: $response');
    _responseQueue.add(response);
  }

  Future<void> _setupNotifications() async {
    print('Setting up notifications...');
    await characteristic.setNotifyValue(true);
    characteristic.value.listen(_handleNotification);
    print('Notifications set up.');
  }


  Future<String> sendCommand(String command, {bool expectOk = false}) async {

    // Inner function to send the command
    //  this function sends the command, waits for >, cleans out the > and returns the response
    //  OK handling and retries are done by the outer function
    Future<String> _sendCommandInner(String command) async {
      final ELM_PROMPT = '>';
      final TIMEOUT = Duration(seconds: 5);

      var buffer = '';
      var startTime = DateTime.now();

      await Future.delayed(Duration(milliseconds: 100)); // Wait for the notification to be processed
      _responseQueue.clear(); // Clear the queue

        // Send the command
      print('Sending command: $command');
      await characteristic.write(utf8.encode(command + '\r'));

      // Wait for the response
      print('Waiting for response...');

      while (true) { // while we don't see the ELM_PROMPT

        // Wait for a response  
        while (_responseQueue.isEmpty) {
          // Check for timeout
          if (DateTime.now().difference(startTime) > TIMEOUT) {
            print('Timeout waiting for response to command: $command');
            throw ObdCommandError(command, 'Timeout waiting for response');
          }
          await Future.delayed(Duration(milliseconds: 100));
        }

        // Process the response
        while (_responseQueue.isNotEmpty) {
          var chunk = _responseQueue.removeFirst();
          print('Received chunk: $chunk');
          if (chunk == command) continue; // Skip the command echo
          if (chunk.contains(ELM_PROMPT)) {
            buffer += chunk.replaceAll(ELM_PROMPT, '').trim();
            return buffer;
          }
          buffer += chunk;
          // Debug: Print the buffer content
          print('Buffer content: $buffer');
        } 
      }  // end of ELM_PROMPT loop

      // we should never get here
      throw Exception('BUG BUG BUG - should never get here');

    } // End of _sendCommandInner()


    // ----
    // main body of sendCommand() here. Really most of the work is done in _sendCommandInner()
    // But we do retries and "OK" checking here
    final RETRY_DELAY = Duration(milliseconds: 100);
    final MAX_RETRIES = 3;
  
    for (var retryCount = 0; retryCount < MAX_RETRIES; retryCount++) {
      // Send the command
      var response = await _sendCommandInner(command);

      // Check for "OK" if required
      if (!expectOk || response.contains('OK')) {
        print('Command successful: $command');
        return response;
      }

      // If we expected "OK" but didn't get it, retry
      print('Retrying command: $command (attempt ${retryCount + 1}/$MAX_RETRIES)');
      await Future.delayed(RETRY_DELAY);
    } // end retry loop 

    print('Max retries reached for command: $command');
    throw ObdCommandError(command, 'Max retries reached');

  }  // End of sendCommand()

  Future<void> initialize() async {
    if (_initialized) return;
  
    try {
      print('Initializing OBD controller...');
      await sendCommand('ATZ', expectOk: false);  // ATZ can return junk
      await Future.delayed(Duration(seconds: 1));
    
      await sendCommand('ATE0', expectOk: true);  // Echo off
      await sendCommand('ATSP6', expectOk: true); // Protocol 6
      await sendCommand('ATH1', expectOk: true);  // Headers on
      await sendCommand('ATL0', expectOk: true);  // Linefeeds off
      await sendCommand('ATS0', expectOk: true);  // Spaces off
      await sendCommand('ATCAF0', expectOk: true); // CAN formatting off
      await sendCommand('ATFCSD300000', expectOk: true); //set flow control 
      await sendCommand('ATFCSM1', expectOk: true);  // Set flow control mode
//  await sendCommand('ATAT2', expectOk: true);  // adaptive timing mode 
    //  await sendCommand('ATST08', expectOk: true); // timeout 
    
      _initialized = true;
      print('OBD controller initialized.');
    } catch (e) {
      _initialized = false;
      print('Initialization failed: $e');
      rethrow;
    }
  }
/*
    Future<Map<String, dynamic>> readLBCData() async {
      print('Reading LBC data...');

      // Step 1: Set the header
      await sendCommand('ATSH 79B', expectOk: true);
      print('Header set to 79B');

      // Step 2: Send the LBC command
      var response = await sendCommand('022101');
      print('Raw LBC response: $response');

      // Step 3: Decode the response
      var bytes = utf8.encode(response);

      // Ensure the response is not empty
      if (bytes.isEmpty) {
        print('Empty LBC response, returning empty data');
        return {};
      }

      // Extract SOC, SOH, and other data (adjust byte ranges as needed)
      var soc = int.fromBytes(bytes.sublist(33, 37)) / 10000; // SOC in bytes 33-36
      var soh = int.fromBytes(bytes.sublist(30, 32)) / 102.4; // SOH in bytes 30-32
      var batteryAh = int.fromBytes(bytes.sublist(37, 40)) / 10000; // Battery capacity in bytes 37-40
      var hvBatteryVoltage = int.fromBytes(bytes.sublist(20, 22)) / 100; // HV battery voltage in bytes 20-22

      print('Parsed LBC data: SOC=$soc%, SOH=$soh%, BatteryAh=$batteryAh, HVVoltage=$hvBatteryVoltage');

      return {
        'state_of_charge': soc,
        'hv_battery_health': soh,
        'hv_battery_Ah': batteryAh,
        'hv_battery_voltage': hvBatteryVoltage,
      };
    } // End of readLBCData()
  */    
} // End of OBDController class