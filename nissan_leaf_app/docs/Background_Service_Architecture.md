# Background Data Collection System

The Background Service architecture handles automated data collection from the vehicle's OBD system, even when the app is not in the foreground. The implementation is split into two main components: a Controller and a Service.

*[Return to main documentation](../README.md)*

## Architecture Overview

```
┌───────────────────┐
│   DashboardPage   │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐                
│BackgroundService  │  Platform API    Flutter App
│  Controller       │  Boundary ───────────────────
└─────────┬─────────┘                
          │                         
          │                         
┌─────────▼─────────┐     ┌───────────────────┐
│ BackgroundService │────▶│ DataOrchestrator  │
│ (TaskHandler)     │     │  (Interface)      │
└───────────────────┘     └─────────┬─────────┘
                                    │
                                    ▼
                          ┌───────────────────┐
                          │ DirectOBDOrchestrator │
                          └─────────┬─────────┘
                                    │
                                    ▼
                          ┌───────────────────┐
                          │   OBDConnector    │
                          └───────────────────┘
```

## Two-Part Design

The background functionality is implemented as two distinct components:

1. **BackgroundServiceController** - UI-facing component that:
   - Handles platform-specific service initialization
   - Manages Android's foreground service notifications
   - Takes care of permissions requests
   - Provides service lifecycle controls (start/stop)
   - Acts as the boundary between Flutter UI and native platform services

2. **BackgroundService** - Task-executing component that:
   - Implements the actual data collection logic
   - Manages collection frequency and triggers
   - Orchestrates connection to the vehicle
   - Handles data storage and MQTT publishing
   - Runs as a background task on the device

This separation allows:
- Clean isolation of platform-specific code
- Better testability of the collection logic
- Proper dependency injection
- Clear boundaries of responsibility

## Key Components

### `background_service_controller.dart`

Manages the lifecycle of the foreground service, which allows the app to run in the background on mobile devices. Key features:

- Initializes the service
- Starts/stops the service
- Manages Android notification
- Handles permissions

```dart
// Example usage
await BackgroundServiceController.initialize();
await BackgroundServiceController.startService();
bool isRunning = await BackgroundServiceController.isServiceRunning();
await BackgroundServiceController.stopService();
```

### `background_service.dart`

The core service that runs in the background to collect data. Features:

- Implements the `TaskHandler` interface from flutter_foreground_task
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
   - Activates when device moves ~800 meters
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
   const double LOCATION_DISTANCE_FILTER = 800.0; // meters
   ```

3. **Changing maximum delay**:
   ```dart
   // In BackgroundService
   static const Duration maxDelay = Duration(minutes: 30);
   ```
