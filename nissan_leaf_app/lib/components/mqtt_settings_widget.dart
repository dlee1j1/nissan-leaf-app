import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../mqtt_client.dart';
import '../mqtt_settings.dart';

class MqttSettingsWidget extends StatefulWidget {
  const MqttSettingsWidget({super.key});

  @override
  State<MqttSettingsWidget> createState() => _MqttSettingsWidgetState();
}

class _MqttSettingsWidgetState extends State<MqttSettingsWidget> {
  final _formKey = GlobalKey<FormState>();
  final _brokerController = TextEditingController();
  final _portController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _clientIdController = TextEditingController();
  final _topicPrefixController = TextEditingController();

  bool _isEnabled = false;
  bool _isPasswordVisible = false;
  bool _isTesting = false;
  String _connectionStatus = 'Disconnected';
  bool _isConnected = false;
  int _qosValue = 0;

  // MQTT instances
  final _mqttClient = MqttClient.instance;
  final _mqttSettings = MqttSettings();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _setupConnectionListener();
  }

  void _setupConnectionListener() {
    final mqttClient = MqttClient.instance;
    _connectionStatus = mqttClient.isConnected ? 'Connected' : 'Disconnected';
    _isConnected = mqttClient.isConnected;

    _mqttClient.connectionStatus.listen((status) {
      setState(() {
        switch (status) {
          case MqttConnectionStatus.disconnected:
            _connectionStatus = 'Disconnected';
            _isConnected = false;
            break;
          case MqttConnectionStatus.connecting:
            _connectionStatus = 'Connecting...';
            _isConnected = false;
            break;
          case MqttConnectionStatus.connected:
            _connectionStatus = 'Connected';
            _isConnected = true;
            break;
          case MqttConnectionStatus.error:
            _connectionStatus = 'Connection error';
            _isConnected = false;
            break;
        }
        _isTesting = false;
      });
    });
  }

  Future<void> _loadSettings() async {
    await _mqttSettings.loadSettings();

    setState(() {
      _brokerController.text = _mqttSettings.broker;
      _portController.text = _mqttSettings.port.toString();
      _usernameController.text = _mqttSettings.username;
      _clientIdController.text = _mqttSettings.clientId;
      _topicPrefixController.text = _mqttSettings.topicPrefix;
      _qosValue = _mqttSettings.qos;
      _isEnabled = _mqttSettings.enabled;
    });

    // Get initial connection status
    if (_mqttClient.settings != null) {
      setState(() {
        _isConnected = _mqttClient.isConnected;
        _connectionStatus = _mqttClient.isConnected ? 'Connected' : 'Disconnected';
      });
    }
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Parse values from controllers
    final broker = _brokerController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 1883;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final clientId = _clientIdController.text.trim();
    final topicPrefix = _topicPrefixController.text.trim();

    // Update settings object
    _mqttSettings.broker = broker;
    _mqttSettings.port = port;
    _mqttSettings.username = username;
    _mqttSettings.clientId = clientId;
    _mqttSettings.topicPrefix = topicPrefix;
    _mqttSettings.qos = _qosValue;
    _mqttSettings.enabled = _isEnabled;

    // Save password if provided
    if (password.isNotEmpty) {
      await _mqttSettings.setPassword(password);
    }

    // Save settings
    await _mqttSettings.saveSettings();

    // Initialize MQTT client with new settings
    if (_isEnabled && _mqttSettings.isValid()) {
      await _mqttClient.initialize(_mqttSettings);
    } else if (!_isEnabled && _mqttClient.isConnected) {
      await _mqttClient.disconnect();
    }

    // Show confirmation
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('MQTT settings saved')),
      );
    }
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isTesting = true;
      _connectionStatus = 'Connecting...';
    });

    // Update settings with current form values
    _mqttSettings.broker = _brokerController.text.trim();
    _mqttSettings.port = int.tryParse(_portController.text.trim()) ?? 1883;
    _mqttSettings.username = _usernameController.text.trim();
    _mqttSettings.clientId = _clientIdController.text.trim();
    _mqttSettings.topicPrefix = _topicPrefixController.text.trim();
    _mqttSettings.qos = _qosValue;

    // Update password if provided
    final password = _passwordController.text;
    if (password.isNotEmpty) {
      await _mqttSettings.setPassword(password);
    }

    // Test connection
    final connected = await _mqttClient.connect();

    setState(() {
      _isTesting = false;
      _isConnected = connected;
      _connectionStatus = connected ? 'Connected' : 'Connection failed';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with enable/disable switch
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'MQTT Settings',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Row(
                  children: [
                    Text(_isEnabled ? 'Enabled' : 'Disabled'),
                    Switch(
                      value: _isEnabled,
                      onChanged: (value) {
                        setState(() {
                          _isEnabled = value;
                        });
                      },
                      activeColor: Colors.green,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Connection status indicator
            Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: _isConnected ? Colors.green.withAlpha(13) : Colors.grey.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isConnected ? Colors.green : Colors.grey,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isConnected ? Icons.cloud_done : Icons.cloud_off,
                    color: _isConnected ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Status: $_connectionStatus',
                    style: TextStyle(
                      color: _isConnected ? Colors.green : Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ),

            // Broker settings
            TextFormField(
              controller: _brokerController,
              decoration: const InputDecoration(
                labelText: 'Broker Address',
                hintText: 'e.g., 192.168.1.100 or broker.example.com',
                prefixIcon: Icon(Icons.dns),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a broker address';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),

            // Port
            TextFormField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '1883 (default) or 8883 (TLS)',
                prefixIcon: Icon(Icons.settings_ethernet),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a port number';
                }
                final port = int.tryParse(value);
                if (port == null || port < 1 || port > 65535) {
                  return 'Enter a valid port number (1-65535)';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),

            // Username
            TextFormField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username (optional)',
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 12),

            // Password
            TextFormField(
              controller: _passwordController,
              obscureText: !_isPasswordVisible,
              decoration: InputDecoration(
                labelText: 'Password (optional)',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(
                    _isPasswordVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () {
                    setState(() {
                      _isPasswordVisible = !_isPasswordVisible;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Client ID
            TextFormField(
              controller: _clientIdController,
              decoration: const InputDecoration(
                labelText: 'Client ID',
                hintText: 'A unique identifier for this device',
                prefixIcon: Icon(Icons.perm_identity),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a client ID';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),

            // Topic Prefix
            TextFormField(
              controller: _topicPrefixController,
              decoration: const InputDecoration(
                labelText: 'Topic Prefix',
                hintText: 'e.g., nissan_leaf',
                prefixIcon: Icon(Icons.topic),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a topic prefix';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // QoS Selector
            Row(
              children: [
                const Text('Quality of Service (QoS):'),
                const SizedBox(width: 16),
                DropdownButton<int>(
                  value: _qosValue,
                  onChanged: (int? newValue) {
                    if (newValue != null) {
                      setState(() {
                        _qosValue = newValue;
                      });
                    }
                  },
                  items: [
                    DropdownMenuItem<int>(
                      value: 0,
                      child: const Text('At most once (0)'),
                    ),
                    DropdownMenuItem<int>(
                      value: 1,
                      child: const Text('At least once (1)'),
                    ),
                    DropdownMenuItem<int>(
                      value: 2,
                      child: const Text('Exactly once (2)'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: _isTesting ? null : _testConnection,
                  icon: _isTesting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: const Text('Test Connection'),
                ),
                ElevatedButton.icon(
                  onPressed: _saveSettings,
                  icon: const Icon(Icons.save),
                  label: const Text('Save Settings'),
                ),
              ],
            ),

            // Help text
            const SizedBox(height: 24),
            const Text(
              'Note: This configuration will connect to Home Assistant via MQTT. '
              'Make sure your MQTT broker is configured in Home Assistant for auto-discovery.',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _brokerController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _clientIdController.dispose();
    _topicPrefixController.dispose();
    super.dispose();
  }
}
