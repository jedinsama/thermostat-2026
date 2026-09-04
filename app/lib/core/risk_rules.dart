/// THERMOSTAT rule-based risk engine — Dart port of analysis/labeling.py.
///
/// The canonical implementation is labeling.py; this port must agree with it.
/// If you change a threshold here, change it there and re-run both self-tests
/// (mlops/sync check). Bands: 0 Safe · 1 Caution · 2 Extreme Caution ·
/// 3 Danger · 4 Extreme Danger (PAGASA naming).
library risk_rules;

import 'dart:math' as math;

const riskNames = ['Safe', 'Caution', 'Extreme Caution', 'Danger', 'Extreme Danger'];
const int kDangerBand = 3;

class UserProfile {
  final String userId; // participant code in research; display name in product
  final double ageYears;
  final double heightCm;
  final double weightKg;
  final double restingHrBpm;
  final bool cardiovascularCondition;
  final String emergencyContactName;
  final String emergencyContactPhone;

  UserProfile({
    required this.userId,
    required this.ageYears,
    required this.heightCm,
    required this.weightKg,
    required this.restingHrBpm,
    this.cardiovascularCondition = false,
    this.emergencyContactName = '',
    this.emergencyContactPhone = '',
  }) {
    if (ageYears <= 0 || ageYears >= 120) throw ArgumentError('implausible age');
    if (heightCm <= 50 || heightCm >= 250) throw ArgumentError('implausible height');
    if (weightKg <= 10 || weightKg >= 400) throw ArgumentError('implausible weight');
    if (restingHrBpm <= 25 || restingHrBpm >= 130) {
      throw ArgumentError('implausible resting HR');
    }
  }

  double get bmi => weightKg / math.pow(heightCm / 100.0, 2);

  /// Tanaka et al. (2001) — more accurate than 220−age in older adults.
  double get hrMax => 208.0 - 0.7 * ageYears;

  double get hrReserve {
    final r = hrMax - restingHrBpm;
    if (r <= 0) throw StateError('non-positive HR reserve');
    return r;
  }

  bool get isAgeVulnerable => ageYears >= 65 || ageYears <= 12;
  bool get isObese => bmi >= 30.0;

  Map<String, dynamic> toJson() => {
        'userId': userId, 'ageYears': ageYears, 'heightCm': heightCm,
        'weightKg': weightKg, 'restingHrBpm': restingHrBpm,
        'cardiovascularCondition': cardiovascularCondition,
        'emergencyContactName': emergencyContactName,
        'emergencyContactPhone': emergencyContactPhone,
      };

  static UserProfile fromJson(Map<String, dynamic> j) => UserProfile(
        userId: j['userId'] as String,
        ageYears: (j['ageYears'] as num).toDouble(),
        heightCm: (j['heightCm'] as num).toDouble(),
        weightKg: (j['weightKg'] as num).toDouble(),
        restingHrBpm: (j['restingHrBpm'] as num).toDouble(),
        cardiovascularCondition: j['cardiovascularCondition'] as bool? ?? false,
        emergencyContactName: j['emergencyContactName'] as String? ?? '',
        emergencyContactPhone: j['emergencyContactPhone'] as String? ?? '',
      );
}

/// NWS Rothfusz heat index with both standard adjustments; input/output °C.
double rothfuszHeatIndexC(double tempC, double rhPct) {
  if (tempC.isNaN || rhPct.isNaN) return double.nan;
  final tF = tempC * 9 / 5 + 32;
  final simple = 0.5 * (tF + 61.0 + (tF - 68.0) * 1.2 + rhPct * 0.094);
  if ((simple + tF) / 2 < 80.0) return (simple - 32) * 5 / 9;
  var hiF = -42.379 +
      2.04901523 * tF +
      10.14333127 * rhPct -
      0.22475541 * tF * rhPct -
      0.00683783 * tF * tF -
      0.05481717 * rhPct * rhPct +
      0.00122874 * tF * tF * rhPct +
      0.00085282 * tF * rhPct * rhPct -
      0.00000199 * tF * tF * rhPct * rhPct;
  if (rhPct < 13 && tF >= 80 && tF <= 112) {
    hiF -= ((13 - rhPct) / 4) * math.sqrt((17 - (tF - 95).abs()) / 17);
  } else if (rhPct > 85 && tF >= 80 && tF <= 87) {
    hiF += ((rhPct - 85) / 10) * ((87 - tF) / 5);
  }
  return (hiF - 32) * 5 / 9;
}

/// PAGASA heat-index bands → ordinal class 0..4 (−1 on NaN).
int pagasaRiskClass(double hiC) {
  if (hiC.isNaN) return -1;
  if (hiC < 27) return 0;
  if (hiC <= 32) return 1;
  if (hiC <= 41) return 2;
  if (hiC <= 51) return 3;
  return 4;
}

/// Heart-rate-only Physiological Strain Index, 0–10 (Moran et al., 1998).
double psiHeartRate(double hrBpm, UserProfile p) {
  if (hrBpm.isNaN) return double.nan;
  final psi = 5.0 * (hrBpm - p.restingHrBpm) / p.hrReserve;
  return psi.clamp(0.0, 10.0);
}

int psiRiskClass(double psi) {
  if (psi.isNaN) return -1;
  if (psi < 3) return 0;
  if (psi < 5) return 1;
  if (psi < 7) return 2;
  if (psi < 9) return 3;
  return 4;
}

/// Fusion rule — mirrors labeling.py exactly, including the graduated
/// escalation cap (MAX_ESCALATION=1; tighter cap of 1 when base ≥ 3).
int fuseRisk(int envClass, int psiClass, UserProfile p, {bool spo2Desat = false}) {
  if (envClass < 0 && psiClass < 0) return -1;
  final base = math.max(envClass, psiClass);
  var esc = 0;
  if (p.cardiovascularCondition && envClass >= 2) esc += 1;
  if (p.isObese && envClass >= 2) esc += 1;
  if (p.isAgeVulnerable) esc += 1;
  if (spo2Desat) esc += 1;
  final cap = base <= 2 ? 1 : 1; // MAX_ESCALATION = 1, graduated form kept
  esc = math.min(esc, cap);
  return (base + esc).clamp(0, 4);
}

class RiskAssessment {
  final double heatIndexC;
  final int envClass;
  final double psi;
  final int psiClass;
  final int ruleBand; // fused, pre-calibration
  final int finalBand; // post-calibration (never below rule Danger — see
  // personal_calibration.dart safety floor)
  RiskAssessment(this.heatIndexC, this.envClass, this.psi, this.psiClass,
      this.ruleBand, this.finalBand);
  String get name =>
      finalBand >= 0 && finalBand < riskNames.length ? riskNames[finalBand] : '—';
}
