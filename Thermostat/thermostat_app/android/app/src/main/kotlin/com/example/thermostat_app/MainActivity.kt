package com.example.thermostat_app

import android.telephony.SmsManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.thermostat/sms"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "sendSms") {
                val phone = call.argument<String>("phone")
                val msg = call.argument<String>("msg")
                
                if (phone != null && msg != null) {
                    try {
                        // Reaches directly into the Android OS to send the text silently
                        val smsManager: SmsManager = SmsManager.getDefault()
                        smsManager.sendTextMessage(phone, null, msg, null, null)
                        result.success("SMS Sent Successfully")
                    } catch (e: Exception) {
                        result.error("SMS_FAILED", e.message, null)
                    }
                } else {
                    result.error("INVALID_ARGS", "Phone or message is null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}