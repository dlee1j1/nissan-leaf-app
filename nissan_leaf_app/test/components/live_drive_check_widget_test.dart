import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/components/live_drive_check_widget.dart';
import 'package:nissan_leaf_app/obd/obd_command.dart';

void main() {
  group('LiveDriveCheckWidget', () {
    tearDown(() {
      OBDCommand.setTestRunOverride(null);
    });

    testWidgets('shows placeholders and a Start button before polling begins',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LiveDriveCheckWidget())),
      );

      expect(find.text('--'), findsAtLeastNWidgets(1));
      expect(find.widgetWithText(ElevatedButton, 'Start'), findsOneWidget);
    });

    testWidgets('polling shows decoded speed/odometer/ambient temp and can be stopped',
        (WidgetTester tester) async {
      var pollCount = 0;
      OBDCommand.setTestRunOverride((cmd) async {
        if (cmd == OBDCommand.speed) {
          pollCount++;
          return {'speed': 42.0};
        }
        if (cmd == OBDCommand.odometer) return {'odometer': 12345};
        if (cmd == OBDCommand.ambientTemp) return {'ambient_temp': 21.5};
        return {};
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LiveDriveCheckWidget(pollInterval: Duration(milliseconds: 100)),
          ),
        ),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Start'));
      await tester.pumpAndSettle();

      expect(find.text('42 km/h'), findsOneWidget);
      expect(find.text('Odometer: 12345 km'), findsOneWidget);
      expect(find.text('Ambient: 21.5°C'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Stop'), findsOneWidget);
      final firstPollCount = pollCount;
      expect(firstPollCount, greaterThanOrEqualTo(1));

      // Advance past another poll interval and confirm it polled again.
      await tester.pump(const Duration(milliseconds: 150));
      expect(pollCount, greaterThan(firstPollCount));

      // Stopping cancels the timer - no further polls once settled.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Stop'));
      await tester.pumpAndSettle();
      final countAfterStop = pollCount;
      await tester.pump(const Duration(milliseconds: 300));
      expect(pollCount, countAfterStop);
      expect(find.widgetWithText(ElevatedButton, 'Start'), findsOneWidget);
    });

    testWidgets('shows an error message if a command fails', (WidgetTester tester) async {
      OBDCommand.setTestRunOverride((cmd) async {
        throw Exception('no response');
      });

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LiveDriveCheckWidget())),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Start'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Error:'), findsOneWidget);

      // Stop before the test ends so no bare Timer outlives the widget tree.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Stop'));
      await tester.pumpAndSettle();
    });
  });
}
