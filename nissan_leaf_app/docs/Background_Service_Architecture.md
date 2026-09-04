# Background Data Collection System

The Background Service architecture handles automated data collection from the vehicle's OBD system. Metrics are only interesting while driving, so collection is tied to a Bluetooth signal that means "you're in the car" rather than run continuously. A manifest-declared broadcast receiver starts the foreground service when the phone connects to the Leaf's Bluetooth (or to the OBD dongle); the service later stops itself once it can no longer reach the dongle. Nothing runs in between, so there is nothing for Android to reclaim.

*[Return to main documentation](../README.md)*

## Architecture Overview

```
   car powers on  →  phone reconnects to "MY LEAF" (and the OBD dongle)
                          │
              ┌───────────▼────────────┐   native, manifest-declared;
              │  ObdConnectionReceiver  │   runs with no live Dart process
              │  + ObdConnectionPolicy  │   ACL_CONNECTED → start service
              └───────────┬────────────┘   (no stop — service self-terminates)
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

1. **ObdConnectionReceiver** (native Kotlin) - the start trigger:
   - Manifest-declared `BroadcastReceiver` on `ACTION_ACL_CONNECTED` — delivered
     even when no app process is alive. Start only; no disconnect handling
     (`BluetoothDeviceManager` drops the dongle link every cycle by design, so
     disconnect is noise — the service self-terminates instead).
   - Starts the foreground service for a device it recognises: the Leaf head unit
     by name (default `MY LEAF`), or the OBD dongle by saved MAC (written after
     the first in-app connect) or name hint (`OBD` / `ELM`)
   - The head-unit link is classic Bluetooth, which Android auto-reconnects on
     ignition, so it is the match that actually fires with no app running; the
     dongle is BLE and Android will not reconnect it on its own. Either way the
     service does its real work against the dongle once awake.
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
   - Polls at a fixed interval; stops the service after N consecutive failed
     cycles (see Service Lifecycle / Collection Loop)
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

This is the canonical record of the "why" behind the design; there is
deliberately nothing about it in `CLAUDE.md`.

- **Let Android kill it.** Random death after hours, while surviving when
  freshly started, is the OS reclaiming resources — not a crash. So there is
  **no watchdog and no restart logic**: `android:stopWithTask="true"` on the
  foreground service turns off flutter_foreground_task's restart machinery (the
  5-second `RestartReceiver` alarm, the task-swipe alarm, `START_STICKY`). If
  Android kills the service mid-drive it stays dead until the next connection.
  Chasing that is a treadmill against every OEM battery manager.
- **A Bluetooth connection is the trigger, not a stored flag.** No persisted
  "service enabled" flag (it could only disagree with reality) and no boot
  receiver — a manifest receiver survives reboots without a live process.
- **Match the Leaf head unit, not just the dongle.** The dongle connection is
  the literal signal, but it is BLE and Android does not auto-reconnect BLE
  peripherals — so with nothing running, `ACL_CONNECTED` for the dongle may
  never fire. The phone↔head-unit link is classic Bluetooth, which the OS *does*
  reconnect on ignition. The head unit defaults to `MY LEAF`; the app is
  Leaf-only, so matching that name by substring costs no generality and needs no
  pairing or config. A renamed head unit falls back to the dongle match.
- **No stop signal, only self-termination.** Disconnect can't be the stop
  trigger — `BluetoothDeviceManager` drops the dongle link after every collection
  cycle by design. So the service polls at a fixed interval (the BT connection
  already established we're in the car — no backoff, no GPS/movement trigger, no
  `location` dependency) and stops itself after `maxConsecutiveFailures` cycles
  fail back to back.
- **`eventAction` is `nothing()`.** Scheduling is driven by `BackgroundService`'s
  own timer; the plugin's periodic `onRepeatEvent` wakeup is unused.
- **Revisit the model only if `service_heartbeat.log` shows missed or truncated
  drives.** That is the signal that "let it die" is actually costing data; short
  of it, resist adding reliability machinery.

## Key Components

### `android/.../ObdConnectionReceiver.kt` and `ObdConnectionPolicy.kt`

The native trigger, and start-only. `ObdConnectionReceiver` is a thin adapter: it
pulls the action, the `BluetoothDevice`, the `BLUETOOTH_CONNECT` permission state,
and the saved dongle MAC out of the framework, hands them to
`ObdConnectionPolicy.decide`, and carries out the result (`START` / `IGNORE`).
`ObdConnectionPolicy` is `isDriveTrigger` (saved dongle MAC, or a name hint:
`OBD` / `ELM` / `LEAF`) with no `android.*` imports, so it can be unit-tested
directly. There is no disconnect handling — see Service Lifecycle.

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

The core `TaskHandler`, running from the moment a recognised Bluetooth device
connects until it stops itself:

- Implements the `TaskHandler` interface from flutter_foreground_task
- `onStart`: writes a heartbeat line, re-checks required permissions (stops the
  service if any are missing), then collects once
- Polls at a **fixed** interval (`_baseInterval`, default 1 minute) — no backoff,
  because the BT connection already told us we're in the car
- Counts consecutive failed cycles; at `maxConsecutiveFailures` (5) it writes
  `stop: N failed cycles` to the heartbeat and calls `stopService()` — the dongle
  is unreachable, so we've almost certainly parked

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

## Collection Loop

Once started, the service just polls on a fixed timer — one collection every
`_baseInterval` (default 1 minute), no adaptation. The earlier design used
exponential backoff and a GPS/movement trigger to guess whether the car was on;
the Bluetooth connection answers that now, so both are gone (see issue #13).

Stopping is failure-driven, not disconnect-driven: `ObdConnectionReceiver` never
sends a stop, because `BluetoothDeviceManager` drops the dongle link after every
cycle by design. Instead the service tracks consecutive failed cycles and calls
`stopService()` at `maxConsecutiveFailures` (5) — ~5 minutes of not being able to
reach the dongle, i.e. parked. A transient dongle drop mid-drive costs at most a
few cycles before the next success resets the counter.

Known gap (out of scope, issue #13): a genuinely flaky dongle could rack up 5
failures *while still driving* and stop the service with no way to restart it
until the next connection. If real drives show that in `service_heartbeat.log`,
gate the self-terminate on a "still in the car" check — best signal is whether
the Leaf's Bluetooth (`MY LEAF`) is still connected, since that is the same
classic-BT link we trust to start on; a cheap fallback is "no successful
collection in the last ~10 minutes". (Not `ActivityRecognition` — its
`IN_VEHICLE` is too laggy and unreliable to gate on.)

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

- A failed collection just logs and schedules the next cycle at the normal
  interval; one success resets the consecutive-failure counter
- `maxConsecutiveFailures` failures in a row stops the service (see Collection
  Loop)
- MQTT errors are caught and don't prevent local storage

## Mock Mode

For testing or when no vehicle is available, a mock mode provides simulated data:

- Set via `AppState.instance.enableMockMode()`
- Uses predefined battery states from `mock_battery_states.dart`
- No actual OBD connection is attempted
- Helpful for development and demonstration

## Customizing Collection Behavior

To modify collection behavior:

1. **Poll interval** — `BackgroundService.updateCollectionFrequency(int minutes)`
   at runtime, or the `defaultFrequency` constant.
2. **When it gives up** — `BackgroundService.maxConsecutiveFailures` (default 5).
3. **What counts as the OBD dongle / the car** — `NAME_HINTS` in
   `ObdConnectionPolicy.kt`.
