# UI Components

This documentation covers the user interface components of the Nissan Leaf Battery Tracker app.

*[Return to main documentation](../README.md)*

## Screen Flow

The app has a simple navigation structure:

```
┌─────────────┐
│ MainScreen  │
└──────┬──────┘
       │
       ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ DashboardPage│────▶│ConnectionPage│────▶│ OBD Test Page │
└──────┬──────┘     └─────────────┘     └─────────────┘
       │
       ▼
┌─────────────┐
│ MQTT Settings│
└─────────────┘
```

## Page Components

### `dashboard_page.dart`

The main screen of the application with:

- Current battery status display
- Historical charts
- Connection status
- Background service controls
- Mock mode toggle
- Menu options for settings

Key features:
- Real-time battery status updates
- Historical data visualization
- Background service control
- Pull-to-refresh functionality
- Connection management

### `connection_page.dart`

Provides Bluetooth device scanning and connection:

- Scans for nearby Bluetooth OBD adapters
- Shows signal strength and device details
- Handles connection and disconnection
- Tests OBD commands after connection

### `ble_scan_page.dart` (Legacy)

An alternative/older implementation of connection management:

- Direct Bluetooth Low Energy (BLE) scanning
- Less abstracted than the newer ConnectionPage
- Currently accessible via the "OBD Test" menu option

### `obd_test_page.dart`

A utility page for testing OBD commands:

- Enter raw CAN frame responses
- Test command parsing and decoding
- Includes preset test frames
- Useful for developing new OBD commands

## Reusable Components

### `battery_status_widget.dart`

Visual display of current battery status:

- State of charge with visual battery indicator
- Battery health percentage
- Estimated range
- Last updated timestamp
- Animated refresh button

```dart
BatteryStatusWidget(
  stateOfCharge: 75.0,
  batteryHealth: 92.0,
  estimatedRange: 150.0,
  lastUpdated: DateTime.now(),
  isLoading: false,
  onRefresh: refreshData,
)
```

### `readings_chart_widget.dart`

Time-series visualization of battery data:

- Interactive line chart
- Customizable data source
- Adaptive time axis
- Empty state handling
- Loading indicator

```dart
ReadingsChartWidget(
  readings: readings,
  isLoading: isLoadingHistory,
  title: 'Battery Health