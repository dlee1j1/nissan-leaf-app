import 'package:flutter/foundation.dart';

import 'obd_controller.dart';
import 'can_protocol_handler.dart';
import 'package:simple_logger/simple_logger.dart';

/// Abstract base class for OBD (On-Board Diagnostics) commands.
///
/// This class provides a common interface for sending OBD commands to a vehicle's
/// on-board computer and decoding the responses. Subclasses of `OBDCommand` define
/// the specific details of each command, such as the command string, header, and
/// how to decode the response.
///
/// Usage:
///   1. Initialize the `ObdController` by calling `OBDCommand.initialize(ODBController)`.
///   2. Use the `run()` method on specific commands, e.g.,
///      `var response = await OBDCommand.lbc.run();` // Send the Li-ion Battery Controller command
///
/// *Creating a new OBD command:*
///
/// To create a new OBD command, subclass `OBDCommand` and implement the `decode()` method
/// to parse the response from the vehicle and return the relevant data as a `Map<String, dynamic>`.
///
/// Subclasses should add a static instance of themselves to the end of the `OBDCommand` class.
///
/// Clients can then use these instances to send commands to the vehicle. For example:
///    var response = await OBDCommand.lbc.run(); // Send the Li-ion Battery Controller command
///
/// *The run method:*
/// The run method coordinates the process of sending the OBD command, handling any errors, and returning the decoded response.
///  It leverages the specific/overridden data - header, command, and decode provided by the subclasses to send the command.
///
abstract class OBDCommand {
  // Static instance of ObdController
  static ObdController? _obdController;

/*
  // Initialize the ObdController
  static Future<void> initialize(BluetoothCharacteristic characteristic) async {
    _obdController = ObdController(characteristic);
    await _obdController!.initialize();
  }
*/

  // Setter for injecting an ObdController
  static void setObdController(ObdController controller) {
    _obdController = controller;
  }

  // Static instances of commands
  static final OBDCommand probe = _ProbeCommand();
  static final OBDCommand lbc = _LBCCommand();
  static final OBDCommand powerSwitch = _PowerSwitchCommand();
  static final OBDCommand gearPosition = _GearPositionCommand();
  static final OBDCommand odometer = _OdometerCommand();
  static final OBDCommand battery12v = _12VBatteryCommand();
  static final OBDCommand bat12vCurrent = _12VBatteryCurrentCommand();
  static final OBDCommand quickCharges = _QuickChargesCommand();
  static final OBDCommand l1l2Charges = _L1L2ChargesCommand();
  static final OBDCommand ambientTemp = _AmbientTempCommand();
  static final OBDCommand estimatedAcPower = _EstimatedAcPowerCommand();
  static final OBDCommand estimatedPtcPower = _EstimatedPtcPowerCommand();
  static final OBDCommand auxPower = _AuxPowerCommand();
  static final OBDCommand acPower = _AcPowerCommand();
  static final OBDCommand plugState = _PlugStateCommand();
  static final OBDCommand chargeMode = _ChargeModeCommand();
  static final OBDCommand rpm = _RPMCommand();
  static final OBDCommand obcOutPower = _ObcOutPowerCommand();
  static final OBDCommand motorPower = _MotorPowerCommand();
  static final OBDCommand speed = _SpeedCommand();
  static final OBDCommand acOn = _AcOnCommand();
  static final OBDCommand rearHeater = _RearHeaterCommand();
  static final OBDCommand ecoMode = _EcoModeCommand();
  static final OBDCommand ePedalMode = _EPedalModeCommand();
  static final OBDCommand tpFr = _TpFrCommand();
  static final OBDCommand tpFl = _TpFlCommand();
  static final OBDCommand tpRr = _TpRrCommand();
  static final OBDCommand tpRl = _TpRlCommand();
  static final OBDCommand rangeRemaining = _RangeRemainingCommand();

  static final _registry = [
    lbc,
    rangeRemaining,
    odometer,
    l1l2Charges,
    quickCharges,
    plugState,
    chargeMode,
    tpFr,
    tpFl,
    tpRr,
    tpRl,
    battery12v,
    bat12vCurrent,
    gearPosition,
    speed,
    rpm,
    motorPower,
    ecoMode,
    ePedalMode,
    ambientTemp,
    estimatedAcPower,
    estimatedPtcPower,
    auxPower,
    acPower,
    obcOutPower,
    acOn,
    rearHeater,
    powerSwitch,
  ];
  static List<OBDCommand> getAllCommands() => _registry;

  // Command details (set by subclasses via constructor)
  final String name;
  final String description;
  final String command;
  final String header;

  // Constructor for subclasses to set the data
  OBDCommand({
    required this.name,
    required this.description,
    required this.command,
    required this.header,
  });

  // test hook
  static Future<Map<String, dynamic>> Function(OBDCommand command)? _testRunOverride;
  @visibleForTesting
  static void setTestRunOverride(
      Future<Map<String, dynamic>> Function(OBDCommand command)? override) {
    _testRunOverride = override;
  }

  // Send the command and return the response
  Future<Map<String, dynamic>> run() async {
    // If a test run override is provided, use it
    if (_testRunOverride != null) {
      return _testRunOverride!(this);
    }

    if (_obdController == null) {
      throw Exception('ObdController not initialized. Call OBDCommand.initialize() first.');
    }

    // Step 1: Set the header (AT command)
    await _obdController!.sendCommand('ATSH $header', expectOk: true);
    await _obdController!.sendCommand('ATFCSH $header', expectOk: true);
    await _obdController!.sendCommand('ATFCSM1', expectOk: true); // flow control

    // Step 2: Send the OBD command
    final response = await _obdController!.sendCommand(command, expectOk: false);
    // Step 3: validation checks
    if (response.isEmpty) {
      _log.warning('No valid OBD Messages returned');
      return {};
    }

    if (response == 'NO DATA' || response == 'CAN ERROR') {
      _log.severe('Vehicle not responding');
      return {};
    }

    // Step 4: Parse CAN protocol only for vehicle commands
    final canMessage = CANProtocolHandler.parseMessage(response);

    // Step 4: decode the valid response
    return decode(canMessage);
  }

  // Decode the response (must be implemented by subclasses)
  Map<String, dynamic> decode(List<int> response);
  static final _log = SimpleLogger();
}

class _LBCCommand extends OBDCommand {
  _LBCCommand()
      : super(
          name: 'lbc',
          description: 'Li-ion Battery Controller',
          command: '022101',
          header: '79B',
        );
  @override
  Map<String, dynamic> decode(List<int> data) {
    if (data.isEmpty) return {};

    var hvBatteryCurrent1 = extractInt(data, 2, 6);
    var hvBatteryCurrent2 = extractInt(data, 8, 12);

    // Handle signed values
    if (hvBatteryCurrent1 & 0x8000000 == 0x8000000) {
      hvBatteryCurrent1 |= -0x100000000;
    }
    if (hvBatteryCurrent2 & 0x8000000 == 0x8000000) {
      hvBatteryCurrent2 |= -0x100000000;
    }

    int stateOfCharge;
    int stateOfHealth;
    int batteryAh;

    if (data.length > 41) {
      stateOfCharge = extractInt(data, 33, 36) ~/ 10000;
      stateOfHealth = extractInt(data, 30, 32) ~/ 102.4;
      batteryAh = extractInt(data, 37, 40) ~/ 10000;
    } else {
      stateOfCharge = extractInt(data, 31, 34) ~/ 10000;
      stateOfHealth = extractInt(data, 28, 30) ~/ 102.4;
      batteryAh = extractInt(data, 34, 37) ~/ 10000;
    }

    return {
      'state_of_charge': stateOfCharge,
      'hv_battery_health': stateOfHealth,
      'hv_battery_Ah': batteryAh,
      'hv_battery_current_1': hvBatteryCurrent1 ~/ 1024,
      'hv_battery_current_2': hvBatteryCurrent2 ~/ 1024,
      'hv_battery_voltage': extractInt(data, 20, 22) ~/ 100,
    };
  }
}

/// Probe command - it's a mystery command that we use to probe the vehicle for OBD data.
/// if it returns an error, then we know the rest of the data will not work as expected.
class _ProbeCommand extends OBDCommand {
  _ProbeCommand()
      : super(
          name: 'unknown',
          description: 'Mystery command',
          command: '0210C0 1',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> response) {
    return {
      'raw_response': response,
    };
  }
}

class _PowerSwitchCommand extends OBDCommand {
  _PowerSwitchCommand()
      : super(
          name: 'power_switch',
          description: 'Power Switch Status',
          command: '03221304',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'power_switch': (data[3] & 0x80) == 0x80,
    };
  }
}

class _GearPositionCommand extends OBDCommand {
  _GearPositionCommand()
      : super(
          name: 'gear_position',
          description: 'Current Gear Position',
          command: '03221156',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    String position;
    switch (data[3]) {
      case 1:
        position = "Park";
        break;
      case 2:
        position = "Reverse";
        break;
      case 3:
        position = "Neutral";
        break;
      case 4:
        position = "Drive";
        break;
      case 5:
        position = "Eco";
        break;
      default:
        position = "Unknown";
    }
    return {'gear_position': position};
  }
}

// ignore: camel_case_types
class _12VBatteryCommand extends OBDCommand {
  _12VBatteryCommand()
      : super(
          name: '12v_battery',
          description: '12V Battery Voltage',
          command: '03221103',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'bat_12v_voltage': data[3] * 0.08,
    };
  }
}

class _OdometerCommand extends OBDCommand {
  _OdometerCommand()
      : super(
          name: 'odometer',
          description: 'Total odometer reading',
          command: '03220e01',
          header: '743',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'odometer': extractInt(data, 3, 6),
    };
  }
}

// ignore: camel_case_types
class _12VBatteryCurrentCommand extends OBDCommand {
  _12VBatteryCurrentCommand()
      : super(
          name: 'bat_12v_current',
          description: '12V battery current',
          command: '03221183',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'bat_12v_current': extractInt(data, 3, 5) / 256,
    };
  }
}

class _QuickChargesCommand extends OBDCommand {
  _QuickChargesCommand()
      : super(
          name: 'quick_charges',
          description: 'Number of quick charges',
          command: '03221203',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'quick_charges': extractInt(data, 3, 5),
    };
  }
}

class _L1L2ChargesCommand extends OBDCommand {
  _L1L2ChargesCommand()
      : super(
          name: 'l1_l2_charges',
          description: 'Number of L1/L2 charges',
          command: '03221205',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'l1_l2_charges': extractInt(data, 3, 5),
    };
  }
}

class _AmbientTempCommand extends OBDCommand {
  _AmbientTempCommand()
      : super(
          name: 'ambient_temp',
          description: 'Ambient temperature',
          command: '0322115d',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'ambient_temp': data[3] / 2 - 40,
    };
  }
}

class _EstimatedAcPowerCommand extends OBDCommand {
  _EstimatedAcPowerCommand()
      : super(
          name: 'estimated_ac_power',
          description: 'Estimated AC system power',
          command: '03221261',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'estimated_ac_power': data[3] * 50,
    };
  }
}

class _EstimatedPtcPowerCommand extends OBDCommand {
  _EstimatedPtcPowerCommand()
      : super(
          name: 'estimated_ptc_power',
          description: 'Est Power Temp Coef (PTC - i.e., heater) consumption',
          command: '03221262',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'estimated_ptc_power': data[3] * 250,
    };
  }
}

class _AuxPowerCommand extends OBDCommand {
  _AuxPowerCommand()
      : super(
          name: 'aux_power',
          description: 'Auxiliary equipment power',
          command: '03221152',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'aux_power': data[3] * 100,
    };
  }
}

class _AcPowerCommand extends OBDCommand {
  _AcPowerCommand()
      : super(
          name: 'ac_power',
          description: 'AC system power',
          command: '03221151',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'ac_power': data[3] * 250,
    };
  }
}

class _PlugStateCommand extends OBDCommand {
  _PlugStateCommand()
      : super(
          name: 'plug_state',
          description: 'Plug state of J1772 socket',
          command: '03221234',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    String state;
    switch (data[3]) {
      case 0:
        state = "Not plugged";
        break;
      case 1:
        state = "Partial plugged";
        break;
      case 2:
        state = "Plugged";
        break;
      default:
        state = "Unknown";
    }
    return {'plug_state': state};
  }
}

class _ChargeModeCommand extends OBDCommand {
  _ChargeModeCommand()
      : super(
          name: 'charge_mode',
          description: 'Charging mode',
          command: '0322114e',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    String mode;
    switch (data[3]) {
      case 0:
        mode = "Not charging";
        break;
      case 1:
        mode = "L1 charging";
        break;
      case 2:
        mode = "L2 charging";
        break;
      case 3:
        mode = "L3 charging";
        break;
      default:
        mode = "Unknown";
    }
    return {'charge_mode': mode};
  }
}

class _RPMCommand extends OBDCommand {
  _RPMCommand()
      : super(
          name: 'rpm',
          description: 'Motor RPM',
          command: '03221255',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'rpm': extractInt(data, 3, 5),
    };
  }
}

class _ObcOutPowerCommand extends OBDCommand {
  _ObcOutPowerCommand()
      : super(
          name: 'obc_out_power',
          description: 'On-board charger output power',
          command: '03221236',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'obc_out_power': extractInt(data, 3, 5) * 100,
    };
  }
}

class _MotorPowerCommand extends OBDCommand {
  _MotorPowerCommand()
      : super(
          name: 'motor_power',
          description: 'Traction motor power',
          command: '03221146',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'motor_power': extractInt(data, 3, 5) * 40,
    };
  }
}

class _SpeedCommand extends OBDCommand {
  _SpeedCommand()
      : super(
          name: 'speed',
          description: 'Vehicle speed',
          command: '0322121a',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'speed': extractInt(data, 3, 5) / 10,
    };
  }
}

class _AcOnCommand extends OBDCommand {
  _AcOnCommand()
      : super(
          name: 'ac_on',
          description: 'AC status',
          command: '03221106',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'ac_on': data[3] == 0x01,
    };
  }
}

class _RearHeaterCommand extends OBDCommand {
  _RearHeaterCommand()
      : super(
          name: 'rear_heater',
          description: 'Rear heater status',
          command: '0322110f',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'rear_heater': data[3] == 0xA2,
    };
  }
}

class _EcoModeCommand extends OBDCommand {
  _EcoModeCommand()
      : super(
          name: 'eco_mode',
          description: 'ECO mode status',
          command: '03221318',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'eco_mode': data[3] == 0x10 || data[3] == 0x11,
    };
  }
}

class _EPedalModeCommand extends OBDCommand {
  _EPedalModeCommand()
      : super(
          name: 'e_pedal_mode',
          description: 'e-Pedal mode status',
          command: '0322131A',
          header: '797',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'e_pedal_mode': data[3] == 0x04,
    };
  }
}

class _TpFrCommand extends OBDCommand {
  _TpFrCommand()
      : super(
          name: 'tp_fr',
          description: 'Tyre pressure front right',
          command: '03220e25',
          header: '743',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'tp_fr': data[3] * 1.7236894,
    };
  }
}

class _TpFlCommand extends OBDCommand {
  _TpFlCommand()
      : super(
          name: 'tp_fl',
          description: 'Tyre pressure front left',
          command: '03220e26',
          header: '743',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'tp_fl': data[3] * 1.7236894,
    };
  }
}

class _TpRrCommand extends OBDCommand {
  _TpRrCommand()
      : super(
          name: 'tp_rr',
          description: 'Tyre pressure rear right',
          command: '03220e27',
          header: '743',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'tp_rr': data[3] * 1.7236894,
    };
  }
}

class _TpRlCommand extends OBDCommand {
  _TpRlCommand()
      : super(
          name: 'tp_rl',
          description: 'Tyre pressure rear left',
          command: '03220e28',
          header: '743',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'tp_rl': data[3] * 1.7236894,
    };
  }
}

class _RangeRemainingCommand extends OBDCommand {
  _RangeRemainingCommand()
      : super(
          name: 'range_remaining',
          description: 'Remaining range (km)',
          command: '03220e24',
          header: '743',
        );

  @override
  Map<String, dynamic> decode(List<int> data) {
    return {
      'range_remaining': extractInt(data, 3, 5) / 10,
    };
  }
}

// Utility functions
int extractInt(List<int> bytes, int start, int end) {
  // bigEndian
  if (end - start > 4) {
    throw Exception('Cannot extract more than 4 bytes (32 bits)');
  }

  int result = 0;
  for (int i = start; i < end; i++) {
    result = (result << 8) + bytes[i];
  }
  return result;
}
