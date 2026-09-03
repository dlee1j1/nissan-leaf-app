# Background Data Collection System

The Background Service architecture handles automated data collection from the vehicle's OBD system. Metrics are only interesting while driving, and the OBD dongle appears on Bluetooth when the car powers on — so collection is tied to that connection rather than run continuously. A manifest-declared broadcast receiver starts the foreground service when the dongle connects and stops it when the dongle disconnects; nothing runs in between, so there is nothing for Android to reclaim.

*[Return to main documentation](../README.md)*

## Architecture Overview

```
   car powers on  →  OBD dongle appears on BLE
                          │
              ┌───────────▼────────────┐   native, manifest-declared;
              │  ObdConnectionReceiver  │   runs with no live Dart process
              │  + ObdConnectionPolicy  │   ACL_CONNECTED    → start service
              └───────────┬────────────┘   ACL_DISCONNECTED  → stop service
                          │ startForegroundService()
──────────────────────────┼───────────────────────────  Platform API boundary
   ┌───────────────┐      │
   │ DashboardPage │──────┤   BackgroundServiceController
   └───────────────┘      │   - initialize(): notification channel, permissions
                          │   - startService() once at launch, only to persist
                          │     the notification options + Dart callback handle
                          ▼     that the receiver needs to start headless
        ┌─────────────────────────┐     ┌─────────────────────┐
        │ BackgroundService       │────▶│ DataOrchestrator    │
        │ (TaskHandler)           │     │  (Interface)        │
        │  onStart: heartbeat +   │     └──────────┬──────────┘
        │  permission re-check    │                ▼
        └─────────────────────────┘     ┌─────────────────────┐
                                        │ DirectOBDOrchestrator│
                                        └──────────┬──────────┘
                                                   ▼
                                        ┌─────────────────────┐
                                        │   OBDConnector      │
                                        └─────────────────────┘
```

## Three-Part Design

The background functionality is implemented as three distinct components:

1. **ObdConnectionReceiver** (native Kotlin) - the lifecycle trigger:
   - Manifest-declared `BroadcastReceiver` on `ACTION_ACL_CONNECTED` /
     `ACTION_ACL_DISCONNECTED` — delivered even when no app process is alive
   - Recognises the dongle by saved MAC (written after the first in-app connect)
     or a name hint, then starts / stops the foreground service
   - Starts it headless by reusing flutter_foreground_task's own restart path
     (write its service-status pref, then `startForegroundService`), which is why
     the Controller still calls `startService()` once at launch — to persist the
     notification options and Dart callback handle the receiver relies on
   - The decision logic lives in `ObdConnectionPolicy`, a pure class with no
     `android.*` imports so it is unit-testable without a device

2. **BackgroundServiceController** - UI-facing component that:
   - Handles platform-specific service initialization
   - Manages Android's foreground service notification
   - Takes care of permission requests
   - Persists service config at launch (see above); exposes manual start/stop

3. **BackgroundService** - Task-executing component that:
   - Implements the actual data collection logic
   - Re-checks required permissions in `onStart` (they can be revoked between
     drives) and stops the service if any are missing
   - Manages collection frequency and triggers
   - Orchestrates connection to the vehicle
   - Handles data storage and MQTT publishing
   - Appends a line to `service_heartbeat.log` on start, each collection cycle,
     and stop — the only way to confirm a drive was captured without a rig

This separation allows:
- Clean isolation of platform-specific code
- Better testability of the collection logic (and of the trigger policy)
- Proper dependency injection
- Clear boundaries of responsibility

## Service Lifecycle

- **The dongle's BLE presence is the source of truth.** There is no persisted
  "service enabled" flag and no boot receiver — a manifest receiver is registered
  from the package, so it already survives reboots without a live process.
- **No watchdog or restart logic.** `android:stopWithTask="true"` on the
  foreground service turns off flutter_foreground_task's restart machinery (the
  5-second `RestartReceiver` alarm, the task-swipe alarm, `START_STICKY`). If
  Android kills the service mid-drive it stays dead until the next connection;
  fighting that is a losing battle against OEM battery managers.
- **`eventAction` is `nothing()`.** Scheduling is driven by `BackgroundService`'s
  own timer; the plugin's periodic `onRepeatEvent` wakeup is unused.

## Key Components

### `android/.../ObdConnectionReceiver.kt` and `ObdConnectionPolicy.kt`

The native trigger. `ObdConnectionReceiver` is a thin adapter: it pulls the
action, the `BluetoothDevice`, the `BLUETOOTH_CONNECT` permission state, and the
saved dongle MAC out of the framework, hands them to `ObdConnectionPolicy.decide`,
and carries out the result (`START` / `STOP` / `IGNORE`). `ObdConnectionPolicy`
holds all the branching — dongle matching and the connect/disconnect mapping —
with no `android.*` imports, so it can be unit-tested directly.

### `background_service_controller.dart`

Boundary between the Flutter UI and the native foreground service. Key features:

- `initialize()` — notification channel, permission requests, `autoRunOnBoot: false`
- `startService()` — called once at launch; its job now is to persist the
  notification options and Dart callback handle so `ObdConnectionReceiver` can
  start the service headless later
- Manual `stopService()` / `isServiceRunning()`

```dart
// Example usage
await BackgroundServiceController.initialize();
await BackgroundServiceController.startService();
bool isRunning = await BackgroundServiceController.isServiceRunning();
await BackgroundServiceController.stopService();
```

### `background_service.dart`

The core `TaskHandler` that runs while the dongle is connected. Features:

- Implements the `TaskHandler` interface from flutter_foreground_task
- `onStart`: writes a heartbeat line, re-checks required permissions and stops
  the service if any are missing, then begins collecting
- Uses adaptive collection frequency
- Supports both timer-based and location-based triggers
- Implements error backoff strategy

```dart
// How the backoff algorithm works
Duration computeNextDuration(Duration current, Duration base, bool success) {
  if (success) {
    return base; // Reset to normal interval on success
  } else {
    // Exponential backoff with maximum limit
    return (current * 2 < maxDelay) ? current * 2 : maxDelay;
  }
}
```

### `data_orchestrator.dart`

Defines the interface and implementations for data collection strategies:

1. `DataOrchestrator` - The base interface
2. `DirectOBDOrchestrator` - Implementation using direct OBD connection
3. `MockDataOrchestrator` - Implementation providing simulated data

The orchestrator is responsible for:
- Connecting to the vehicle
- Collecting data points
- Storing readings in the database
- Publishing to MQTT (if enabled)
- Maintaining collection sessions

## Collection Triggers

The service uses two complementary approaches to trigger data collection:

1. **Timer-based collection**:
   - Uses a basic interval (default: 1 minute)
   - Adapts interval based on success/failure (exponential backoff)
   - Maximum interval: 30 minutes

2. **Location-based collection**:
   - Activates when device moves ~1600 meters (about 1 mile)
   - Triggered when wait time reaches 10 minutes (maxDelayBeforeGPS)
   - Helps resume collection when returning to vehicle

## Adaptive Collection Algorithm

The service dynamically adjusts collection frequency:

1. Start with base interval (1 minute)
2. On success: maintain base interval
3. On failure: double the interval (exponential backoff)
4. Cap at maximum interval (30 minutes)
5. At 10-minute interval (maxDelayBeforeGPS), enable location-based triggers
6. On any success: reset to base interval

This approach balances:
- Data collection frequency
- Battery consumption
- Connection attempts
- Recovery from temporary failures

## Sessions and Continuity

The service implements a session management system:

- Sessions are identified by a timestamp-based ID
- A session persists for 30 minutes of inactivity
- New sessions start automatically after inactivity
- Session IDs are included in MQTT data

This allows for logical grouping of data points, making it easier to:
- Identify charging cycles
- Track trips
- Correlate data with activities

## Error Handling

The service implements robust error handling:

- Connection failures are tracked
- Each error increments consecutive failure count
- Collection automatically resumes when conditions improve
- MQTT errors are caught and don't prevent local storage

## Mock Mode

For testing or when no vehicle is available, a mock mode provides simulated data:

- Set via `AppState.instance.enableMockMode()`
- Uses predefined battery states from `mock_battery_states.dart`
- No actual OBD connection is attempted
- Helpful for development and demonstration

## Customizing Collection Behavior

To modify collection behavior:

1. **Changing base interval**:
   ```dart
   // In BackgroundService
   void updateCollectionFrequency(int minutes) {
     _baseInterval = Duration(minutes: minutes);
   }
   ```

2. **Adjusting location trigger distance**:
   ```dart
   // In background_service.dart, modify:
   const double LOCATION_DISTANCE_FILTER = 1600.0; // meters (approx 1 mile)
   ```

3. **Changing maximum delay**:
   ```dart
   // In BackgroundService
   static const Duration maxDelay = Duration(minutes: 30);
   ```
