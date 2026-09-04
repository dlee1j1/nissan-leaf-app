import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:nissan_leaf_app/data_orchestrator.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// Custom mock for DirectOBDOrchestrator (needs a real status stream).
class MockDirectOBDOrchestrator extends Mock implements DirectOBDOrchestrator {
  final StreamController<Map<String, dynamic>> _statusController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  @override
  void dispose() {
    _statusController.close();
  }
}

// Fakes for the platform interfaces the heartbeat / prerequisite code touches.
class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.basePath);
  final String basePath;

  @override
  Future<String?> getApplicationDocumentsPath() async => basePath;
  @override
  Future<String?> getApplicationSupportPath() async => basePath;
  @override
  Future<String?> getTemporaryPath() async => basePath;
}

class _FakePermissionHandler extends PermissionHandlerPlatform with MockPlatformInterfaceMixin {
  _FakePermissionHandler(this.status);
  final PermissionStatus status;

  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) async => status;
  @override
  Future<ServiceStatus> checkServiceStatus(Permission permission) async => ServiceStatus.enabled;
  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(List<Permission> permissions) async =>
      {for (final p in permissions) p: status};
  @override
  Future<bool> openAppSettings() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDirectOBDOrchestrator mockOrchestrator;
  late BackgroundService backgroundService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mockOrchestrator = MockDirectOBDOrchestrator();
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(DateTime.now());
  });

  tearDown(() {
    BackgroundService.resetForTesting();
    mockOrchestrator.dispose();
  });

  group('Service Logic', () {
    setUp(() async {
      BackgroundService.resetForTesting();
      backgroundService = BackgroundService(orchestrator: mockOrchestrator);
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => true);

      // Await it so the initial execute() finishes before any test body runs.
      await backgroundService.onStart(DateTime.now(), TaskStarter.system);

      reset(mockOrchestrator);
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => true);
    });

    test('collectData uses orchestrator and handles success', () async {
      reset(mockOrchestrator);
      clearInteractions(mockOrchestrator);
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => true);
      backgroundService.setOrchestratorForTesting(mockOrchestrator);

      final result = await backgroundService.collectData();

      expect(result, true);
      verify(() => mockOrchestrator.collectData()).called(1);
    });

    test('collectData handles errors and reports them', () async {
      final testOrchestrator = MockDirectOBDOrchestrator();
      when(() => testOrchestrator.collectData())
          .thenAnswer((_) => Future.error(Exception('Test error')));
      backgroundService.setOrchestratorForTesting(testOrchestrator);

      final result = await backgroundService.collectData();
      expect(result, false);
      testOrchestrator.dispose();
    });
  });

  group('Heartbeat and prerequisites', () {
    late Directory tempDir;
    late PathProviderPlatform originalPathProvider;
    late PermissionHandlerPlatform originalPermissionHandler;

    setUp(() async {
      BackgroundService.resetForTesting();
      tempDir = await Directory.systemTemp.createTemp('heartbeat_test');
      originalPathProvider = PathProviderPlatform.instance;
      originalPermissionHandler = PermissionHandlerPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      PermissionHandlerPlatform.instance = _FakePermissionHandler(PermissionStatus.granted);
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => true);
    });

    tearDown(() async {
      BackgroundService.resetForTesting();
      PathProviderPlatform.instance = originalPathProvider;
      PermissionHandlerPlatform.instance = originalPermissionHandler;
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    File heartbeatLog() => File('${tempDir.path}/service_heartbeat.log');

    test('onStart writes a start line and a per-cycle line to the heartbeat log', () async {
      backgroundService = BackgroundService();
      backgroundService.setOrchestratorForTesting(mockOrchestrator);

      await backgroundService.onStart(DateTime.now(), TaskStarter.system);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(heartbeatLog().existsSync(), isTrue);
      final contents = await heartbeatLog().readAsString();
      expect(contents, contains('start (system)'));
      expect(contents, contains('cycle trigger='));
    });

    test('onStart stops the service and logs an abort when a permission is missing', () async {
      PermissionHandlerPlatform.instance = _FakePermissionHandler(PermissionStatus.denied);

      backgroundService = BackgroundService();
      backgroundService.setOrchestratorForTesting(mockOrchestrator);
      clearInteractions(mockOrchestrator);

      await backgroundService.onStart(DateTime.now(), TaskStarter.system);

      verifyNever(() => mockOrchestrator.collectData());
      final contents = await heartbeatLog().readAsString();
      expect(contents, contains('abort - missing prerequisites'));
    });

    test('stops itself after N consecutive failed cycles', () async {
      backgroundService = BackgroundService();
      backgroundService.setOrchestratorForTesting(mockOrchestrator);
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => false);

      for (var i = 0; i < BackgroundService.maxConsecutiveFailures; i++) {
        await backgroundService.collectData();
      }

      final contents = await heartbeatLog().readAsString();
      expect(contents, contains('stop:'));
      expect(contents, contains('failed cycles'));

      // Once stopped, further cycles are dropped without touching the orchestrator.
      clearInteractions(mockOrchestrator);
      final result = await backgroundService.collectData();
      expect(result, false);
      verifyNever(() => mockOrchestrator.collectData());
    });
  });
}
