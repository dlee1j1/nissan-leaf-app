import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';

class ObdCommandError extends Error {
  final String command;
  final String response;
  
  ObdCommandError(this.command, this.response);
  
  @override
  String toString() => 'OBD Command Error: $command returned $response';
}

class ObdController {
  final BluetoothCharacteristic characteristic;
  bool _initialized = false;
  
  ObdController(this.characteristic); // Constructor

  Future<String> sendCommand(String command, {bool expectOk = false}) async {
    // utility function to check if a response is "OK"
    bool _isOk(String response) {
        if (response.isEmpty) return false;
        
        final lines = response.split('\r\n');
        return lines.length == 1 && lines[0].trim() == 'OK';
    }



    // Ensure initialization before any command
    if (!_initialized && command != 'ATZ') {
      await initialize();
    }
    await characteristic.write(utf8.encode(command + '\r'));
    var response = await characteristic.read();
    var responseStr = utf8.decode(response);

    if (expectOk && !_isOk(responseStr)) {
      throw ObdCommandError(command, responseStr);
    }

    return responseStr;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      await sendCommand('ATZ', expectOk: true);
      await Future.delayed(Duration(seconds: 1));
      
      await sendCommand('ATE0', expectOk: true);
      await sendCommand('ATSP6');
      await sendCommand('ATH1');
      await sendCommand('ATL0');
      await sendCommand('ATS0');
      await sendCommand('ATCAF0');
      await sendCommand('ATAT2');
      await sendCommand('ATST 08');
      
      _initialized = true;
    } catch (e) {
      _initialized = false;
      rethrow;
    }
  }

  Future<int> readBatterySOC() async {
    int parseSOCResponse(String response) {
        final hexStrings = response.split(' ');
        final values = hexStrings
            .map((s) => int.parse(s, radix: 16))
            .toList();
            
        if (hexStrings.isEmpty) return 0;
        final soc = int.parse(hexStrings[0], radix: 16);
        return soc;
    }

    // Using the same command as in the Python code
    var response = await sendCommand('022101');
    // Parse response and return battery percentage
    // Implementation needed based on the protocol
    return parseSOCResponse(response);
  }

}

