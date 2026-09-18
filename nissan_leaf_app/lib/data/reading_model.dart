class Reading {
  final int? id; // Nullable for new entries
  final DateTime timestamp;
  final double stateOfCharge;
  final double batteryHealth;
  final double batteryVoltage;
  final double batteryCapacity;
  final double estimatedRange;

  // Analytics fields (data-pipeline plan, Phase B) - nullable because older
  // rows predate them, and the OBD reads themselves are best-effort (see
  // BluetoothDeviceManager.collectCarData()), so a given reading may be
  // missing some or all of them even going forward.
  final double? speed;
  final int? odometer;
  final double? ambientTemp;
  final int? l1l2Charges;
  final int? quickCharges;

  Reading({
    this.id,
    required this.timestamp,
    required this.stateOfCharge,
    required this.batteryHealth,
    required this.batteryVoltage,
    required this.batteryCapacity,
    required this.estimatedRange,
    this.speed,
    this.odometer,
    this.ambientTemp,
    this.l1l2Charges,
    this.quickCharges,
  });

  // Convert a Reading to a Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'stateOfCharge': stateOfCharge,
      'batteryHealth': batteryHealth,
      'batteryVoltage': batteryVoltage,
      'batteryCapacity': batteryCapacity,
      'estimatedRange': estimatedRange,
      'speed': speed,
      'odometer': odometer,
      'ambientTemp': ambientTemp,
      'l1l2Charges': l1l2Charges,
      'quickCharges': quickCharges,
    };
  }

  // Create a Reading from a Map (from database)
  factory Reading.fromMap(Map<String, dynamic> map) {
    return Reading(
      id: map['id'],
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] ?? DateTime.now()),
      stateOfCharge: map['stateOfCharge'] ?? 0.0,
      batteryHealth: map['batteryHealth'] ?? 0.0,
      batteryVoltage: map['batteryVoltage'] ?? 0.0,
      batteryCapacity: map['batteryCapacity'] ?? 0.0,
      estimatedRange: map['estimatedRange'] ?? 0.0,
      speed: (map['speed'] as num?)?.toDouble(),
      odometer: (map['odometer'] as num?)?.toInt(),
      ambientTemp: (map['ambientTemp'] as num?)?.toDouble(),
      l1l2Charges: (map['l1l2Charges'] as num?)?.toInt(),
      quickCharges: (map['quickCharges'] as num?)?.toInt(),
    );
  }

  // Create a Reading from OBD data
  factory Reading.fromObd(Map<String, dynamic> lbcData, Map<String, dynamic> rangeData) {
    return Reading(
      timestamp: DateTime.now(),
      stateOfCharge: (lbcData['state_of_charge'] ?? 0).toDouble(),
      batteryHealth: (lbcData['hv_battery_health'] ?? 0).toDouble(),
      batteryVoltage: (lbcData['hv_battery_voltage'] ?? 0).toDouble(),
      batteryCapacity: (lbcData['hv_battery_Ah'] ?? 0).toDouble(),
      estimatedRange: (rangeData['range_remaining'] ?? 0).toDouble(),
    );
  }

  factory Reading.fromObdMap(Map<String, dynamic> odbData) {
    return Reading(
      timestamp: odbData['timeStamp'] ?? DateTime.now(),
      stateOfCharge: (odbData['state_of_charge'] as num?)?.toDouble() ?? 00.0,
      batteryHealth: (odbData['hv_battery_health'] as num?)?.toDouble() ?? 0.0,
      batteryVoltage: (odbData['hv_battery_voltage'] as num?)?.toDouble() ?? 0.0,
      batteryCapacity: (odbData['hv_battery_Ah'] as num?)?.toDouble() ?? 0.0,
      estimatedRange: (odbData['range_remaining'] as num?)?.toDouble() ?? 0.0,
      speed: (odbData['speed'] as num?)?.toDouble(),
      odometer: (odbData['odometer'] as num?)?.toInt(),
      ambientTemp: (odbData['ambient_temp'] as num?)?.toDouble(),
      l1l2Charges: (odbData['l1_l2_charges'] as num?)?.toInt(),
      quickCharges: (odbData['quick_charges'] as num?)?.toInt(),
    );
  }

  // Create a copy of this Reading with the given fields replaced
  Reading copyWith({
    int? id,
    DateTime? timestamp,
    double? stateOfCharge,
    double? batteryHealth,
    double? batteryVoltage,
    double? batteryCapacity,
    double? estimatedRange,
    double? speed,
    int? odometer,
    double? ambientTemp,
    int? l1l2Charges,
    int? quickCharges,
  }) {
    return Reading(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      stateOfCharge: stateOfCharge ?? this.stateOfCharge,
      batteryHealth: batteryHealth ?? this.batteryHealth,
      batteryVoltage: batteryVoltage ?? this.batteryVoltage,
      batteryCapacity: batteryCapacity ?? this.batteryCapacity,
      estimatedRange: estimatedRange ?? this.estimatedRange,
      speed: speed ?? this.speed,
      odometer: odometer ?? this.odometer,
      ambientTemp: ambientTemp ?? this.ambientTemp,
      l1l2Charges: l1l2Charges ?? this.l1l2Charges,
      quickCharges: quickCharges ?? this.quickCharges,
    );
  }
}
