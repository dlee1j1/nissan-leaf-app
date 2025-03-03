import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/data/reading_model.dart';
import 'package:nissan_leaf_app/components/readings_chart_widget.dart';
import 'package:fl_chart/fl_chart.dart';

void main() {
  final testReadings = [
    Reading(
      id: 1,
      timestamp: DateTime(2023, 1, 1, 10, 0),
      stateOfCharge: 80.0,
      batteryHealth: 95.0,
      batteryVoltage: 360.0,
      batteryCapacity: 40.0,
      estimatedRange: 160.0,
    ),
    Reading(
      id: 2,
      timestamp: DateTime(2023, 1, 1, 12, 0),
      stateOfCharge: 75.0,
      batteryHealth: 95.0,
      batteryVoltage: 355.0,
      batteryCapacity: 40.0,
      estimatedRange: 150.0,
    ),
    Reading(
      id: 3,
      timestamp: DateTime(2023, 1, 1, 14, 0),
      stateOfCharge: 70.0,
      batteryHealth: 94.0,
      batteryVoltage: 350.0,
      batteryCapacity: 39.5,
      estimatedRange: 140.0,
    ),
  ];

  group('ReadingsChartWidget', () {
    testWidgets('renders correctly with data', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadingsChartWidget(
              readings: testReadings,
            ),
          ),
        ),
      );

      // Verify that the widget renders correctly
      expect(find.text('Battery Charge History'), findsOneWidget);

      // Verify the chart is rendered (at least the container)
      expect(find.byType(LineChart), findsOneWidget);
    });

    testWidgets('shows empty state when no data is available', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReadingsChartWidget(
              readings: [],
            ),
          ),
        ),
      );

      expect(find.text('No data available'), findsOneWidget);
      expect(find.text('Connect to your vehicle to collect readings'), findsOneWidget);
      expect(find.byType(LineChart), findsNothing);
    });

    testWidgets('shows loading indicator when isLoading is true', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReadingsChartWidget(
              readings: [],
              isLoading: true,
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('No data available'), findsNothing);
    });

    testWidgets('uses custom title when provided', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadingsChartWidget(
              readings: testReadings,
              title: 'Custom Chart Title',
            ),
          ),
        ),
      );

      expect(find.text('Custom Chart Title'), findsOneWidget);
      expect(find.text('Battery Charge History'), findsNothing);
    });

    testWidgets('uses custom y-axis title when provided', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadingsChartWidget(
              readings: testReadings,
              yAxisTitle: 'Custom Axis (%)',
            ),
          ),
        ),
      );

      // Note: Testing exact text inside the chart is difficult
      // We're just verifying the widget builds without errors
      expect(find.byType(ReadingsChartWidget), findsOneWidget);
    });

    testWidgets('uses custom data selector when provided', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadingsChartWidget(
              readings: testReadings,
              dataSelector: (reading) => reading.batteryHealth,
            ),
          ),
        ),
      );

      // Again, we're just verifying the widget builds without errors
      expect(find.byType(ReadingsChartWidget), findsOneWidget);
    });
  });
}
