/// Session CSV logger — research collector mode.
///
/// STORAGE. Telemetry is written to APPLICATION-PRIVATE storage
/// (`getApplicationDocumentsDirectory()` → `/data/data/<pkg>/app_flutter/`).
/// No other app can read it, it is invisible to file managers and to MTP, and
/// with `android:allowBackup="false"` it is never synced to Google's servers.
/// That is what makes the manuscript's "no research data leaves the device or
/// the country" statement literally true.
///
/// IDENTIFIERS. Rows carry the participant CODE only. The constructor rejects
/// anything that is not P-nn, so the data-protection plan is enforced at the
/// input boundary rather than by discipline.
///
/// EXPORT. Deliberately NOT the Android share sheet: that sheet offers Gmail,
/// Drive and Messenger, and one mis-tap would transmit sensitive personal
/// information over a networked channel the protocol forbids. Export instead
/// goes through the system Storage Access Framework save dialog
/// ([exportToPickedLocation]), where the researcher chooses an explicit local
/// destination — a USB-OTG drive, an SD card, or on-device Documents for a
/// subsequent cable copy. See README §4 for the `adb pull` route, which is the
/// most direct cable transfer.
///
/// VERIFICATION. [summary] reports the row count and byte size so the
/// researcher can confirm the copied file matches before deleting the local
/// one (`wc -l` and `ls -l` on the research laptop). This is the evidence
/// behind the session log sheet's "file verified complete and readable" tick.
library csv_logger;

import 'dart:io';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'protocol.dart';

final RegExp kParticipantCode = RegExp(r'^P-\d{2}$');

/// What was written, for verification against the copy on the laptop.
class SessionSummary {
  final String fileName;
  final int rows;
  final int bytes;
  const SessionSummary(this.fileName, this.rows, this.bytes);

  /// The CSV has one header line plus one line per row.
  int get expectedLines => rows + 1;

  @override
  String toString() =>
      '$fileName · $rows rows · $bytes bytes · expect $expectedLines lines';
}

class CsvLogger {
  final String participantCode;
  IOSink? _sink;
  File? _file;
  int rows = 0;

  CsvLogger(this.participantCode) {
    if (!kParticipantCode.hasMatch(participantCode)) {
      throw ArgumentError(
          'participant identifier must be a code like P-01 — names are not accepted');
    }
  }

  File? get file => _file;

  Future<File> start() async {
    final dir = await getApplicationDocumentsDirectory();
    final sessions = Directory('${dir.path}/sessions');
    await sessions.create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .split('.')
        .first;
    _file = File('${sessions.path}/${participantCode}_$stamp.csv');
    _sink = _file!.openWrite();
    _sink!.writeln(TelemetryFrame.csvHeader);
    rows = 0;
    return _file!;
  }

  void log(TelemetryFrame frame) {
    final s = _sink;
    if (s == null) return;
    s.writeln(frame.toCsvRow(participantCode).join(','));
    rows++;
    // Flush periodically so a crash or flat battery costs at most ~20 rows
    // rather than the whole session.
    if (rows % 20 == 0) s.flush();
  }

  Future<File?> stop() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    return _file;
  }

  /// Row count and byte size of the closed session file. Call after [stop].
  Future<SessionSummary?> summary() async {
    final f = _file;
    if (f == null || !await f.exists()) return null;
    return SessionSummary(
        f.path.split('/').last, rows, await f.length());
  }

  /// Open the system save dialog and copy the session file to the location
  /// the researcher picks (USB-OTG drive, SD card, Documents…). Returns the
  /// destination path/URI reported by the picker, or null if cancelled.
  ///
  /// The SAF picker lists storage providers, not messaging apps, so the
  /// forbidden networked channels are not reachable from here.
  Future<String?> exportToPickedLocation() async {
    final f = _file;
    if (f == null || !await f.exists()) return null;
    return FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        sourceFilePath: f.path,
        fileName: f.path.split('/').last,
      ),
    );
  }

  /// Delete after verified transfer — performed in the participant's presence
  /// and recorded on the session log sheet.
  Future<bool> deleteSession() async {
    final f = _file;
    if (f == null) return false;
    if (await f.exists()) await f.delete();
    _file = null;
    return true;
  }

  /// Sessions still held on this phone. Must be empty before the participant
  /// leaves; the collector screen shows this list for exactly that check.
  static Future<List<File>> pendingSessions() async {
    final dir = await getApplicationDocumentsDirectory();
    final sessions = Directory('${dir.path}/sessions');
    if (!await sessions.exists()) return [];
    return sessions
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.csv'))
        .toList();
  }

  /// Export/delete an older session left on the phone (e.g. a transfer that
  /// was interrupted). Same SAF picker, same protocol.
  static Future<String?> exportExisting(File f) async {
    if (!await f.exists()) return null;
    return FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
          sourceFilePath: f.path, fileName: f.path.split('/').last),
    );
  }
}
