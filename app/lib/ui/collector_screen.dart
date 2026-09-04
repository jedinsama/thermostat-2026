/// Research collector — the hidden mode.
///
/// Protocol-compliant by construction:
///  · accepts a participant CODE only (P-nn) — the field cannot hold a name;
///  · shows NO risk score, band, alert, survey, or SOS (data-logging only);
///  · logs to app-private storage; exports through the system save dialog to
///    a local destination only (never the share sheet — see csv_logger.dart);
///  · delete-after-verified-transfer, used in the participant's presence.
library collector_screen;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/ble_client.dart';
import '../core/csv_logger.dart';
import '../core/protocol.dart';

class CollectorScreen extends StatefulWidget {
  const CollectorScreen({super.key});
  @override
  State<CollectorScreen> createState() => _CollectorScreenState();
}

class _CollectorScreenState extends State<CollectorScreen> {
  final _code = TextEditingController();
  CsvLogger? _logger;
  TelemetryFrame? _last;
  SessionSummary? _summary;
  String _status = 'idle';
  int _rows = 0;
  List<File> _pending = [];

  @override
  void initState() {
    super.initState();
    _refreshPending();
  }

  Future<void> _refreshPending() async {
    _pending = await CsvLogger.pendingSessions();
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    final code = _code.text.trim().toUpperCase();
    if (!kParticipantCode.hasMatch(code)) {
      setState(() => _status = 'enter a participant CODE like P-01 — names are refused');
      return;
    }
    if (!runSelfTest()) {
      setState(() => _status = 'PROTOCOL SELF-TEST FAILED — collection refused');
      return;
    }
    final ble = context.read<BleClient>();
    _logger = CsvLogger(code);
    final file = await _logger!.start();
    setState(() => _status = 'logging → ${file.path.split('/').last}');
    ble.status.listen((s) => mounted ? setState(() => _status = s) : null);
    try {
      if (!ble.connected) await ble.connect();
      ble.frames.listen((f) {
        _logger?.log(f);
        if (mounted) setState(() { _last = f; _rows = _logger?.rows ?? 0; });
      });
    } catch (_) {/* status stream reported it */}
  }

  Future<void> _stop() async {
    await _logger?.stop();
    _summary = await _logger?.summary();
    setState(() => _status =
        _summary == null ? 'idle' : 'session closed — verify against: $_summary');
    await _refreshPending();
  }

  /// Opens the system save dialog (Storage Access Framework), NOT the share
  /// sheet: the picker lists storage providers only, so email/messaging/cloud
  /// targets — forbidden by the data-protection plan — are not reachable.
  Future<void> _export() async {
    final dest = await _logger?.exportToPickedLocation();
    if (!mounted) return;
    setState(() => _status = dest == null
        ? 'export cancelled — nothing copied'
        : 'copied to: $dest — now verify line count on the research storage');
  }

  Future<void> _deleteAfterTransfer() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete session copy?'),
        content: const Text(
            'Confirm ONLY after the transferred file has been verified complete '
            'and readable on the research storage, with the participant present. '
            'Record the deletion on the session log sheet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Verified — delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await _logger?.deleteSession();
      await _refreshPending();
      setState(() => _status = 'local copy deleted (record on log sheet)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _last;
    return Scaffold(
      appBar: AppBar(title: const Text('Research collector'), backgroundColor: Colors.deepOrange.shade100),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text('DATA LOGGING ONLY — this screen computes and displays no '
                'risk output. Raw sensor values are shown solely so the researcher '
                'can verify the link is alive.'),
          ),
        ),
        TextField(
          controller: _code,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Participant code',
            helperText: 'format P-01 … P-99 — the study never records names',
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: _start, icon: const Icon(Icons.fiber_manual_record), label: const Text('Start'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(onPressed: _stop, icon: const Icon(Icons.stop), label: const Text('Stop'))),
        ]),
        const SizedBox(height: 12),
        Text('rows logged: $_rows · $_status'),
        const Divider(height: 32),
        if (f != null) ...[
          Text('link check — frame #${f.seq}'),
          Text('amb ${f.ambientC.toStringAsFixed(1)}°C · rh ${f.humidityPct.toStringAsFixed(0)}% · '
              'skin ${f.skinC.toStringAsFixed(2)}°C · hr ${f.hrBpm.isNaN ? "—" : f.hrBpm.toStringAsFixed(0)} · '
              'spo2 ${f.spo2Pct.isNaN ? "—" : f.spo2Pct.toStringAsFixed(0)} · '
              'batt ${f.batteryPct}% · flags 0x${f.flags.toRadixString(16)}'),
        ],
        const Divider(height: 32),
        if (_summary != null)
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Verify the copy against these numbers:',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Text('file      ${_summary!.fileName}'),
                Text('rows      ${_summary!.rows}'),
                Text('bytes     ${_summary!.bytes}'),
                Text('lines     ${_summary!.expectedLines}  (header + rows)'),
                const SizedBox(height: 6),
                const Text('On the research laptop:  wc -l <file>   and   ls -l <file>',
                    style: TextStyle(fontSize: 12, fontFamily: 'monospace')),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(onPressed: _export, icon: const Icon(Icons.save_alt), label: const Text('Export session (choose local destination)')),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _deleteAfterTransfer,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete after verified transfer'),
        ),
        const SizedBox(height: 16),
        Text('sessions still on this phone: ${_pending.length}',
            style: Theme.of(context).textTheme.bodySmall),
        ..._pending.map((p) => Text('  · ${p.path.split('/').last}',
            style: Theme.of(context).textTheme.bodySmall)),
      ]),
    );
  }
}
