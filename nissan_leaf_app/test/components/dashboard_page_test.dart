import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/pages/dashboard_page.dart';
import 'package:nissan_leaf_app/components/battery_status_widget.dart';
import 'package:nissan_leaf_app/components/readings_chart_widget.dart';

void main() {
  group('DashboardPage', () {
/*
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
*/
    testWidgets('renders correctly with OBD controller', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DashboardPage(),
        ),
      );

      // Allow time for async operations
      await tester.pump();

      // Verify that the widget renders correctly
      expect(find.text('Nissan Leaf Battery Tracker'), findsOneWidget);

      // Should not show the no connection message
      expect(find.text('No OBD Connection'), findsNothing);

      // Should have the battery status and chart widgets
      expect(find.byType(BatteryStatusWidget), findsOneWidget);
      expect(find.byType(ReadingsChartWidget), findsAtLeastNWidgets(1));
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
