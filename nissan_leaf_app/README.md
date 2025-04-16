# Nissan Leaf Battery Tracker App

*[Return to main repository](../README.md)*

## Project Architecture

### Core Components

- **OBD Communication Layer** ([details](lib/obd/readme.md))
  - Handles Bluetooth device communication
  - Processes CAN bus protocol
  - Defines vehicle-specific OBD commands

- **Data Management** ([details](lib/data/readme.md))
  - Defines data models for battery readings
  - Manages SQLite storage of readings

- **Background Service System** ([details](../docs/Background_Service_Architecture.md)) (composed of two key parts)
  - **Controller** (`lib/background_service_controller.dart`): Manages the foreground service lifecycle, permissions, and Android notification
  - **Service** (`lib/background_service.dart`): Implements the actual background task logic with adaptive collection intervals

- **MQTT Integration** ([details](../docs/MQTT_Integration.md))
  - Publishes data to Home Assistant (optional)
  - Supports autodiscovery for easy integration

- **UI Components** ([details](../docs/UI_Components.md))
  - Dashboard for real-time monitoring
  - Historical data charts
  - Connection management

### Development Philosophy

This project follows YAGNI principles:
- Simple, direct implementations over complex abstractions
- Practical organization focused on current needs
- Adding complexity only when justified by concrete requirements

## Documentation Structure

This repository contains several documentation files to help you understand different aspects of the project:

- [**Repository README**](../README.md) - Project overview, development setup, and status
- [**App README**](README.md) - App architecture and component overview
- [**OBD Communication**](lib/obd/readme.md) - Details on the OBD protocol implementation
- [**Data Persistence**](lib/data/readme.md) - Information on the data model and database
- [**Background Service**](../docs/Background_Service_Architecture.md) - Background data collection system
- [**MQTT Integration**](../docs/MQTT_Integration.md) - MQTT client for Home Assistant
- [**UI Components**](../docs/UI_Components.md) - User interface components overview
- [**Technical Notes**](../docs/technical-notes.md) - Implementation details and workarounds

## Contributing

Contributions are welcome! Areas particularly needing help:

1. **OBD Command Validation/Fixing**
   - Updating OBD commands for newer Leaf models (2019+)
   - Finding and fixing non-working commands
   - Adding new vehicle metrics

2. **Features**
   - Improving battery health analysis
   - Enhancing data visualization
   - Adding driving efficiency metrics

3. **Testing**
   - Testing on different Leaf model years
   - Adding more test coverage
   - Validating with real-world data

Please follow the existing code style and always include tests for new functionality.

## License

[Insert your license information here]