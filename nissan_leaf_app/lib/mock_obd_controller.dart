import 'obd_controller.dart';

class MockObdController extends ObdController {
  final String mockResponse;
  final List<String> sentCommands = [];

  MockObdController(this.mockResponse) : super.test();

  @override
  Future<String> sendCommand(String command, {bool expectOk = true}) async {
    sentCommands.add(command);
    return mockResponse;
  }
}
