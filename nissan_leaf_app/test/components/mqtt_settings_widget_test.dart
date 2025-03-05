import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/app_state.dart';
import 'package:nissan_leaf_app/components/mqtt_settings_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MqttSettingsWidget', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppState.instance.disableMockMode();
    });

    testWidgets('renders correctly with default values', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MqttSettingsWidget(),
            ),
          ),
        ),
      );

      // Allow async operations to complete
      await tester.pumpAndSettle();

      // Verify that the widget renders correctly
      expect(find.text('MQTT Settings'), findsOneWidget);

      // Check for form fields
      expect(find.text('Broker Address'), findsOneWidget);
      expect(find.text('Port'), findsOneWidget);
      expect(find.text('Username (optional)'), findsOneWidget);
      expect(find.text('Password (optional)'), findsOneWidget);
      expect(find.text('Client ID'), findsOneWidget);
      expect(find.text('Topic Prefix'), findsOneWidget);

      // Check for buttons
      expect(find.text('Test Connection'), findsOneWidget);
      expect(find.text('Save Settings'), findsOneWidget);

      // Status should start as "Disconnected"
      expect(find.text('Status: Disconnected'), findsOneWidget);

      // Switch should start as disabled
      expect(find.text('Disabled'), findsOneWidget);
    });

    testWidgets('validates broker address input', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MqttSettingsWidget(),
            ),
          ),
        ),
      );

      // Allow async operations to complete
      await tester.pumpAndSettle();

      // Find the Test Connection button and tap it
      final testButton = find.text('Test Connection');
      await tester.tap(testButton);
      await tester.pumpAndSettle();

      // Should show validation error for empty broker
      expect(find.text('Please enter a broker address'), findsOneWidget);
    });

    testWidgets('validates port input', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MqttSettingsWidget(),
            ),
          ),
        ),
      );

      // Allow async operations to complete
      await tester.pumpAndSettle();

      // Enter a broker address but leave port empty
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Broker Address'), 'test.mosquitto.org');
      await tester.enterText(find.widgetWithText(TextFormField, 'Port'), '');

      // Find the Test Connection button and tap it
      final testButton = find.text('Test Connection');
      await tester.tap(testButton);
      await tester.pumpAndSettle();

      // Should show validation error for empty port
      expect(find.text('Please enter a port number'), findsOneWidget);
    });

    testWidgets('toggles password visibility', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MqttSettingsWidget(),
            ),
          ),
        ),
      );

      // Allow async operations to complete
      await tester.pumpAndSettle();

      // Enter a password
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Password (optional)'), 'test_password');

      // Find the visibility toggle button and tap it
      final visibilityButton = find.byIcon(Icons.visibility);
      await tester.tap(visibilityButton);
      await tester.pumpAndSettle();

      // Visibility icon should have changed
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });

    testWidgets('enables/disables MQTT with switch', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MqttSettingsWidget(),
            ),
          ),
        ),
      );

      // Allow async operations to complete
      await tester.pumpAndSettle();

      // Initially disabled
      expect(find.text('Disabled'), findsOneWidget);

      // Find the switch and tap it
      final switchWidget = find.byType(Switch);
      await tester.tap(switchWidget);
      await tester.pumpAndSettle();

      // Should now be enabled
      expect(find.text('Enabled'), findsOneWidget);
    });

    testWidgets('changes QoS level', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MqttSettingsWidget(),
            ),
          ),
        ),
      );

      // Allow async operations to complete
      await tester.pumpAndSettle();

      // Initially QoS 0
      expect(find.text('At most once (0)'), findsOneWidget);

      // Find the dropdown and tap it
      await tester.tap(find.text('At most once (0)'));
      await tester.pumpAndSettle();

      // Select QoS 1
      await tester.tap(find.text('At least once (1)').last);
      await tester.pumpAndSettle();

      // Should now show QoS 1
      expect(find.text('At least once (1)'), findsOneWidget);
    });
  });
}
