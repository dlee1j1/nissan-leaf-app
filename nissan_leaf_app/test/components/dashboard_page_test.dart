import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/obd/bluetooth_device_manager.dart';
import 'package:nissan_leaf_app/pages/dashboard_page.dart';
import 'package:nissan_leaf_app/components/battery_status_widget.dart';
import 'package:nissan_leaf_app/components/readings_chart_widget.dart';

void main() {
  // Create mock LBC response that would be returned when connected to vehicle
  final mockLbcResponse = '''
  7BB10356101FFFFF060
  7BB210289FFFFE763FF
  7BB22FFCA4A09584650
  7BB239608383E038700
  7BB24017000239A000C
  7BB25814C00191FB580
  7BB260005FFFFE763FF
  7BB27FFE56501AEFFFF''';

  // Create mock range response
  final mockRangeResponse = '''
  7BB 03 62 0E 24 01 23''';

  group('DashboardPage', () {
    testWidgets('renders correctly without OBD controller', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DashboardPage(),
        ),
      );

      // Verify that the widget renders correctly
      expect(find.text('Nissan Leaf Battery Tracker'), findsOneWidget);

      // Should show the no connection message
      expect(find.text('No OBD Connection'), findsOneWidget);
      expect(find.text('Connect to Vehicle'), findsOneWidget);

      // Should still have the battery status and chart widgets (with default/empty values)
      expect(find.byType(BatteryStatusWidget), findsOneWidget);
      expect(find.byType(ReadingsChartWidget), findsAtLeastNWidgets(1));
    });

    testWidgets('renders correctly with OBD controller', (WidgetTester tester) async {
      // Set up mock mode in device manager
      final deviceManager = BluetoothDeviceManager.instance;
      deviceManager.enableMockMode(
        mockResponse: mockLbcResponse,
        mockRangeResponse: mockRangeResponse,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardPage(),
        ),
      );

      // Allow time for async operations
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // Verify that the widget renders correctly
      expect(find.text('Nissan Leaf Battery Tracker'), findsOneWidget);

      // Should not show the no connection message
      expect(find.text('No OBD Connection'), findsNothing);

      // Should have the battery status and chart widgets
      expect(find.byType(BatteryStatusWidget), findsOneWidget);
      expect(find.byType(ReadingsChartWidget), findsAtLeastNWidgets(1));

      deviceManager.disableMockMode();
    });

    testWidgets('shows refresh indicator when pulled down', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DashboardPage(),
        ),
      );

      // Drag down to show refresh indicator
      await tester.drag(find.byType(RefreshIndicator), const Offset(0, 300));
      await tester.pump();

      // Verify that refresh indicator is shown
      expect(find.byType(RefreshIndicator), findsOneWidget);
    });

    testWidgets('shows settings button in app bar', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DashboardPage(),
        ),
      );

      // Verify that settings button is present
      expect(find.byIcon(Icons.settings), findsOneWidget);

      // Tap settings button
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pump();

      // Now check for the menu items in the popup
      final mqttSettingsItem = find.widgetWithText(ListTile, 'MQTT Settings');
      final generalSettingsItem = find.widgetWithText(ListTile, 'General Settings');

      expect(mqttSettingsItem, findsOneWidget, reason: 'MQTT Settings menu item should be present');
      expect(generalSettingsItem, findsOneWidget,
          reason: 'General Settings menu item should be present');

/*
      // Tap the general settings option
      await tester.ensureVisible(generalSettingsItem);
      await tester.tap(generalSettingsItem);
      await tester.pumpAndSettle(); // Wait for navigation/action

      // Verify snackbar appears (since we don't have settings page yet)
      expect(find.text('Settings page coming soon'), findsOneWidget);
*/
    });
  });
}
