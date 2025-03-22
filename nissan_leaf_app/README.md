## Documentation Structure

This repository contains several documentation files to help you understand different aspects of the project:

- [**Main README**](README.md) - Project overview, development setup, and architecture
- [**OBD Communication**](lib/obd/README.md) - Details on the OBD protocol implementation
- [**Data Persistence**](lib/data/README.md) - Information on the data model and database
- [**Background Service**](docs/Background_Service_Architecture.md) - Background data collection system
- [**MQTT Integration**](docs/MQTT_Integration.md) - MQTT client for Home Assistant
- [**UI Components**](docs/UI_Components.md) - User interface components overview# Nissan Leaf Battery Tracker

A Flutter-based application for monitoring and tracking Nissan Leaf battery metrics through the OBD-II interface.

## Project Overview

This application connects to your Nissan Leaf via an OBD-II Bluetooth adapter to collect real-time battery data including:
- State of charge
- Battery health
- Battery capacity
- Estimated range
- And numerous other OBD metrics

Unlike the built-in Leaf display, this app allows you to:
- Track battery metrics while driving
- Record data during charging (when the car's display is inactive)
- Store historical data for analysis
- (Optional) Send metrics to Home Assistant via MQTT

## Project Status

⚠️ **DEVELOPMENT STATUS**: This project is currently in active development and seeking contributors. Several areas need improvement:

- OBD command compatibility varies between Leaf model years (currently optimized for 2018 models)
- Many OBD commands need validation and fixing for 2019+ models
- Additional metrics could be added for different components of the Leaf
- App deployment and distribution not yet implemented

## Development Environment Setup

This project uses a Docker-based development environment to ensure consistency across platforms.

### Prerequisites

- Docker and Docker Compose
- Git
- (Windows only) WSL2 and usbipd for physical device testing

### Setting Up Development Environment

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/nissan-leaf-battery-tracker.git
   cd nissan-leaf-battery-tracker
   ```

2. Build and start the development container:
   ```bash
   make docker-build
   ```

3. Open a shell in the development container:
   ```bash
   make docker-shell
   ```

4. Within the Docker container, set up the project:
   ```bash
   make setup
   ```

### Development Commands

The following commands should be run from within the Docker container:

- Run tests: `make test`
- Check code quality: `make analyze`
- Run on connected Android device: `make android`
- Build APK: `make apk`
- Clean build artifacts: `make clean`

For Windows users connecting physical devices:
```bash
make docker-adb   # Sets up USB passthrough to Docker
```

## Project Architecture

The project follows a focused, pragmatic architecture:

### Core Components

- **OBD Communication Layer** ([details](lib/obd/README.md))
  - Handles Bluetooth device communication
  - Processes CAN bus protocol
  - Defines vehicle-specific OBD commands

- **Data Management** ([details](lib/data/README.md))
  - Defines data models for battery readings
  - Manages SQLite storage of readings

- **Background Service System** ([details](docs/Background_Service_Architecture.md)) (composed of two key parts)
  - **Controller** (`lib/background_service_controller.dart`): Manages the foreground service lifecycle, permissions, and Android notification
  - **Service** (`lib/background_service.dart`): Implements the actual background task logic with adaptive collection intervals

- **MQTT Integration** ([details](docs/MQTT_Integration.md))
  - Publishes data to Home Assistant (optional)
  - Supports autodiscovery for easy integration

- **UI Components** ([details](docs/UI_Components.md))
  - Dashboard for real-time monitoring
  - Historical data charts
  - Connection management

### Development Philosophy

This project follows YAGNI principles:
- Simple, direct implementations over complex abstractions
- Practical organization focused on current needs
- Adding complexity only when justified by concrete requirements

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
