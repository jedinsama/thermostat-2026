/// THERMOSTAT rule-based risk engine — Dart port of mlops/labeling.py.
///
/// The canonical implementation is labeling.py; this port must agree with it.
/// If you change a threshold here, change it there and re-run both self-tests:
///
///     cd mlops && python verify_dart_parity.py && cp golden_vectors.json ../app/test/
///     cd ../app && flutter test test/parity_test.dart
///
/// Bands: 0 Safe · 1 Caution · 2 Extreme Caution · 3 Danger ·
/// 4 Extreme Danger (PAGASA naming).
library risk_rules;

import 'dart:math' as math;

const riskNames = ['Safe', 'Caution', 'Extreme Caution', 'Danger', 'Extreme Danger'];
const int kDangerBand = 3;

/// Cap on the total personalized vulnerability bump, in bands.
///
/// MUST equal MAX_ESCALATION in mlops/labeling.py. It is named here rather
/// than inlined so that a change on the Python side has one obvious place to
/// land on this side; a hard-coded literal is how the two implementations
/// drift apart without anyone noticing.
const int kMaxEscalation = 1;

/// Tighter cap applied at the top of the scale (base >= 3).
///
/// When conditions are already Danger for everyone, further personalized
/// escalation pins every vulnerable user at Extreme Danger all day —
/// clinically implausible, and useless as a training signal. Personalization
/// carries the most information in the MIDDLE bands, where a generic
/// heat-index system tells a vulnerable person they are fine and they are not.
const int kMaxEscalationAtDanger = 1;

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
///
/// PSI = 5 * (HR_t − HR_rest) / (HR_max − HR_rest)
///
/// The denominator is where personalization enters the system: identical
/// telemetry yields a different strain band for a 20-year-old and a
/// 70-year-old, because HR_max follows Tanaka and HR_rest is measured at
/// enrollment.
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

/// Fusion rule — mirrors fuse_risk() in mlops/labeling.py exactly.
///
///     base = max(envClass, psiClass)
///     +1 if cardiovascular condition AND envClass >= 2
///     +1 if BMI >= 30                AND envClass >= 2
///     +1 if age >= 65 or <= 12
///     +1 if sustained SpO2 desaturation
///     escalation capped, then clamped to [0, 4]
///
/// Comorbidity and obesity are gated on envClass >= 2 because they amplify
/// heat vulnerability rather than create risk in a cool environment. Age and
/// desaturation are ungated.
int fuseRisk(int envClass, int psiClass, UserProfile p, {bool spo2Desat = false}) {
  if (envClass < 0 && psiClass < 0) return -1;
  final base = math.max(envClass, psiClass);
  var esc = 0;
  if (p.cardiovascularCondition && envClass >= 2) esc += 1;
  if (p.isObese && envClass >= 2) esc += 1;
  if (p.isAgeVulnerable) esc += 1;
  if (spo2Desat) esc += 1;

  // Matches `effective_cap = MAX_ESCALATION if base <= 2 else 1` in
  // labeling.py. Both constants are 1 today; they are named separately so the
  // graduated form survives a change to either.
  final cap = base <= 2 ? kMaxEscalation : kMaxEscalationAtDanger;
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
