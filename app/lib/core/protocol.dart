/// THERMOSTAT wire protocol — Dart side.
///
/// Decodes the 41-byte little-endian frame emitted by the ESP32-C3 node and
/// verifies CRC-16/CCITT-FALSE over bytes 0..38. Layout is locked against the
/// canonical test vector; [runSelfTest] MUST pass before any collection
/// starts — a wire mismatch has to fail loudly, never produce plausible
/// wrong numbers.
library protocol;

import 'dart:typed_data';

class TelemetryFrame {
  final int seq;
  final int uptimeMs;
  final double ambientC;
  final double humidityPct;
  final double pressureHpa;
  final double skinC;
  final double hrBpm; // NaN until the PPG solver locks
  final double spo2Pct; // NaN until the PPG solver locks
  final int irRaw;
  final int batteryPct;
  final int dutyS;
  final int flags;
  final DateTime receivedAt;

  TelemetryFrame({
    required this.seq,
    required this.uptimeMs,
    required this.ambientC,
    required this.humidityPct,
    required this.pressureHpa,
    required this.skinC,
    required this.hrBpm,
    required this.spo2Pct,
    required this.irRaw,
    required this.batteryPct,
    required this.dutyS,
    required this.flags,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  bool get bmeOk => flags & 0x01 != 0;
  bool get skinOk => flags & 0x02 != 0;
  bool get ppgOk => flags & 0x04 != 0;
  bool get hrLock => flags & 0x08 != 0;

  /// Thermal Conduction Compensation:  T_ambient = T_BME − k·(T_SKIN − T_BME).
  /// k comes from Ria's bench calibration (see README); 0 disables it.
  double compensatedAmbientC(double k) =>
      ambientC.isNaN || skinC.isNaN ? ambientC : ambientC - k * (skinC - ambientC);

  List<String> toCsvRow(String participantCode) => [
        DateTime.now().toUtc().toIso8601String(),
        participantCode,
        '$seq', '$uptimeMs',
        ambientC.toStringAsFixed(2), humidityPct.toStringAsFixed(2),
        pressureHpa.toStringAsFixed(2), skinC.toStringAsFixed(3),
        hrBpm.isNaN ? '' : hrBpm.toStringAsFixed(1),
        spo2Pct.isNaN ? '' : spo2Pct.toStringAsFixed(1),
        '$irRaw', '$batteryPct', '$dutyS', '$flags',
      ];

  static const csvHeader =
      'timestamp,participant,seq,uptime_ms,ambient_temp_c,relative_humidity_pct,'
      'pressure_hpa,skin_temp_c,heart_rate_bpm,spo2_pct,ir_raw,battery_pct,'
      'duty_s,flags';
}

class ProtocolException implements Exception {
  final String message;
  ProtocolException(this.message);
  @override
  String toString() => 'ProtocolException: $message';
}

/// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, xorout 0.
/// Check value for ASCII "123456789" is 0x29B1.
int crc16CcittFalse(Uint8List data, [int? length]) {
  var crc = 0xFFFF;
  final n = length ?? data.length;
  for (var i = 0; i < n; i++) {
    crc ^= data[i] << 8;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

TelemetryFrame decodeFrame(Uint8List bytes) {
  if (bytes.length != 41) {
    throw ProtocolException('expected 41 bytes, got ${bytes.length}');
  }
  final bd = ByteData.sublistView(bytes);
  final crcWire = bd.getUint16(39, Endian.little);
  final crcCalc = crc16CcittFalse(bytes, 39);
  if (crcWire != crcCalc) {
    throw ProtocolException(
        'CRC mismatch: wire=0x${crcWire.toRadixString(16)} calc=0x${crcCalc.toRadixString(16)}');
  }
  return TelemetryFrame(
    seq: bd.getUint32(0, Endian.little),
    uptimeMs: bd.getUint32(4, Endian.little),
    ambientC: bd.getFloat32(8, Endian.little),
    humidityPct: bd.getFloat32(12, Endian.little),
    pressureHpa: bd.getFloat32(16, Endian.little),
    skinC: bd.getFloat32(20, Endian.little),
    hrBpm: bd.getFloat32(24, Endian.little),
    spo2Pct: bd.getFloat32(28, Endian.little),
    irRaw: bd.getUint32(32, Endian.little),
    batteryPct: bd.getUint8(36),
    dutyS: bd.getUint8(37),
    flags: bd.getUint8(38),
  );
}

/// Canonical project test vector (frame CRC 0xF944). Startup gate: the app
/// refuses to enter collector mode if this fails.
final Uint8List kTestVector = Uint8List.fromList([
  0x01, 0x00, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00, 0x00, 0x00, 0xFA, 0x41,
  0x00, 0x00, 0x91, 0x42, 0x00, 0x00, 0x7C, 0x44, 0x00, 0x00, 0x0A, 0x42,
  0x00, 0x00, 0x9C, 0x42, 0x00, 0x00, 0xC3, 0x42, 0x40, 0xE2, 0x01, 0x00,
  0x1F, 0x3C, 0x0F, 0x44, 0xF9,
]);

bool runSelfTest() {
  if (crc16CcittFalse(Uint8List.fromList('123456789'.codeUnits)) != 0x29B1) {
    return false;
  }
  try {
    final f = decodeFrame(kTestVector);
    return f.seq == 1 &&
        f.uptimeMs == 1000 &&
        (f.ambientC - 31.25).abs() < 1e-6 &&
        (f.humidityPct - 72.5).abs() < 1e-6 &&
        (f.pressureHpa - 1008.0).abs() < 1e-6 &&
        (f.skinC - 34.5).abs() < 1e-6 &&
        (f.hrBpm - 78.0).abs() < 1e-6 &&
        (f.spo2Pct - 97.5).abs() < 1e-6 &&
        f.irRaw == 123456 &&
        f.batteryPct == 31 &&
        f.dutyS == 60 &&
        f.flags == 15;
  } on ProtocolException {
    return false;
  }
}
