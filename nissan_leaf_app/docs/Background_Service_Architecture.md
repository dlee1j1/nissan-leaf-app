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
                          ▼
══════════════════════════════════════════════════════  isolate boundary (#20)
  Background-task isolate (flutter_foreground_task spawns          Main UI isolate
  this fresh via backgroundServiceEntryPoint - see #20)         ┌───────────────┐
                                                                 │ DashboardPage │
        ┌─────────────────────────┐     ┌─────────────────────┐└──────┬────────┘
        │ BackgroundService       │────▶│ DataOrchestrator    │       │
        │ (TaskHandler)           │     │  (Interface)        │       │ DataOrchestratorFactory
        │  onStart: heartbeat +   │     └──────────┬──────────┘       │  .create(AppMode.real)
        │  permission re-check    │                ▼                 ▼
        │  onReceiveData: replies │     ┌─────────────────────┐ ┌─────────────────────────┐
        │  to getStatus/refreshNow│     │ DirectOBDOrchestrator│ │ BackgroundServiceOrchestr│
        └────────────┬────────────┘     └──────────┬──────────┘ │ ator (implements the same│
                     │ sendDataToMain               ▼            │ DataOrchestrator - never │
                     │ (IsolateNameServer,  ┌─────────────────┐  │ touches Bluetooth)       │
                     │  see #20)            │   OBDConnector  │  └───────────┬──────────────┘
                     │                      │  (real BLE)     │              │ sendDataToTask
                     └──────────────────────┴─────────────────┘              │ ('refreshNow'/
                                       ▲                                     │  'getStatus')
                                       │                                     │
                                readings.db ◀───────────────────────────────┘
                        (real file, safely reachable from both isolates -
                         the actual data transport; see "Two Isolates" below)
```

## Two Isolates: Why the UI Can't Just Share the Collector

`flutter_foreground_task` runs the `TaskHandler` (`BackgroundService`) in a
Dart isolate the plugin spawns specifically for it, separate from the main
UI isolate that builds the widget tree. This is unavoidable, not a design
choice: Android's foreground `Service` can outlive the `Activity` (this app
starts it headlessly, with no Activity ever having run), and Flutter's
engine/isolate is tied to whatever hosts it - there's no single isolate
that's guaranteed to exist across both.

Dart isolates share **no memory** - not "share carefully," not "share with a
lock," genuinely inaccessible. A `factory`/`static` singleton (`BackgroundService`,
`BluetoothDeviceManager`) only guarantees one instance *within the isolate
that constructed it*. Before #20, `DashboardPage` called
`DataOrchestratorFactory.create(AppMode.real)`, which constructed its own
`BackgroundService()` - a second, independent instance living in the main
isolate's memory, entirely unaware of the real one. Both, by default, built
their own `DirectOBDOrchestrator` → `OBDConnector` → `BluetoothDeviceManager`.
Isolate isolation protected the thing that didn't need it (neither instance
could corrupt the other's Dart heap) and did nothing for the thing that did:
both ultimately drove the same physical Bluetooth radio through
`flutter_blue_plus`, which talks to the OS Bluetooth stack regardless of
which isolate is asking. Confirmed on a real drive
(`PlatformException(writeCharacteristic, ... ERROR_GATT_WRITE_REQUEST_BUSY)`,
`FormatException: CAN Frame: Invalid frame length`, and 53 minutes of zero
database rows despite the receiver confirming the real service had started -
every reading that drive produced turned out to trace back to the dashboard
being open, not the headless service).

**Fix: the UI never touches Bluetooth. It messages the real service.**
`BackgroundServiceOrchestrator` (UI isolate) implements the same
`DataOrchestrator` interface as `DirectOBDOrchestrator`, but instead of
holding a `BluetoothDeviceManager`, it:
1. Checks `FlutterForegroundTask.isRunningService` - no point messaging a
   service that isn't there.
2. Sends `{'command': 'refreshNow'}` via `FlutterForegroundTask.sendDataToTask`
   and awaits a `{'type': 'refreshResult', 'success': ..., 'connected': ...}`
   reply via `addTaskDataCallback` (20s timeout - a hung real service, see
   the "known gap" below, should mean this gives up, not that the UI hangs).
   `BackgroundService.onReceiveData` is the receiving side, running only on
   the real instance the plugin actually registered via `setTaskHandler`.
3. Reads the actual reading back from `readings.db` rather than carrying it
   in the reply - the database is a real file both isolates reach
   independently, unlike a Dart object confined to one isolate's heap, so
   it's the natural data transport (the same reason `service_heartbeat.log`
   and `receiver_debug.log`, below, have been reliable cross-isolate
   evidence this whole investigation leaned on).

`isConnected` (is the dongle linked *right now*, distinct from "is the
service running" - #17 means these diverge for real stretches between a
failed cycle's disconnect and the next reconnect attempt) travels the same
way: `BackgroundService` includes it in every status/refresh reply;
`BackgroundServiceOrchestrator` caches the last value it was told, since it
can't synchronously ask a different isolate, and `refreshStatus()` gives the
UI a cheap way to ask for a fresh answer (5s timeout) without forcing a real
collection cycle the way `refreshNow` does.

This restores, on top of the current plugin's API, a pattern the app had
before: pre-2025-03-21 (before migrating from `flutter_background_service`
to `flutter_foreground_task`), `AppMode.real`'s orchestrator was a
`BackgroundServiceOrchestrator` that sent `invoke('manualCollect')` and
listened on `.on('status')` - the same shape of fix, just built on
`flutter_background_service`'s message-passing instead of
`flutter_foreground_task`'s. It didn't survive the plugin migration; nobody
re-wired the equivalent on the new plugin's API at the time. See issue #20
for the full incident writeup.

**Known gap:** if the real service's isolate hangs mid-cycle (plausible -
nothing in the scan/connect/probe chain is timeout-guarded; see the
`cycle-start` heartbeat line added to help tell "isolate never ran" apart
from "ran and got stuck," under issue #3), `refreshNow`/`refreshStatus`
requests just time out. The UI degrades to showing stale data with a timeout
error rather than hanging, but nothing currently un-sticks the real service
itself - revisit if that turns out to be a recurring, not merely
theoretical, failure mode.

**Zombie service (#22, fixed):** a worse variant of the gap above - the
native receiver could get Android to promote the process to a foreground
service while the Dart `TaskHandler` never attached at all, so
`isServiceRunning()` reported "alive" for a service nothing was listening
on and `refreshNow`/`refreshStatus` just burned their full timeout. Root
cause: `flutter_foreground_task`'s `ForegroundTask.init()` silently skips
running any Dart code at all - no exception, no log - when its persisted
Dart callback handle is missing, and `BackgroundService`'s own routine
"probably parked" self-stop (`FlutterForegroundTask.stopService()`, after
`maxConsecutiveFailures`) clears that handle as a side effect, with
nothing re-persisting it until the app is next opened by hand. Fixed by
backing up the handle to our own prefs key at every normal app launch
(`BackgroundServiceController.startService()`) and having
`ObdConnectionReceiver` restore it from that backup before a headless
REBOOT whenever the plugin's own copy is missing - see the doc comments on
`restoreCallbackHandleIfMissing()` and `startService()` for the full
mechanism. Full investigation trail lives on the issue, not here.

## Four-Part Design

The background functionality is implemented as four distinct components -
three native/background-isolate pieces, plus the UI-isolate messenger added
in #20 (see "Two Isolates" above for why that split exists at all):

1. **ObdConnectionReceiver** (native Kotlin) - the start trigger:
   - Manifest-declared `BroadcastReceiver` on `ACTION_ACL_CONNECTED` — delivered
     even when no app process is alive. Start only; no disconnect handling -
     never was one to begin with, and it stays that way even though
     `BluetoothDeviceManager` no longer drops the dongle link every cycle
     (only on a failed one, see #17) - the service self-terminates instead.
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
     and stop — the only way to confirm a drive was captured without a rig.
     A failed cycle's line includes `reason=<...>` when the orchestrator can
     say why (no devices in range, a scan error, no OBD match, an empty
     probe response, etc.) — otherwise a scan that came back empty because
     of e.g. a platform scan-throttle rejection looks identical to
     "genuinely nothing in range" (see issue #3).

4. **BackgroundServiceOrchestrator** (UI isolate) - the messenger, not a
   collector:
   - Never constructs a `BluetoothDeviceManager` - `DataOrchestratorFactory`
     hands this to `DashboardPage` for `AppMode.real` instead of a
     `BackgroundService()` of its own (see "Two Isolates" above for why that
     used to be the bug)
   - `collectData()`: checks `isRunningService`, sends `refreshNow`, awaits
     the reply, then reads the actual reading back from `readings.db`
   - `refreshStatus()`: a cheaper `getStatus` round trip for just
     `isConnected`, without forcing a real collection cycle
   - Implements the same `DataOrchestrator` interface as
     `DirectOBDOrchestrator`, so `DashboardPage`'s code doesn't need to know
     which one it's holding

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
- **No stop signal, only self-termination.** The receiver was never given a
  disconnect trigger, and that stays true even though disconnect means
  something again post-#17 (a failed cycle, not every cycle) - the
  `maxConsecutiveFailures` counter already reacts to that same signal, just
  debounced across several cycles instead of the first blip. So the service
  polls at a fixed interval (the BT connection already established we're in
  the car — no backoff, no GPS/movement trigger, no `location` dependency)
  and stops itself after `maxConsecutiveFailures` cycles fail back to back.
- **`eventAction` is `nothing()`.** Scheduling is driven by `BackgroundService`'s
  own timer; the plugin's periodic `onRepeatEvent` wakeup is unused.
- **Revisit the model only if `service_heartbeat.log` shows missed or truncated
  drives.** That is the signal that "let it die" is actually costing data; short
  of it, resist adding reliability machinery.

## Key Components

### `android/.../ObdConnectionReceiver.kt` and `ObdConnectionPolicy.kt`

The native trigger, and start-only. `ObdConnectionReceiver` is a thin adapter: it
pulls the action, the `BluetoothDevice`, the `BLUETOOTH_CONNECT` permission state,
whether the foreground service is currently running, and the saved dongle MAC
out of the framework, hands them to `ObdConnectionPolicy.decide`, and carries
out the result (`START` / `ALREADY_RUNNING` / `IGNORE`). `ObdConnectionPolicy`
is `isDriveTrigger` (saved dongle MAC, or a name hint: `OBD` / `ELM` / `LEAF`)
with no `android.*` imports, so it can be unit-tested directly (pending #5's
JVM test lane). There is no disconnect handling — see Service Lifecycle.

`isServiceRunning` is deliberately a parameter to `decide`, not a check the
receiver makes and branches on by itself — see the doc comment on `decide` in
`ObdConnectionPolicy.kt`. It was originally the latter (added, then fixed as a
follow-up in the same issue): every recognised-device connect restarted the
service unconditionally, including the dongle's own per-cycle reconnect, which
restarted the Dart isolate roughly every minute for the whole drive. Nobody
had written a test asserting what should happen when the service is already
running, because nobody had modelled it as a question `decide` needed to
answer — an unmodelled precondition, not a wrong answer to a modelled one, so
no test on the original code would have caught it. Pulling it out as an
explicit parameter with a named outcome (`ALREADY_RUNNING`) is what makes that
case something a test can pin down going forward.

**Untested assumptions**, in the same category as the `NAME_HINTS` substring
match above — plausible, unverified, and would fail silently if wrong:
- The saved-MAC match (`isDriveTrigger`) assumes `flutter.obd_device_id`
  (`BluetoothDeviceManager`, via flutter_blue_plus's `remoteId.str`) and native
  `BluetoothDevice.address` are byte-for-byte comparable modulo case. A
  flutter_blue_plus upgrade that changes its address string format would break
  this match without any error - the device would just stop being recognised.
- `onReceive` isn't synchronized against itself: the `isServiceRunning` read
  and the `startForegroundService` call aren't atomic, relying instead on
  Android delivering broadcasts to one receiver instance serially. Two
  `ACL_CONNECTED` broadcasts landing genuinely concurrently (e.g. separate
  cold-start processes) could both see "not running" and both start - harmless
  today (a redundant REBOOT just repeats work) but not something anything
  enforces.

`restoreCallbackHandleIfMissing` runs right before every `setServiceStatus`
+ `startForegroundService` call: it checks whether
`flutter_foreground_task`'s own persisted Dart callback handle is present,
and restores it from `BackgroundServiceController.startService()`'s backup
if not. See "Zombie service (#22, fixed)" in "Two Isolates" above for why
this exists - a no-op in the common case (the handle is already there).

### `background_service_controller.dart`

Boundary between the Flutter UI and the native foreground service. Key features:

- `initialize()` — notification channel, permission requests, `autoRunOnBoot: false`
- `startService()` — called once at launch; its job now is to persist the
  notification options and Dart callback handle so `ObdConnectionReceiver` can
  start the service headless later. Also backs up that same callback handle
  to our own prefs key (`ObdConnectionReceiver.restoreCallbackHandleIfMissing`
  restores it from there if the plugin's own copy is ever missing at REBOOT
  time — see issue #22)
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

1. `DataOrchestrator` - the base interface. Beyond `collectData()`/
   `statusStream`/`dispose()`/`lastFailureReason`, it also declares
   `isConnected` (is the dongle linked right now) and `refreshStatus()`
   (best-effort refresh of that without a real collection cycle) - added for
   #20, since "is the service running" and "is it connected" turned out to
   be different questions worth asking separately (#17 means they diverge
   for real stretches).
2. `DirectOBDOrchestrator` - real collection via `OBDConnector`/
   `BluetoothDeviceManager`. `isConnected` is live here (it holds the
   connection); `refreshStatus()` is a no-op.
3. `BackgroundServiceOrchestrator` - the UI-isolate messenger (see
   "Two Isolates" / Four-Part Design above). `isConnected` is a cached,
   best-effort value updated from status/refresh replies, since this
   orchestrator can't synchronously ask a different isolate.
4. `MockDataOrchestrator` - simulated data; `isConnected` is always `true`
   (no real dongle to track).

The orchestrator is responsible for:
- Connecting to the vehicle (or, for `BackgroundServiceOrchestrator`, asking
  whichever isolate actually can)
- Collecting data points
- Storing readings in the database
- Publishing to MQTT (if enabled)
- Maintaining collection sessions

## Diagnostics

Two durable, on-device log files, plus a way to actually read them - all
added investigating issue #3, since there's no hardware rig and the real
failure modes (restart storms, BLE collisions, an isolate that never wrote
a single line) only ever showed up on real drives with nobody watching:

- **`service_heartbeat.log`** (app documents dir) - one line per `start`,
  `cycle-start`, `cycle` (with `reason=<...>` on failure - see
  `background_service.dart` above), and `stop` (`stop (timeout)` if
  `TaskHandler.onDestroy`'s `isTimeout` param was true). `cycle-start` is
  written before any `await` in `execute()`, specifically so a cycle that
  starts and then hangs forever (nothing in the scan/connect/probe chain is
  timeout-guarded) leaves a trace distinguishable from the isolate never
  having run at all - both used to look like the same silence.
- **`receiver_debug.log`** (app files dir) - one line per `ACL_CONNECTED`
  `ObdConnectionReceiver` sees, unconditionally (`IGNORE` included), with
  the device name, permission state, `decide()`'s outcome, and the
  `startForegroundService()` result. Without this, a name/match bug showing
  up as `decision=IGNORE` looks identical to "the broadcast never arrived
  at all" - very different problems that would otherwise be indistinguishable
  from the outside.
- **Every heartbeat line is tagged** `[<isolate debug name>/<isolate
  hashCode>#<instance counter>]` (see #9/#3). `BackgroundService` is
  constructed independently in two places that can both be alive at once
  (see "Two Isolates" above) - before this tag, there was no way to tell
  from the log alone whether a given line came from the real service or
  from a stray second instance.
- **Reading either file off a release build**: `adb run-as` needs a
  debuggable app, and flipping `debuggable=true` on the release build type
  directly crashes on launch (SIGABRT - an AOT-release/debuggable-manifest
  mismatch that SELinux blocks on newer Android). `make debug-apk` builds
  the real, supported `flutter build apk --debug` variant to a separate
  file instead; same debug signing config as release, so `adb install -r`
  over either variant preserves app data. Install it, pull the files, then
  reinstall the release apk to go back to normal.
- **The in-app `LogViewer`** (dashboard's log panel) is live, not durable -
  it only ever shows what the isolate that built it did, since `SimpleLogger`
  is a singleton per isolate, not per app (see "Two Isolates" above). Before
  this follow-up it silently only showed UI-isolate activity, making the
  real background service's connect attempts, OBD command retries, and CAN
  parse errors invisible whenever you watched it live. `backgroundServiceEntryPoint`
  (`background_service_controller.dart`) now forwards every line the service
  logs to the main isolate via `sendDataToMain({'type': 'log', ...})`, and
  `main.dart` relays it into `LogViewer` via a permanent `addTaskDataCallback`
  (`onBackgroundServiceData`) alongside the transient request/reply callbacks
  `BackgroundServiceOrchestrator` registers - `flutter_foreground_task` calls
  every registered callback per message, so both coexist. Still not durable:
  closing the app or the dashboard not being open loses it, same as before -
  for anything that needs to survive that, use the two log files above.

## Collection Loop

Once started, the service just polls on a fixed timer — one collection every
`_baseInterval` (default 1 minute), no adaptation. The earlier design used
exponential backoff and a GPS/movement trigger to guess whether the car was on;
the Bluetooth connection answers that now, so both are gone (see issue #13).

Stopping is failure-driven, not disconnect-driven: `ObdConnectionReceiver`
never sends a stop - it was never given an `ACL_DISCONNECTED` filter, and
that's still the right call even though a disconnect isn't guaranteed noise
anymore (`BluetoothDeviceManager` only drops the link on a failed cycle now,
not every cycle - see #17). The service tracks consecutive failed cycles
instead and calls `stopService()` at `maxConsecutiveFailures` (5) — ~5 minutes
of not being able to reach the dongle, i.e. parked. A transient dongle drop
mid-drive costs at most a few cycles (each one now paying a fresh
scan+connect+probe round-trip, since the failure disconnected it) before the
next success resets the counter and settles back into a held-open connection.

Known gap (out of scope, issue #13): a genuinely flaky dongle could rack up 5
failures *while still driving* and stop the service with no way to restart it
until the next connection (pull-to-refresh, below, needs a hand on the phone -
it doesn't help mid-drive). If real drives show that in
`service_heartbeat.log`, gate the self-terminate on a "still in the car" check
— best signal is whether the Leaf's Bluetooth (`MY LEAF`) is still connected,
since that is the same classic-BT link we trust to start on; a cheap fallback
is "no successful collection in the last ~10 minutes". (Not
`ActivityRecognition` — its `IN_VEHICLE` is too laggy and unreliable to gate
on.)

### Restarting a Stopped Service

Pull-to-refresh (the `RefreshIndicator` in `dashboard_page.dart`, wired to
`_refreshCurrentReading()` → `_orchestrator.collectData()`) can restart a
service that self-stopped, or was never started this run — the user pulling
down is an explicit, in-person "check right now" that overrides the
"probably parked" heuristic (#20 follow-up). `BackgroundServiceOrchestrator
.collectData()` checks `isServiceRunning()`; when false, instead of failing
immediately it calls `BackgroundServiceController.startService()` and awaits
a `startupResult` message — `onStart()`'s own initial
`execute(TriggerType.manual)` reporting back once it finishes. That message
type is sent from nowhere else, so this wait can't be satisfied by an
unrelated timer cycle completing around the same moment. No `refreshNow` is
also sent: `onStart()` already runs exactly one cycle before anything else,
so a second request would either race the freshly spawned isolate's own
listener registration or double up the BLE round trip once it's free.

Deliberately out of scope for now: what happens *after* that one restart
cycle. A failed restart still re-arms the normal 1-minute polling loop for up
to `maxConsecutiveFailures` more cycles before stopping again, same as any
other start — there's no one-shot special case. A stray pull-to-refresh at
home could cost a few minutes of pointless polling; left as an open question
rather than solved here.

The auto-refresh-on-resume path that used to *also* reach this same
`collectData()` call — firing whenever the app came back to the foreground
with a reading more than 10 minutes stale — was removed for the same reason
it's being left alone here: it fired from simply glancing at the app, not
from asking for anything, and would silently re-arm the same polling burst
just from that. `didChangeAppLifecycleState`'s resume handler now only
reloads the historical chart from the DB (cheap, no BLE) and checks status
(`getStatus`, not a collection) when stale — a live read only ever happens
from pull-to-refresh or cold app launch.

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

- Set via `DashboardPage`'s mode-switch menu (`_setMode(AppMode.mock)`),
  which swaps `DataOrchestratorFactory`'s cached orchestrator to
  `MockDataOrchestrator`. Not `AppState.instance.enableMockMode()` - that
  flag exists (`app_state.dart`) but nothing in the app currently calls it;
  it's read only by `mqtt_client.dart` for an unrelated, separate mock
  concept, so it stays permanently `false` in practice. Pre-existing
  staleness, noticed while updating this doc for #20 - not something #20
  touched.
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
