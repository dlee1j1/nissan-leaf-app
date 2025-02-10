import 'obd_controller.dart';

class MockObdController extends ObdController {
  final String mockResponse;

  MockObdController(this.mockResponse) : super.test();

  @override
  Future<String> sendCommand(String command, {bool expectOk = true}) async {
    return mockResponse;
  }
}
