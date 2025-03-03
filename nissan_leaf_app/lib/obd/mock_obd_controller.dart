import 'obd_controller.dart';

class MockObdController extends ObdController {
  final String mockResponse;
  final List<String> sentCommands = [];

  // Additional mock responses for specific commands
  String? mockRangeResponse;
  Map<String, String> commandResponses = {};

  MockObdController(this.mockResponse) : super.test();

  @override
  Future<String> sendCommand(String command, {bool expectOk = true}) async {
    sentCommands.add(command);

    // Return appropriate response based on command
    if (command == '03220e24' && mockRangeResponse != null) {
      return mockRangeResponse!;
    }

    // Check if we have a specific response for this command
    if (commandResponses.containsKey(command)) {
      return commandResponses[command]!;
    }

    // Default response
    return mockResponse;
  }

  // Helper method to set responses for specific commands
  void setCommandResponse(String command, String response) {
    commandResponses[command] = response;
  }
}
