import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_storage_provider.dart';
import 'background_upload_service.dart';
import 'witness_backup_app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize background upload service (works on both Android and iOS)
  await BackgroundUploadService.initialize();

  // Attempt to restore cloud storage authentication on app startup
  await _restoreCloudStorageAuth();

  // Check and request permissions
  final permissionsGranted = await _checkAndRequestPermissions();

  if (permissionsGranted) {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      runApp(const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('No cameras found'),
          ),
        ),
      ));
    }
    runApp(WitnessBackupApp(cameras: cameras));
  } else {
    runApp(const PermissionDeniedApp());
  }
}

/// Checks permission status and requests permissions if needed
Future<bool> _checkAndRequestPermissions() async {
  print('Checking permission status...');
  
  // Check current permission status
  final cameraStatus = await Permission.camera.status;
  final microphoneStatus = await Permission.microphone.status;
  
  print('Camera status: $cameraStatus');
  print('Microphone status: $microphoneStatus');

  // If both are already granted, we're good
  if (cameraStatus.isGranted && microphoneStatus.isGranted) {
    print('Both permissions already granted');
    return true;
  }

  // Always try to request permissions on first run (this triggers iOS to show the system dialog)
  print('Requesting camera permission...');
  final cameraResult = await Permission.camera.request();
  print('Camera result: $cameraResult');
  
  print('Requesting microphone permission...');
  final microphoneResult = await Permission.microphone.request();
  print('Microphone result: $microphoneResult');
  
  final bothGranted = cameraResult.isGranted && microphoneResult.isGranted;
  print('Both permissions granted: $bothGranted');
  
  return bothGranted;
}

/// App widget shown when permissions are denied
class PermissionDeniedApp extends StatelessWidget {
  const PermissionDeniedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Permissions Required'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.camera_alt_outlined,
                size: 80,
                color: Colors.grey,
              ),
              const SizedBox(height: 24),
              const Text(
                'Camera and Microphone Access Required',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'This app needs access to your camera and microphone to record videos.',
                style: TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: () async {
                  print('Grant Permissions button pressed');
                  
                  if (Platform.isIOS) {
                    // On iOS, always open Settings since iOS won't show permission dialog again after denial
                    print('Opening iOS Settings...');
                    final opened = await openAppSettings();
                    print('Settings opened: $opened');
                    
                    // Show a dialog explaining what to do
                    if (context.mounted) {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Enable Permissions'),
                          content: const Text(
                            '1. Find "WitnessBackup" in the Settings list\n'
                            '2. Tap on Camera and enable it\n'
                            '3. Tap on Microphone and enable it\n'
                            '4. Return to this app',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('OK'),
                            ),
                          ],
                        ),
                      );
                    }
                  } else {
                    // On Android, check if permanently denied
                    final cameraStatus = await Permission.camera.status;
                    final microphoneStatus = await Permission.microphone.status;
                    
                    if (cameraStatus.isPermanentlyDenied || microphoneStatus.isPermanentlyDenied) {
                      // Open app settings
                      await openAppSettings();
                    } else {
                      // Try requesting again
                      final cameraResult = await Permission.camera.request();
                      final microphoneResult = await Permission.microphone.request();
                      
                      if (cameraResult.isGranted && microphoneResult.isGranted) {
                        // Permissions granted, restart the app
                        // ignore: use_build_context_synchronously
                        if (context.mounted) {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (context) => FutureBuilder<List<CameraDescription>>(
                                future: availableCameras(),
                                builder: (context, snapshot) {
                                  if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                                    return WitnessBackupApp(cameras: snapshot.data!);
                                  } else {
                                    return const Scaffold(
                                      body: Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ),
                          );
                        }
                      }
                    }
                  }
                },
                icon: const Icon(Icons.settings),
                label: const Text('Open Settings'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                Platform.isIOS 
                  ? 'Tap "Open Settings" to configure permissions in iOS Settings. After enabling permissions, return to this app.'
                  : 'Tap "Open Settings" to enable access.',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Attempts to restore cloud storage authentication on app startup
Future<void> _restoreCloudStorageAuth() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final cloudStorageId = prefs.getString('cloud_storage') ?? 'none';
    
    if (cloudStorageId != 'none') {
      print('Restoring cloud storage authentication for: $cloudStorageId');
      final provider = CloudStorageFactory.create(cloudStorageId);
      
      if (provider != null) {
        // Attempt to restore the authentication session
        final isAuthenticated = await provider.isAuthenticated();
        if (isAuthenticated) {
          print('Successfully restored ${provider.displayName} authentication');
        } else {
          print('Could not restore ${provider.displayName} authentication');
        }
      }
    }
  } catch (e) {
    print('Error restoring cloud storage authentication: $e');
  }
}