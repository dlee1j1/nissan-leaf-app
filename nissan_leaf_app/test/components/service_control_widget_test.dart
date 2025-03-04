import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/components/service_control_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('ServiceControlWidget', () {
    testWidgets('renders correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ServiceControlWidget(),
          ),
        ),
      );

      // Allow time for async initialization
      await tester.pumpAndSettle();

      // Verify that the widget renders correctly
      expect(find.text('Background Service'), findsOneWidget);
      expect(find.text('Collection Frequency'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
    });
  });
}
