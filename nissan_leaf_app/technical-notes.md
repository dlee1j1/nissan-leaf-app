# Technical Notes and Implementation Details

## OBD Protocol Implementation

### CAN Bus Communication
- **Multi-frame Handling**: To properly receive multi-frame CAN data:
  - Flow control must be configured during initialization with `ATFCSM1`
  - Flow control settings must be sent with `ATFCSH [header]`
  - Header settings must be correctly set with `ATSH [header]`

- **Response Parsing**: The CAN protocol handler handles three types of frames:
  - Single Frame (SF): Complete message in one frame
  - First Frame (FF): First part with length information
  - Consecutive Frame (CF): Subsequent parts with sequence numbers

- **Frame Structure**:
  ```
  [00 00 07 E8] - CAN ID/Header (4 bytes)
  [10] - Protocol Control Information (PCI) byte
      0x00: Single Frame
      0x10: First Frame
      0x20-0x2F: Consecutive Frames with sequence number
  [...] - Data bytes
  ```

### Known Command Issues
- **State of Charge**: App shows ~93% when vehicle display shows 100%
- **Tire Pressure Readings**: Commands `03220e25` through `03220e28` return data but conversion is incorrect
- **Range Remaining**: Command `03220e24` returns multi-frame data that needs proper decoding:
  ```
  7 63 10 0D 62 0E 24 00 18 42
  7 63 21 08 80 02 00 00 00 00
  [62 0E 24 00 18 42 08 80 02]
  ```

## Flutter Implementation Challenges

### Dependencies Avoided
- **flutter_secure_storage**: Dependency issues with Tink library
  - Requires additional native dependencies that led to complex integration issues
  - Instead implemented simplified secure storage via encrypted_shared_preferences

- **workmanager**: Compatibility problems with newer Flutter versions
  - Deprecated shim classes caused build failures
  - Replaced with flutter_foreground_task for background operation

- **flutter_activity_events**: Missing necessary base Flutter classes
  - Used alternative approach with dedicated lifecycle management
  
### Testing Challenges
- Bluetooth testing in emulators is generally not reliable
- Chrome browser support for Bluetooth is limited and requires special flags
- USB debugging with physical devices requires:
  - Developer mode enabled on device
  - USB debugging option enabled
  - Proper passthrough to Docker container (on Windows via usbipd)

## Technical Workarounds

### Bluetooth Connection
- Multiple connection attempts with exponential backoff
- Recovery from unexpected disconnections
- Timeout handling for unresponsive connections

### Background Collection
- Adaptive intervals based on connection success
- Location-based triggers to resume collection after movement
- Foreground service with notification to prevent Android killing the process

### OBD Command Testing
- Test page for validating commands with real device
- Mock controller for simulating responses in tests
- Detailed logging of raw responses for debugging
