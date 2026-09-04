/// App-wide state: user profile, calibration, mode gate (consumer vs
/// research collector), SpO2 desaturation tracking, survey escalation, and
/// the SOS pipeline (background SMS with vitals + geolocation + alarm).
library app_state;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'feature_window.dart';
import 'forest_model.dart';
import 'personal_calibration.dart';
import 'protocol.dart';
import 'risk_rules.dart';
import 'sos_service.dart';

/// Thermal coupling coefficient k for the compensation algorithm.
/// PLACEHOLDER VALUE 0.0 disables compensation until Ria's bench test
/// produces the measured constant — then set it HERE and only here.
const double kThermalCoupling = 0.0;

const double kSpo2DesatThreshold = 94.0;
const int kSpo2DesatSustainS = 60;

/// Non-response window before SOS fires: 2 minutes, per the design spec.
const int kSurveyTimeoutS = 120;

class AppState extends ChangeNotifier {
  UserProfile? profile;
  PersonalCalibration calibration = PersonalCalibration();
  bool collectorUnlocked = false; // secret mode gate — see settings_screen
  bool protocolOk = false;

  TelemetryFrame? latest;
  RiskAssessment? assessment;

  // --- ML layer: rolling features + on-device forest forecast ---
  final FeatureWindow featureWindow = FeatureWindow();
  ForestModel? forest; // null until an asset is trained and bundled
  ForestPrediction? forecast; // null during warm-up or with no model

  DateTime? _desatSince;
  bool surveyPending = false;
  int _lastSurveyBand = 0;
  Timer? _surveyTimer;

  // --- SOS state, surfaced on the dashboard ---
  bool alarmActive = false;
  String sosStatus = ''; // e.g. "SOS SMS sent 14:32" / failure reason
  String lastSosPath = ''; // 'direct' | 'composer' — for the Intervention Log

  Future<void> load() async {
    protocolOk = runSelfTest();
    // Absent model asset is a supported state: the app runs on the rule
    // engine alone until Chapter IV's model is trained and bundled.
    forest = await ForestModel.loadAsset();
    final sp = await SharedPreferences.getInstance();
    final pj = sp.getString('profile');
    if (pj != null) profile = UserProfile.fromJson(jsonDecode(pj));
    final cj = sp.getString('calibration');
    if (cj != null) calibration = PersonalCalibration.fromJson(cj);
    collectorUnlocked = sp.getBool('collectorUnlocked') ?? false;
    notifyListeners();
  }

  Future<void> saveProfile(UserProfile p) async {
    profile = p;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('profile', jsonEncode(p.toJson()));
    notifyListeners();
  }

  Future<void> unlockCollector() async {
    collectorUnlocked = true;
    (await SharedPreferences.getInstance()).setBool('collectorUnlocked', true);
    notifyListeners();
  }

  /// Ask for location up front (onboarding/dashboard), NOT at the moment of
  /// emergency — a permission dialog during an SOS defeats the feature.
  /// SEND_SMS's runtime prompt is wired at onboarding via permission_handler
  /// (README checklist item ②, Jaden).
  Future<void> ensureSosPermissions() async {
    var loc = await Geolocator.checkPermission();
    if (loc == LocationPermission.denied) {
      loc = await Geolocator.requestPermission();
    }
  }

  /// Consumer-mode ingestion: assess risk, drive surveys and SOS.
  /// Collector mode does NOT call this — it logs raw frames only and shows
  /// no risk output (research protocol requirement).
  void onFrame(TelemetryFrame f) {
    latest = f;
    final p = profile;
    if (p == null) {
      notifyListeners();
      return;
    }

    // Sustained SpO2 desaturation (single dips are motion artefacts).
    if (!f.spo2Pct.isNaN && f.spo2Pct < kSpo2DesatThreshold) {
      _desatSince ??= f.receivedAt;
    } else {
      _desatSince = null;
    }
    final desat = _desatSince != null &&
        f.receivedAt.difference(_desatSince!).inSeconds >= kSpo2DesatSustainS;

    final ambient = f.compensatedAmbientC(kThermalCoupling);

    // ---- STAGE 1: rule engine — what the risk IS, right now ----
    assessment = calibration.assess(
      compensatedAmbientC: ambient,
      humidityPct: f.humidityPct,
      hrBpm: f.hrBpm,
      profile: p,
      spo2Desat: desat,
    );

    // ---- STAGE 2: forest — what the risk WILL BE in ~20 minutes ----
    featureWindow.add(
      at: f.receivedAt,
      compensatedAmbientC: ambient,
      humidityPct: f.humidityPct,
      hrBpm: f.hrBpm,
      spo2Pct: f.spo2Pct,
    );
    final model = forest;
    if (model != null && featureWindow.ready) {
      forecast = model.predict(featureWindow.features(
        ageYears: p.ageYears,
        bmi: p.bmi,
        cardiovascular: p.cardiovascularCondition,
        heatIndexC: assessment!.heatIndexC,
        psi: assessment!.psi,
      ));
    }

    // ---- STAGE 3: escalate on whichever is worse ----
    // The forecast is the product: it can warn BEFORE the rule fires. The
    // rule is the floor: it can never be talked down by a model prediction.
    // Taking the max preserves both properties.
    if (effectiveBand >= kDangerBand && !surveyPending) {
      _triggerSurvey(assessment!.ruleBand);
    }
    notifyListeners();
  }

  /// The band the interface and the alerting logic act on: the worse of the
  /// present rule assessment and the model's 20-minute forecast.
  int get effectiveBand {
    final now = assessment?.finalBand ?? -1;
    final soon = forecast?.band ?? -1;
    return now > soon ? now : soon;
  }

  /// True when the alert is being driven by the forecast rather than by
  /// present conditions — the case the whole project exists to create. The UI
  /// says "expected within ~20 min" so the warning is not mistaken for a
  /// description of the present moment.
  bool get alertIsForecast =>
      forecast != null && forecast!.band > (assessment?.finalBand ?? -1);

  void _triggerSurvey(int band) {
    surveyPending = true;
    _lastSurveyBand = band;
    _surveyTimer?.cancel();
    // The 2-minute non-response window. If the user cannot or does not
    // answer, we assume the worst and escalate automatically.
    _surveyTimer = Timer(const Duration(seconds: kSurveyTimeoutS), () {
      if (surveyPending) dispatchSos(reason: 'no response to wellness check');
    });
    notifyListeners();
  }

  Future<void> answerSurvey({required bool hadSymptoms}) async {
    surveyPending = false;
    _surveyTimer?.cancel();
    calibration.learn(hadSymptoms: hadSymptoms, bandAtSurvey: _lastSurveyBand);
    final sp = await SharedPreferences.getInstance();
    await sp.setString('calibration', calibration.toJson());
    if (hadSymptoms) {
      await dispatchSos(reason: 'reported heat symptoms'); // symptomatic → escalate
    } else if (alarmActive) {
      stopAlarm(); // "I'm fine" also silences a ringing alarm
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ SOS --

  /// Full SOS pipeline — delegates to SosService (core/sos_service.dart):
  /// alarm first (local, cannot fail on permissions), then GPS with a hard
  /// time budget, then the vitals SMS sent DIRECTLY via the native
  /// SmsManager channel (an unresponsive user cannot tap Send), degrading
  /// to a prefilled composer if the native handler is absent. The message
  /// carries: heart rate, SpO2, skin temp, compensated ambient temp,
  /// humidity, heat index, risk band, and a Google Maps link.
  Future<void> dispatchSos({String reason = 'manual trigger'}) async {
    surveyPending = false;
    _surveyTimer?.cancel();
    final p = profile;
    if (p == null || p.emergencyContactPhone.isEmpty) {
      sosStatus = 'SOS NOT SENT — no emergency contact on profile';
      notifyListeners();
      return;
    }

    alarmActive = true; // SosService.dispatch starts the ringtone itself
    notifyListeners();

    // Vitals snapshot from the latest frame + assessment. NaN -> '--',
    // never a fake zero.
    final f = latest;
    final a = assessment;
    String v(double? x, String unit, [int dp = 0]) =>
        (x == null || x.isNaN) ? '--' : '${x.toStringAsFixed(dp)}$unit';
    final body = 'THERMOSTAT SOS: ${p.userId} may be suffering HEAT ILLNESS '
        '($reason). '
        'Risk: ${a?.name.toUpperCase() ?? 'DANGER'}. '
        'HR ${v(f?.hrBpm, ' bpm')}, '
        'SpO2 ${v(f?.spo2Pct, '%')}, '
        'skin ${v(f?.skinC, 'C', 1)}, '
        'ambient ${v(f?.compensatedAmbientC(kThermalCoupling), 'C', 1)}, '
        'humidity ${v(f?.humidityPct, '%')}, '
        'heat index ${v(a?.heatIndexC, 'C', 1)}. '
        'Please call them now; if no answer, call emergency services.';

    lastSosPath = await SosService.dispatch(p.emergencyContactPhone, body);

    final now = DateTime.now();
    final hhmm = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final who = p.emergencyContactName.isEmpty
        ? p.emergencyContactPhone
        : p.emergencyContactName;
    sosStatus = lastSosPath == 'direct'
        ? 'SOS SMS sent to $who at $hhmm'
        : 'Direct SMS unavailable — composer opened for $who at $hhmm '
            '(install MainActivity.kt, README §4)';
    notifyListeners();
  }

  /// "I'm OK" — stops the alarm. Deliberately does NOT retract the SMS:
  /// the contact was already told, and a false alarm resolved by a phone
  /// call is vastly cheaper than a real emergency missed.
  void stopAlarm() {
    alarmActive = false;
    SosService.stopAlarm();
    notifyListeners();
  }
}
