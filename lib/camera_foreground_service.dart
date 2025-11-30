import 'dart:io';
import 'package:flutter/services.dart';

class CameraForegroundService {
  static const MethodChannel _channel = MethodChannel('org.doodledome.witnessbackup/camera_service');
  
  /// Starts the foreground service to keep camera active during background recording
  /// Only applicable on Android. iOS uses audio background mode instead.
  static Future<bool> startService() async {
    if (!Platform.isAndroid) {
      // iOS doesn't need a foreground service, it uses audio background mode
      return true;
    }
    
    try {
      final result = await _channel.invokeMethod('startForegroundService');
      print('Foreground service started: $result');
      return result == true;
    } on PlatformException catch (e) {
      print('Failed to start foreground service: ${e.message}');
      return false;
    }
  }
  
  /// Stops the foreground service
  /// Only applicable on Android
  static Future<bool> stopService() async {
    if (!Platform.isAndroid) {
      // iOS doesn't need a foreground service
      return true;
    }
    
    try {
      final result = await _channel.invokeMethod('stopForegroundService');
      print('Foreground service stopped: $result');
      return result == true;
    } on PlatformException catch (e) {
      print('Failed to stop foreground service: ${e.message}');
      return false;
    }
  }
}
