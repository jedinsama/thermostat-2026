/// SOS delivery chain: alarm + geolocation + vitals SMS.
///
/// Escalation contract (called from app_state.dart when the wellness survey
/// times out after 120 s, or symptoms are reported at Danger):
///   1. ALARM starts immediately — loud, looping, at alarm volume — both to
///      rouse the user and to help a nearby person or the emergency contact
///      locate them. It keeps ringing until "I'm OK" is tapped.
///   2. GPS fix is attempted (10 s budget; last-known fix as fallback).
///   3. The SMS — vitals + location link — is sent DIRECTLY via a platform
///      channel to Android's SmsManager (no user tap needed; an unconscious
///      user cannot tap Send). If the native channel is unavailable (e.g.
///      MainActivity.kt not installed yet), it falls back to opening the SMS
///      composer prefilled — degraded but never silent.
///
/// Requires (see README §4): SEND_SMS + ACCESS_FINE_LOCATION permissions,
/// and the MainActivity.kt method-channel handler. Google Play policy
/// restricts SEND_SMS for store distribution; the capstone APK is sideloaded,
/// where it is permitted with the runtime grant.
library sos_service;

import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

class SosService {
  static const MethodChannel _sms = MethodChannel('thermostat/sms');

  // ---- alarm ------------------------------------------------------------
  static Future<void> playAlarm() async {
    await FlutterRingtonePlayer().playAlarm(looping: true, asAlarm: true, volume: 1.0);
  }

  static Future<void> stopAlarm() async {
    await FlutterRingtonePlayer().stop();
  }

  // ---- geolocation ------------------------------------------------------
  /// Returns a Google Maps link, or null if no fix is obtainable. Tries a
  /// fresh fix for up to 10 s, then falls back to the last known position —
  /// a minutes-old fix is far better than none in an emergency.
  static Future<String?> mapsLink() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 10)),
        );
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
      }
      if (pos == null) return null;
      return 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
    } catch (_) {
      return null;
    }
  }

  // ---- SMS --------------------------------------------------------------
  /// Direct send via SmsManager (multipart — vitals messages exceed 160
  /// chars). Returns true only if the native layer reports success.
  static Future<bool> sendDirect(String phone, String body) async {
    try {
      final ok =
          await _sms.invokeMethod<bool>('sendSms', {'phone': phone, 'body': body});
      return ok ?? false;
    } on MissingPluginException {
      return false; // MainActivity.kt handler not installed yet
    } on PlatformException {
      return false; // permission denied / no telephony
    }
  }

  /// Fallback: open the SMS composer prefilled. Requires a tap, so it is the
  /// degraded path — but a visible composer plus a ringing alarm still beats
  /// silence.
  static Future<void> composeFallback(String phone, String body) async {
    final uri = Uri.parse('sms:$phone?body=${Uri.encodeComponent(body)}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  /// The full chain. Returns 'direct', 'composer', or 'failed' so the caller
  /// can log which path fired (Intervention Log / Chapter IV).
  static Future<String> dispatch(String phone, String body) async {
    await playAlarm();
    final link = await mapsLink();
    final full = link == null ? '$body Location: unavailable.' : '$body Location: $link';
    if (await sendDirect(phone, full)) return 'direct';
    await composeFallback(phone, full);
    return 'composer';
  }
}
