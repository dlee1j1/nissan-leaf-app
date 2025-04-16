# Nissan Leaf Battery Tracker

A Flutter-based application for monitoring and tracking Nissan Leaf battery metrics through the OBD-II interface.

## Project Overview

This application connects to your Nissan Leaf via an OBD-II Bluetooth adapter to collect real-time battery data including:
- State of charge
- Battery health
- Battery capacity
- Estimated range
- And numerous other OBD metrics

Tthis app allows you to:
- Track battery metrics while driving
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

## Detailed Documentation

For more detailed information about the app architecture, components, and usage, please see the [app README](nissan_leaf_app/README.md).