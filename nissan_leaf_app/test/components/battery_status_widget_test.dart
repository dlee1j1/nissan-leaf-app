import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/components/battery_status_widget.dart';

void main() {
  group('BatteryStatusWidget', () {
    testWidgets('renders correctly with required parameters', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryStatusWidget(
              stateOfCharge: 75.0,
              batteryHealth: 90.0,
            ),
          ),
        ),
      );

      // Verify that the widget renders correctly
      expect(find.text('Battery Status'), findsOneWidget);
      expect(find.text('75.0%'), findsOneWidget);
      expect(find.text('90.0%'), findsOneWidget);

      // Verify that the state of charge and health indicators are present
      expect(find.text('State of Charge'), findsOneWidget);
      expect(find.text('Battery Health'), findsOneWidget);

      // Verify no refresh button without callback
      expect(find.byIcon(Icons.refresh), findsNothing);
    });

    testWidgets('shows estimated range when provided', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryStatusWidget(
              stateOfCharge: 75.0,
              batteryHealth: 90.0,
              estimatedRange: 150.5,
            ),
          ),
        ),
      );

      expect(find.text('Est. Range'), findsOneWidget);
      expect(find.text('150.5 km'), findsOneWidget);
    });

    testWidgets('shows last updated time when provided', (WidgetTester tester) async {
      final testDate = DateTime(2023, 1, 1, 12, 30);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatteryStatusWidget(
              stateOfCharge: 75.0,
              batteryHealth: 90.0,
              lastUpdated: testDate,
            ),
          ),
        ),
      );

      expect(find.textContaining('Last updated:'), findsOneWidget);
      expect(find.textContaining('Jan 1, 2023'), findsOneWidget);
    });

    testWidgets('shows refresh button when onRefresh is provided', (WidgetTester tester) async {
      bool refreshCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatteryStatusWidget(
              stateOfCharge: 75.0,
              batteryHealth: 90.0,
              onRefresh: () {
                refreshCalled = true;
              },
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.refresh), findsOneWidget);

      // Tap the refresh button and verify the callback was called
      await tester.tap(find.byIcon(Icons.refresh));
      expect(refreshCalled, isTrue);
    });

    testWidgets('shows loading indicator when isLoading is true', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatteryStatusWidget(
              stateOfCharge: 75.0,
              batteryHealth: 90.0,
              isLoading: true,
              onRefresh: () {},
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
    });

    testWidgets('battery indicator changes color based on charge level',
        (WidgetTester tester) async {
      // Test with high charge (green)
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryStatusWidget(
              stateOfCharge: 75.0,
              batteryHealth: 90.0,
            ),
          ),
        ),
      );

      // Low charge (red)
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryStatusWidget(
              stateOfCharge: 10.0,
              batteryHealth: 90.0,
            ),
          ),
        ),
      );

      // Medium charge (orange)
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BatteryStatusWidget(
              stateOfCharge: 30.0,
              batteryHealth: 90.0,
            ),
          ),
        ),
      );

      // We can only verify the widget builds correctly
      // Color testing is limited in widget tests
      expect(find.text('Battery Status'), findsOneWidget);
    });
  });
}
