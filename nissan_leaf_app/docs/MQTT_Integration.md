# MQTT Integration

The MQTT integration allows the app to publish battery data to external systems like Home Assistant, enabling smart home automation based on your Nissan Leaf's status.

*[Return to main documentation](../README.md)*

## Architecture

The MQTT implementation has two main components:

```
┌─────────────────┐     ┌─────────────────┐     
│   MqttSettings  │────▶│    MqttClient   │     
│                 │     │                 │     
└─────────────────┘     └─────────────────┘     
        ▲                        │
        │                        │
┌───────┴───────┐                ▼
│MqttSettingsWidget│      ┌─────────────────┐
│                 │      │    MQTT Broker   │
└─────────────────┘      │    (External)    │
                         └─────────────────┘
```

## Components

### `mqtt_settings.dart`

Manages MQTT connection settings, including:

- Broker address and port
- Authentication credentials (securely stored)
- Client ID and topic prefix
- QoS level
- Persistence

Example:
```dart
// Load settings
final settings = MqttSettings();
await settings.loadSettings();

// Update settings
settings.broker = 'homeassistant.local';
settings.port = 1883;
settings.username = 'mqttuser';
await settings.setPassword('mqttpassword');
settings.clientId = 'nissan_leaf_tracker';
settings.topicPrefix = 'nissan_leaf';
settings.qos = 1;
settings.enabled = true;

// Save settings
await settings.saveSettings();
```

### `mqtt_client.dart`

Handles the actual MQTT communication:

- Connection management
- Reconnection logic
- Message publishing
- Home Assistant discovery
- Availability updates

Example:
```dart
// Initialize with settings
final client = MqttClient.instance;
await client.initialize(settings);

// Connect
final connected = await client.connect();

// Publish data
await client.publishBatteryData(
  stateOfCharge: 85.0,
  batteryHealth: 92.0,
  batteryVoltage: 364.5,
  batteryCapacity: 56.0,
  estimatedRange: 150.0,
  sessionId: 'session_123',
);

// Disconnect
await client.disconnect();
```

## Home Assistant Integration

This MQTT implementation includes special support for Home Assistant:

1. **Auto-Discovery**: Automatically creates devices and entities in Home Assistant
2. **Status Tracking**: Updates device availability status
3. **Sensor Configuration**: Provides proper unit configuration and entity type

### Auto-Discovery Configuration

When first connecting, the app publishes configuration messages to Home Assistant's discovery topics:

```
homeassistant/sensor/[clientId]/soc/config
homeassistant/sensor/[clientId]/health/config
homeassistant/sensor/[clientId]/voltage/config
homeassistant/sensor/[clientId]/capacity/config
homeassistant/sensor/[clientId]/range/config
homeassistant/sensor/[clientId]/speed/config
homeassistant/sensor/[clientId]/odometer/config
homeassistant/sensor/[clientId]/ambient_temp/config
homeassistant/sensor/[clientId]/l1l2_charges/config
homeassistant/sensor/[clientId]/quick_charges/config
```

These messages define:
- Entity names and IDs
- Units of measurement
- Device class
- State class
- Device information
- Icons

Example discovery message:
```json
{
  "name": "Nissan Leaf Battery Level",
  "device_class": "battery",
  "state_class": "measurement",
  "unit_of_measurement": "%",
  "state_topic": "nissan_leaf/nissan_leaf_tracker/soc/state",
  "availability_topic": "nissan_leaf/nissan_leaf_tracker/availability",
  "icon": "mdi:car-electric",
  "unique_id": "nissan_leaf_tracker_soc",
  "device": {
    "identifiers": ["nissan_leaf_tracker"],
    "name": "Nissan Leaf Battery Tracker",
    "model": "Nissan Leaf",
    "manufacturer": "Nissan",
    "sw_version": "1.0.0"
  }
}
```

### Topic Structure

The MQTT client publishes to several topics:

1. **State Topics**: For individual metrics
   ```
   [topicPrefix]/[clientId]/soc/state              // Battery percentage
   [topicPrefix]/[clientId]/health/state           // Battery health
   [topicPrefix]/[clientId]/voltage/state          // Battery voltage
   [topicPrefix]/[clientId]/capacity/state         // Battery capacity
   [topicPrefix]/[clientId]/range/state            // Estimated range (unreliable - see note below)
   [topicPrefix]/[clientId]/speed/state            // Vehicle speed, km/h
   [topicPrefix]/[clientId]/odometer/state         // Total odometer, km
   [topicPrefix]/[clientId]/ambient_temp/state     // Ambient temperature, °C
   [topicPrefix]/[clientId]/l1l2_charges/state     // Lifetime L1/L2 charge count
   [topicPrefix]/[clientId]/quick_charges/state    // Lifetime DC quick-charge count
   ```
   The last seven topics only publish when that cycle's OBD read succeeded -
   the reads behind them are best-effort, unlike SOC/health/voltage/capacity.

   `range/state` is a known-unreliable field: its raw OBD response decodes
   correctly by the same byte-level reference validated for the others, but
   real captures show it frozen regardless of actual SOC or driving. Treat
   it as unfixed rather than trustworthy until that gets root-caused - see
   `nissan_leaf_app/lib/data/readme.md`.

2. **Availability Topic**: Device online status
   ```
   [topicPrefix]/[clientId]/availability           // "online" or "offline"
   ```

3. **Data Topic**: Complete data object
   ```
   [topicPrefix]/[clientId]/data                   // JSON with all values
   ```

## Quality of Service (QoS) Levels

The MQTT client supports three QoS levels:

- **QoS 0** (At most once): No guarantee of delivery
- **QoS 1** (At least once): Guaranteed delivery, may be duplicated
- **QoS 2** (Exactly once): Guaranteed delivery exactly once

The QoS level can be set in the MqttSettings configuration.

## Networking and Connectivity

The client includes:

- Connection status monitoring
- Automatic reconnection
- Network connectivity checks
- Keep-alive mechanism (5-minute refresh)

### WebSocket transport

By default the client connects via raw TCP. If your broker is only
reachable behind a reverse proxy that terminates TLS and speaks HTTP(S) -
e.g. Cloudflare's standard proxy, which forwards WebSocket upgrades but
not raw TCP MQTT on 1883/8883 - enable **Use WebSocket (wss://)** in MQTT
Settings. This connects via `wss://<broker>` on the configured port
(typically 443) instead. `MqttSettings.useWebSocket` / `mqtt_use_websocket`
is the underlying flag (`mqtt_settings.dart`, `mqtt_client.dart`).

## Security

To ensure secure communication:

1. **TLS Support**:
   - Automatically enabled when using port 8883
   - CA certificate validation

2. **Authentication**:
   - Username/password support
   - Password stored securely using encrypted shared preferences

3. **Client ID**:
   - Unique client ID to prevent conflicts

## Home Assistant Automation Examples

Once integrated with Home Assistant, you can create automations like:

```yaml
# Notify when battery level is low
- alias: "Nissan Leaf Low Battery Alert"
  trigger:
    platform: numeric_state
    entity_id: sensor.nissan_leaf_battery_level
    below: 20
  action:
    service: notify.mobile_app
    data:
      title: "Nissan Leaf Battery Low"
      message: "Your Leaf's battery is at {{ states('sensor.nissan_leaf_battery_level') }}%"

# Turn on smart plug for home charger when car arrives home with low battery
- alias: "Activate Home Charger on Arrival"
  trigger:
    platform: state
    entity_id: device_tracker.mobile_phone
    to: "home"
  condition:
    condition: numeric_state
    entity_id: sensor.nissan_leaf_battery_level
    below: 50
  action:
    service: switch.turn_on
    target:
      entity_id: switch.garage_charger
```
