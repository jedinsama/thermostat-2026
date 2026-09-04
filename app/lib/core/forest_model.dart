/// On-device Random Forest inference — pure Dart, no plugin, no network.
///
/// Loads the asset produced by `mlops/export_model_dart.py` (format
/// `thermostat-forest-v1`) and traverses the trees directly. A forest is
/// nothing but nested comparisons, so this needs no ML runtime; that keeps
/// the APK small, the inference offline, and the data-protection claim
/// ("no telemetry leaves the device") literally true.
///
/// The export script verifies that this exact traversal reproduces sklearn's
/// `predict_proba` to within 1e-6 on the training frame before writing the
/// asset — so a mismatch here is a shipping error, not a modelling one.
///
/// WHAT IT PREDICTS. Not the present risk band: the band expected
/// `horizonMin` minutes ahead (20 by default). That forecast is the product.
/// The rule engine still evaluates the present, and app_state combines them.
library forest_model;

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

class ForestPrediction {
  /// Forecast risk band (the model's argmax class).
  final int band;

  /// Probability assigned to [band].
  final double confidence;

  /// Full distribution, indexed by the model's class list.
  final List<double> proba;
  final List<int> classes;
  final int horizonMin;

  const ForestPrediction(
      this.band, this.confidence, this.proba, this.classes, this.horizonMin);

  /// Summed probability of Danger or worse — the number that matters for a
  /// warning system, and more informative than argmax when classes are close.
  double get dangerProbability {
    var p = 0.0;
    for (var i = 0; i < classes.length; i++) {
      if (classes[i] >= 3) p += proba[i];
    }
    return p;
  }
}

class ForestModel {
  final List<int> classes;
  final List<String> features;
  final Map<String, double?> impute;
  final int horizonMin;
  final List<_Tree> _trees;

  ForestModel._(this.classes, this.features, this.impute, this.horizonMin,
      this._trees);

  int get treeCount => _trees.length;

  /// Load from a bundled asset. Returns null when the asset is absent — the
  /// app must run without a model (before any is trained), falling back to
  /// the rule engine alone. A missing model is a documented state, not a
  /// crash.
  static Future<ForestModel?> loadAsset(
      [String path = 'assets/model.json']) async {
    for (final p in [path, 'assets/model.example.json']) {
      try {
        return parse(await rootBundle.loadString(p));
      } catch (_) {
        // try the next candidate
      }
    }
    return null;
  }

  static ForestModel parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    if (j['format'] != 'thermostat-forest-v1') {
      throw FormatException('unsupported model format: ${j['format']}');
    }
    final classes = (j['classes'] as List).map((e) => e as int).toList();
    final features = (j['features'] as List).map((e) => e as String).toList();
    final impute = <String, double?>{};
    (j['impute'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      impute[k] = v == null ? null : (v as num).toDouble();
    });
    final trees = (j['trees'] as List)
        .map((t) => _Tree.fromJson(t as Map<String, dynamic>, classes.length))
        .toList();
    return ForestModel._(
        classes, features, impute, (j['horizon_min'] as num?)?.toInt() ?? 20,
        trees);
  }

  /// Build the ordered input vector from a named feature map.
  /// Missing or NaN values take the training-set median, exactly as
  /// train_model.py imputes — so an absent SpO2 reading behaves the same way
  /// on-device as it did during training, instead of becoming a spurious 0.
  List<double> vectorize(Map<String, double> named) {
    return List<double>.generate(features.length, (i) {
      final name = features[i];
      final v = named[name];
      if (v != null && !v.isNaN) return v;
      return impute[name] ?? 0.0;
    });
  }

  ForestPrediction predict(Map<String, double> named) {
    final x = vectorize(named);
    final agg = List<double>.filled(classes.length, 0.0);
    for (final t in _trees) {
      final leaf = t.leafProba(x);
      for (var c = 0; c < agg.length; c++) {
        agg[c] += leaf[c];
      }
    }
    var best = 0;
    for (var c = 0; c < agg.length; c++) {
      agg[c] /= _trees.length;
      if (agg[c] > agg[best]) best = c;
    }
    return ForestPrediction(
        classes[best], agg[best], agg, classes, horizonMin);
  }
}

class _Tree {
  final List<int> f, l, r;
  final List<double> t;
  final Map<int, List<double>> v;
  final int nClasses;

  _Tree(this.f, this.t, this.l, this.r, this.v, this.nClasses);

  factory _Tree.fromJson(Map<String, dynamic> j, int nClasses) {
    final values = <int, List<double>>{};
    (j['v'] as Map<String, dynamic>).forEach((k, val) {
      values[int.parse(k)] =
          (val as List).map((e) => (e as num).toDouble()).toList();
    });
    return _Tree(
      (j['f'] as List).map((e) => e as int).toList(),
      (j['t'] as List).map((e) => (e as num).toDouble()).toList(),
      (j['l'] as List).map((e) => e as int).toList(),
      (j['r'] as List).map((e) => e as int).toList(),
      values,
      nClasses,
    );
  }

  /// sklearn convention: go LEFT when value <= threshold.
  List<double> leafProba(List<double> x) {
    var node = 0;
    while (f[node] != -1) {
      node = x[f[node]] <= t[node] ? l[node] : r[node];
    }
    return v[node] ?? List<double>.filled(nClasses, 0.0);
  }
}
