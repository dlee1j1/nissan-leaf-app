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

One-shot: every call connects, does its work, and disconnects - always,
even on failure. There is no persistent session, keep-alive timer, or
auto-reconnect; each collection cycle (~once a minute while tracking)
publishes fresh with whatever settings are current, so a settings change
takes effect on the very next cycle with nothing to restart.

Example:
```dart
final client = MqttClient.instance;

// Test settings without publishing anything
final ok = await client.testConnection(settings);

// Publish one battery-data cycle
await client.publishBatteryData(
  settings: settings,
  stateOfCharge: 85.0,
  batteryHealth: 92.0,
  batteryVoltage: 364.5,
  batteryCapacity: 56.0,
  sessionId: 'session_123',
);
```

Connects as MQTT 3.1.1 explicitly (some brokers reject the package's
default 3.1 handshake).

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
  "expire_after": 180,
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
   [topicPrefix]/[clientId]/speed/state            // Vehicle speed, km/h
   [topicPrefix]/[clientId]/odometer/state         // Total odometer, km
   [topicPrefix]/[clientId]/ambient_temp/state     // Ambient temperature, °C
   [topicPrefix]/[clientId]/l1l2_charges/state     // Lifetime L1/L2 charge count
   [topicPrefix]/[clientId]/quick_charges/state    // Lifetime DC quick-charge count
   ```
   The last six topics only publish when that cycle's OBD read succeeded -
   the reads behind them are best-effort, unlike SOC/health/voltage/capacity.
   There is no range/state topic - the OBD command behind it was removed
   (see `nissan_leaf_app/lib/data/readme.md`).

2. **Data Topic**: Complete data object
   ```
   [topicPrefix]/[clientId]/data                   // JSON with all values
   ```

There is no availability topic. Each sensor's discovery config sets
`expire_after` instead (Home Assistant marks it unavailable if it hasn't
heard an update within that window) - the right primitive for something
that reports occasionally rather than staying connected.

## Quality of Service (QoS) Levels

The MQTT client supports three QoS levels:

- **QoS 0** (At most once): No guarantee of delivery
- **QoS 1** (At least once): Guaranteed delivery, may be duplicated
- **QoS 2** (Exactly once): Guaranteed delivery exactly once

The QoS level can be set in the MqttSettings configuration.

## Networking and Connectivity

One-shot per call (see `mqtt_client.dart` above) - no persistent session,
so no reconnection or keep-alive logic exists or is needed. A network
connectivity check runs before every connect attempt.

### WebSocket transport

By default the client connects via raw TCP. If your broker is only
reachable behind a reverse proxy that terminates TLS and speaks HTTP(S) -
e.g. Cloudflare's standard proxy, which forwards WebSocket upgrades but
not raw TCP MQTT on 1883/8883 - enable **Use WebSocket (wss://)** in MQTT
Settings. This connects via `wss://<broker>` on the configured port
(typically 443) instead, sending a single `mqtt` value for
`Sec-WebSocket-Protocol` (some brokers reject the package's default of
three candidate values). `MqttSettings.useWebSocket` /
`mqtt_use_websocket` is the underlying flag (`mqtt_settings.dart`,
`mqtt_client.dart`).

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
