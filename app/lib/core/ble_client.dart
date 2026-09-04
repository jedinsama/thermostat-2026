/// BLE link to the THERMOSTAT node (flutter_blue_plus).
///
/// Scans for the node's service UUID, subscribes to the telemetry
/// characteristic, decodes each 41-byte frame (CRC-checked), and exposes a
/// broadcast stream. Frames failing CRC are counted and dropped — never
/// surfaced as data.
library ble_client;

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'protocol.dart';

class BleClient {
  static final Guid svcUuid = Guid('7e400001-b5a3-f393-e0a9-e50e24dcca9e');
  static final Guid chrUuid = Guid('7e400002-b5a3-f393-e0a9-e50e24dcca9e');

  final _frames = StreamController<TelemetryFrame>.broadcast();
  final _status = StreamController<String>.broadcast();
  Stream<TelemetryFrame> get frames => _frames.stream;
  Stream<String> get status => _status.stream;

  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  int framesOk = 0, framesBad = 0;
  bool get connected => _device != null;

  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    _status.add('scanning…');
    await FlutterBluePlus.startScan(withServices: [svcUuid], timeout: timeout);
    final completer = Completer<BluetoothDevice>();
    final scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (!completer.isCompleted) completer.complete(r.device);
      }
    });
    try {
      _device = await completer.future.timeout(timeout);
    } on TimeoutException {
      _status.add('no THERMOSTAT node found');
      await scanSub.cancel();
      await FlutterBluePlus.stopScan();
      rethrow;
    }
    await scanSub.cancel();
    await FlutterBluePlus.stopScan();

    final dev = _device!;
    _status.add('connecting to ${dev.platformName}…');
    await dev.connect(autoConnect: false);
    _connSub = dev.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _status.add('disconnected — will retry');
        _reconnect();
      }
    });

    final services = await dev.discoverServices();
    final svc = services.firstWhere((s) => s.uuid == svcUuid,
        orElse: () => throw StateError('telemetry service missing'));
    final chr = svc.characteristics.firstWhere((c) => c.uuid == chrUuid,
        orElse: () => throw StateError('telemetry characteristic missing'));
    await chr.setNotifyValue(true);
    _valueSub = chr.onValueReceived.listen(_onBytes);
    _status.add('connected');
  }

  void _onBytes(List<int> value) {
    try {
      final frame = decodeFrame(Uint8List.fromList(value));
      framesOk++;
      _frames.add(frame);
    } on ProtocolException {
      framesBad++; // corrupt frame: drop, count, never emit
      if (framesBad % 10 == 1) {
        _status.add('dropped $framesBad corrupt frame(s)');
      }
    }
  }

  Future<void> _reconnect() async {
    final dev = _device;
    if (dev == null) return;
    for (var attempt = 1; attempt <= 5; attempt++) {
      await Future<void>.delayed(Duration(seconds: attempt * 2));
      try {
        await dev.connect(autoConnect: false);
        final services = await dev.discoverServices();
        final svc = services.firstWhere((s) => s.uuid == svcUuid);
        final chr = svc.characteristics.firstWhere((c) => c.uuid == chrUuid);
        await chr.setNotifyValue(true);
        await _valueSub?.cancel();
        _valueSub = chr.onValueReceived.listen(_onBytes);
        _status.add('reconnected');
        return;
      } catch (_) {/* next attempt */}
    }
    _status.add('reconnect failed — check the wearable');
  }

  Future<void> disconnect() async {
    await _valueSub?.cancel();
    await _connSub?.cancel();
    await _device?.disconnect();
    _device = null;
    _status.add('closed');
  }
}
