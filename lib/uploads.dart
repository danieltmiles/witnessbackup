import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:witnessbackup/background_upload_service.dart';
import 'package:witnessbackup/cloud_storage_provider.dart';

/// Schedules a background upload task for the given file
/// This function can be called from any context and is designed to be testable
Future<void> scheduleBackgroundUpload({
  required String destinationPath,
  required String filename,
  required GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey,
}) async {
  // Schedule background upload using the persistent background service
  final prefs = await SharedPreferences.getInstance();
  final cloudStorageId = prefs.getString('cloud_storage') ?? 'none';

  if (cloudStorageId != 'none') {
    // Generate unique task ID
    final taskId = 'upload_${DateTime.now().millisecondsSinceEpoch}';

    // Schedule the upload (persists across app restarts)
    await BackgroundUploadService.scheduleUpload(
      taskId: taskId,
      filePath: destinationPath,
      fileName: filename,
      cloudStorageId: cloudStorageId,
    );

    scaffoldMessengerKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text('Upload scheduled - will continue even if app is closed'),
        duration: Duration(seconds: 3),
        backgroundColor: Colors.blue,
      ),
    );
  }
}
