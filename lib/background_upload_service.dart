import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'upload_state_manager.dart';
import 'cloud_storage_provider.dart';

/// Background upload service that handles uploads even when app is closed
class BackgroundUploadService {
  static const String uploadTaskName = 'videoUploadTask';
  static const String uploadTaskTag = 'video_upload';

  /// Initializes the background upload service
  static Future<void> initialize() async {
    // Initialize WorkManager for both Android and iOS
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: kDebugMode,
    );
    print('WorkManager initialized for ${Platform.isAndroid ? 'Android' : 'iOS'}');
    
    // Check for any pending uploads from previous sessions
    await _checkAndSchedulePendingUploads();
  }

  /// Schedules a new upload task
  static Future<void> scheduleUpload({
    required String taskId,
    required String filePath,
    required String fileName,
    required String cloudStorageId,
  }) async {
    // Add task to persistent queue
    final task = UploadTask(
      id: taskId,
      filePath: filePath,
      fileName: fileName,
      cloudStorageId: cloudStorageId,
      createdAt: DateTime.now(),
    );
    
    await UploadStateManager.addTask(task);
    
    // Schedule background work
    if (Platform.isAndroid) {
      await Workmanager().registerOneOffTask(
        taskId,
        uploadTaskName,
        tag: uploadTaskTag,
        inputData: {
          'taskId': taskId,
        },
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(seconds: 30),
      );
      print('Scheduled WorkManager task for: $fileName');
    } else {
      // For iOS, we'll use the immediate upload approach with background URLSession
      // which is already configured in the cloud storage providers
      await _processUploadTask(taskId);
    }
  }

  /// Checks for pending uploads and schedules them
  static Future<void> _checkAndSchedulePendingUploads() async {
    final pendingTasks = await UploadStateManager.getPendingTasks();
    
    if (pendingTasks.isEmpty) {
      print('No pending uploads found');
      return;
    }
    
    print('Found ${pendingTasks.length} pending uploads');
    
    for (final task in pendingTasks) {
      if (Platform.isAndroid) {
        // Re-schedule the task
        await Workmanager().registerOneOffTask(
          task.id,
          uploadTaskName,
          tag: uploadTaskTag,
          inputData: {
            'taskId': task.id,
          },
          constraints: Constraints(
            networkType: NetworkType.connected,
          ),
          backoffPolicy: BackoffPolicy.exponential,
          backoffPolicyDelay: const Duration(seconds: 30),
        );
      } else {
        // For iOS, process immediately
        await _processUploadTask(task.id);
      }
    }
  }

  /// Processes a single upload task
  static Future<bool> _processUploadTask(String taskId) async {
    print('Processing upload task: $taskId');
    
    try {
      // Get the task details
      final tasks = await UploadStateManager.getAllTasks();
      final task = tasks.firstWhere(
        (t) => t.id == taskId,
        orElse: () => throw Exception('Task not found: $taskId'),
      );
      
      // Check if file still exists
      final file = File(task.filePath);
      if (!await file.exists()) {
        print('File no longer exists: ${task.filePath}');
        await UploadStateManager.removeTask(taskId);
        return false;
      }
      
      // Update task status to uploading
      task.status = 'uploading';
      await UploadStateManager.updateTask(task);
      
      // Get cloud storage provider
      final provider = CloudStorageFactory.create(task.cloudStorageId);
      if (provider == null) {
        throw Exception('Provider not found: ${task.cloudStorageId}');
      }
      
      // Check authentication
      final isAuthenticated = await provider.isAuthenticated();
      if (!isAuthenticated) {
        throw Exception('Provider not authenticated: ${task.cloudStorageId}');
      }
      
      // Perform the upload with progress tracking and resume support
      print('Starting upload to ${provider.displayName}: ${task.fileName}');
      if (task.uploadedBytes != null && task.uploadedBytes! > 0) {
        print('Resuming from byte ${task.uploadedBytes} of ${task.totalBytes}');
      }
      
      final success = await provider.uploadFile(
        task.filePath, 
        task.fileName,
        taskId: taskId,
        existingSessionUri: task.resumableSessionUri,
        startByte: task.uploadedBytes,
        onProgress: (uploaded, total, sessionUri) async {
          // Save progress to persistent storage
          await UploadStateManager.updateProgress(
            taskId, 
            uploaded, 
            total,
            sessionUri: sessionUri,
          );
        },
      );
      
      if (success) {
        print('Upload successful: ${task.fileName}');
        await UploadStateManager.completeTask(taskId);
        return true;
      } else {
        throw Exception('Upload failed');
      }
    } catch (e, stackTrace) {
      print('Error processing upload task: $e');
      print('Stack trace: $stackTrace');
      
      await UploadStateManager.failTask(taskId, e.toString());
      
      // Check if we should retry
      final tasks = await UploadStateManager.getAllTasks();
      final task = tasks.firstWhere(
        (t) => t.id == taskId,
        orElse: () => throw Exception('Task not found after failure'),
      );
      
      if (task.retryCount < UploadStateManager.maxRetries) {
        print('Will retry upload (attempt ${task.retryCount + 1}/${UploadStateManager.maxRetries})');
        // WorkManager will automatically retry with exponential backoff
      } else {
        print('Max retries reached for task: $taskId');
      }
      
      return false;
    }
  }

  /// Cancels a scheduled upload
  static Future<void> cancelUpload(String taskId) async {
    if (Platform.isAndroid) {
      await Workmanager().cancelByUniqueName(taskId);
    }
    await UploadStateManager.removeTask(taskId);
    print('Cancelled upload task: $taskId');
  }

  /// Cancels all scheduled uploads
  static Future<void> cancelAllUploads() async {
    if (Platform.isAndroid) {
      await Workmanager().cancelByTag(uploadTaskTag);
    }
    final tasks = await UploadStateManager.getAllTasks();
    for (final task in tasks) {
      await UploadStateManager.removeTask(task.id);
    }
    print('Cancelled all upload tasks');
  }
}

/// WorkManager callback dispatcher for Android background tasks
/// This runs in a separate isolate
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print('Background task started: $task');
    
    try {
      switch (task) {
        case BackgroundUploadService.uploadTaskName:
          // Get the task ID from the unique name
          final taskId = inputData?['taskId'] as String?;
          if (taskId == null) {
            // Try to process any pending tasks
            final pendingTasks = await UploadStateManager.getPendingTasks();
            if (pendingTasks.isEmpty) {
              print('No pending tasks to process');
              return Future.value(true);
            }
            
            // Process the first pending task
            final task = pendingTasks.first;
            final success = await BackgroundUploadService._processUploadTask(task.id);
            return Future.value(success);
          } else {
            final success = await BackgroundUploadService._processUploadTask(taskId);
            return Future.value(success);
          }
        default:
          print('Unknown task type: $task');
          return Future.value(false);
      }
    } catch (e, stackTrace) {
      print('Error in background task: $e');
      print('Stack trace: $stackTrace');
      return Future.value(false);
    }
  });
}
