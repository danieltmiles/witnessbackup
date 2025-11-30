package org.doodledome.witnessbackup

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "org.doodledome.witnessbackup/camera_service"
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    try {
                        CameraForegroundService.startService(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", "Failed to start foreground service: ${e.message}", null)
                    }
                }
                "stopForegroundService" -> {
                    try {
                        CameraForegroundService.stopService(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", "Failed to stop foreground service: ${e.message}", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
