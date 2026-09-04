/// Rolling feature buffer — the on-device twin of labeling.py's
/// `add_windowed_features`.
///
/// The forest is trained on mean / sd / gradient over 5, 15 and 60-minute
/// windows (Tartarini et al.'s published schema). A single telemetry frame
/// therefore cannot be classified: the model needs trajectory, which is the
/// whole point — the rate of change of heart rate under rising ambient
/// temperature is the early-warning signal a snapshot cannot express.
///
/// This class keeps a time-bounded buffer of frames and produces the named
/// feature map the model expects. It MUST stay numerically identical to
/// labeling.py; if you change a window or a statistic here, change it there
/// and re-export the model.
///
/// Warm-up: the 60-minute window is incomplete for the first hour of wear, so
/// [ready] is false until [warmupRemaining] reaches zero. The UI says
/// "learning your baseline" during that period rather than showing a forecast
/// the model is not entitled to make.
library feature_window;

import 'dart:math' as math;

class _Sample {
  final DateTime t;
  final double ambientC, humidityPct, hrBpm, spo2Pct;
  _Sample(this.t, this.ambientC, this.humidityPct, this.hrBpm, this.spo2Pct);
}

class FeatureWindow {
  /// Must match FEATURE_WINDOWS_MIN in labeling.py.
  static const windowsMin = [5, 15, 60];
  static const int maxWindowMin = 60;

  final List<_Sample> _buf = [];
  DateTime? _firstAt;

  /// Feed one decoded frame (already thermally compensated).
  void add({
    required DateTime at,
    required double compensatedAmbientC,
    required double humidityPct,
    required double hrBpm,
    required double spo2Pct,
  }) {
    _firstAt ??= at;
    _buf.add(_Sample(at, compensatedAmbientC, humidityPct, hrBpm, spo2Pct));
    // Drop anything older than the longest window; memory stays bounded
    // regardless of session length.
    final cutoff = at.subtract(const Duration(minutes: maxWindowMin));
    _buf.removeWhere((s) => s.t.isBefore(cutoff));
  }

  bool get ready =>
      _firstAt != null &&
      _buf.isNotEmpty &&
      _buf.last.t.difference(_firstAt!).inMinutes >= maxWindowMin;

  Duration get warmupRemaining {
    if (_firstAt == null || _buf.isEmpty) {
      return const Duration(minutes: maxWindowMin);
    }
    final elapsed = _buf.last.t.difference(_firstAt!);
    final left = const Duration(minutes: maxWindowMin) - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  int get sampleCount => _buf.length;

  List<_Sample> _within(int minutes) {
    if (_buf.isEmpty) return const [];
    final cutoff = _buf.last.t.subtract(Duration(minutes: minutes));
    return _buf.where((s) => !s.t.isBefore(cutoff)).toList();
  }

  static double _mean(Iterable<double> xs) {
    final v = xs.where((x) => !x.isNaN).toList();
    if (v.isEmpty) return double.nan;
    return v.reduce((a, b) => a + b) / v.length;
  }

  /// Sample standard deviation (ddof=1), matching pandas' rolling().std().
  static double _sd(Iterable<double> xs) {
    final v = xs.where((x) => !x.isNaN).toList();
    if (v.length < 2) return double.nan;
    final m = _mean(v);
    final ss = v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b);
    return math.sqrt(ss / (v.length - 1));
  }

  /// (current − first-in-window) / window_minutes — labeling.py's gradient.
  static double _grad(List<double> xs, int windowMin) {
    final v = xs.where((x) => !x.isNaN).toList();
    if (v.length < 2) return double.nan;
    return (v.last - v.first) / windowMin;
  }

  /// Named features in exactly the vocabulary the exported model uses.
  /// Profile-derived and rule-derived values are passed in because they are
  /// computed elsewhere (risk_rules.dart) and must not be duplicated.
  Map<String, double> features({
    required double ageYears,
    required double bmi,
    required bool cardiovascular,
    required double heatIndexC,
    required double psi,
  }) {
    final out = <String, double>{
      'age_years': ageYears,
      'bmi': bmi,
      'cardiovascular_flag': cardiovascular ? 1.0 : 0.0,
      'heat_index_c': heatIndexC,
      'psi': psi,
    };
    if (_buf.isEmpty) return out;

    final last = _buf.last;
    out['ambient_temp_c'] = last.ambientC;
    out['relative_humidity_pct'] = last.humidityPct;
    out['heart_rate_bpm'] = last.hrBpm;
    out['spo2_pct'] = last.spo2Pct;

    const series = {
      'ambient_temp_c': 0,
      'relative_humidity_pct': 1,
      'heart_rate_bpm': 2,
      'spo2_pct': 3,
    };
    for (final w in windowsMin) {
      final win = _within(w);
      for (final entry in series.entries) {
        final name = entry.key;
        final xs = win.map((s) => switch (entry.value) {
              0 => s.ambientC,
              1 => s.humidityPct,
              2 => s.hrBpm,
              _ => s.spo2Pct,
            }).toList();
        out['mean.${name}_$w'] = _mean(xs);
        out['sd.${name}_$w'] = _sd(xs);
        out['grad.${name}_$w'] = _grad(xs, w);
      }
    }
    return out;
  }

  void clear() {
    _buf.clear();
    _firstAt = null;
  }
}
