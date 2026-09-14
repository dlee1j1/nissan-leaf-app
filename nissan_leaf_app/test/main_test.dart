import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/main.dart';
import 'package:nissan_leaf_app/components/log_viewer.dart';

// Regression tests for onBackgroundServiceData - the #20 follow-up that lets
// the background service isolate's own logs reach the UI's LogViewer over
// the same sendDataToMain/addTaskDataCallback channel used for
// getStatus/refreshNow, instead of only ever showing what the UI isolate did.
void main() {
  setUp(() => LogViewer.clearLogs());

  group('onBackgroundServiceData', () {
    test('forwards a log message into LogViewer with a [Service] prefix', () {
      onBackgroundServiceData({'type': 'log', 'message': 'connecting to OBDBLE'});

      expect(LogViewer.logs, ['[Service] connecting to OBDBLE']);
    });

    test('ignores messages that are not the log type', () {
      onBackgroundServiceData({'type': 'status', 'connected': true});

      expect(LogViewer.logs, isEmpty);
    });

    test('ignores malformed data without crashing', () {
      onBackgroundServiceData('not a map');

      expect(LogViewer.logs, isEmpty);
    });
  });
}
