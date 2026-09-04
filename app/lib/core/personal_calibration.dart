/// On-device personal calibration with a hard safety floor.
///
/// Learns a per-user heat-index offset (°C) from wellness-survey responses:
/// symptoms reported below Danger → protective shift (risk assessed sooner);
/// repeated "feeling fine" at elevated bands → small permissive shift.
///
/// SAFETY FLOOR (non-negotiable): once the RULE-BASED band reaches Danger
/// (band 3), calibration may RAISE the assessed band but may never lower it.
/// Simulation caught the alternative — a 43 °C heat index personalised down
/// from Danger — which is precisely the failure this project exists to
/// prevent. Offsets are asymmetric: up to +8 °C protective, only −3 °C
/// permissive. Do not widen these without adviser sign-off.
library personal_calibration;

import 'dart:convert';
import 'risk_rules.dart';

class PersonalCalibration {
  static const double maxProtectiveC = 8.0; // shifts HI up → earlier warnings
  static const double maxPermissiveC = -3.0; // shifts HI down → later warnings
  static const int activationResponses = 3; // inert until 3 survey answers
  static const double baseLearningRate = 1.5; // °C per response, decays

  double offsetC;
  int responses;

  PersonalCalibration({this.offsetC = 0.0, this.responses = 0});

  bool get active => responses >= activationResponses;
  double get _lr => baseLearningRate / (1 + 0.25 * responses); // decaying

  /// [hadSymptoms]: any yes on the wellness survey. [bandAtSurvey]: the
  /// rule-based band shown/active when the survey fired.
  void learn({required bool hadSymptoms, required int bandAtSurvey}) {
    responses += 1;
    if (hadSymptoms && bandAtSurvey < kDangerBand) {
      offsetC += _lr; // felt bad before the rule said Danger → protect earlier
    } else if (!hadSymptoms && bandAtSurvey >= 2) {
      offsetC -= _lr * 0.4; // permissive learning is deliberately slower
    }
    offsetC = offsetC.clamp(maxPermissiveC, maxProtectiveC);
  }

  /// Full evaluation: rule band from raw inputs, calibrated band from the
  /// offset heat index, floor applied.
  RiskAssessment assess({
    required double compensatedAmbientC,
    required double humidityPct,
    required double hrBpm,
    required UserProfile profile,
    bool spo2Desat = false,
  }) {
    final hi = rothfuszHeatIndexC(compensatedAmbientC, humidityPct);
    final env = pagasaRiskClass(hi);
    final psi = psiHeartRate(hrBpm, profile);
    final psiC = psiRiskClass(psi);
    final rule = fuseRisk(env, psiC, profile, spo2Desat: spo2Desat);

    var calBand = rule;
    if (active && !hi.isNaN) {
      final hiCal = hi + offsetC;
      final envCal = pagasaRiskClass(hiCal);
      calBand = fuseRisk(envCal, psiC, profile, spo2Desat: spo2Desat);
    }
    // SAFETY FLOOR: calibration can raise, never lower past rule Danger.
    final finalBand = rule >= kDangerBand && calBand < rule ? rule : calBand;
    return RiskAssessment(hi, env, psi, psiC, rule, finalBand);
  }

  String toJson() => jsonEncode({'offsetC': offsetC, 'responses': responses});
  static PersonalCalibration fromJson(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return PersonalCalibration(
        offsetC: (j['offsetC'] as num).toDouble(),
        responses: j['responses'] as int);
  }
}

/// Unit checks, run from main() in debug builds.
bool calibrationSelfTest() {
  final p = UserProfile(
      userId: 'T', ageYears: 30, heightCm: 170, weightKg: 70, restingHrBpm: 60);
  final c = PersonalCalibration();

  // Inert before activation.
  var a = c.assess(
      compensatedAmbientC: 34, humidityPct: 70, hrBpm: 90, profile: p);
  if (a.finalBand != a.ruleBand) return false;

  // Force a large permissive offset, then verify the floor holds at Danger:
  final evil = PersonalCalibration(offsetC: -3.0, responses: 10);
  final hot = evil.assess(
      compensatedAmbientC: 39, humidityPct: 75, hrBpm: 95, profile: p);
  if (hot.ruleBand >= kDangerBand && hot.finalBand < hot.ruleBand) return false;

  // Protective learning raises the offset; clamp holds.
  final learn = PersonalCalibration();
  for (var i = 0; i < 20; i++) {
    learn.learn(hadSymptoms: true, bandAtSurvey: 1);
  }
  if (learn.offsetC > PersonalCalibration.maxProtectiveC + 1e-9) return false;
  if (!learn.active) return false;
  return true;
}
