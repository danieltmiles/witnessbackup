import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Represents the state of a video upload
class UploadTask {
  final String id;
  final String filePath;
  final String fileName;
  final String cloudStorageId;
  final DateTime createdAt;
  int retryCount;
  String status; // 'pending', 'uploading', 'completed', 'failed'
  String? errorMessage;
  int? uploadedBytes;
  int? totalBytes;
  String? resumableSessionUri; // For resumable uploads (e.g., Google Drive session URI)

  UploadTask({
    required this.id,
    required this.filePath,
    required this.fileName,
    required this.cloudStorageId,
    required this.createdAt,
    this.retryCount = 0,
    this.status = 'pending',
    this.errorMessage,
    this.uploadedBytes,
    this.totalBytes,
    this.resumableSessionUri,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'filePath': filePath,
      'fileName': fileName,
      'cloudStorageId': cloudStorageId,
      'createdAt': createdAt.toIso8601String(),
      'retryCount': retryCount,
      'status': status,
      'errorMessage': errorMessage,
      'uploadedBytes': uploadedBytes,
      'totalBytes': totalBytes,
      'resumableSessionUri': resumableSessionUri,
    };
  }

  factory UploadTask.fromJson(Map<String, dynamic> json) {
    return UploadTask(
      id: json['id'],
      filePath: json['filePath'],
      fileName: json['fileName'],
      cloudStorageId: json['cloudStorageId'],
      createdAt: DateTime.parse(json['createdAt']),
      retryCount: json['retryCount'] ?? 0,
      status: json['status'] ?? 'pending',
      errorMessage: json['errorMessage'],
      uploadedBytes: json['uploadedBytes'],
      totalBytes: json['totalBytes'],
      resumableSessionUri: json['resumableSessionUri'],
    );
  }
}

/// Manages the state of upload tasks, persisting them to SharedPreferences
class UploadStateManager {
  static const String _uploadQueueKey = 'upload_queue';
  static const int maxRetries = 3;
  
  // Stream controller for broadcasting upload progress updates
  static final StreamController<List<UploadTask>> _progressController = 
      StreamController<List<UploadTask>>.broadcast();
  
  /// Stream of upload tasks for UI updates
  static Stream<List<UploadTask>> get progressStream => _progressController.stream;
  
  /// Broadcasts the current state of all tasks
  static Future<void> _broadcastProgress() async {
    final tasks = await getAllTasks();
    print('[UploadStateManager] Broadcasting ${tasks.length} tasks to UI stream');
    for (final task in tasks) {
      print('[UploadStateManager] Task: ${task.fileName}, status: ${task.status}, uploaded: ${task.uploadedBytes}/${task.totalBytes}');
    }
    _progressController.add(tasks);
  }
  
  /// Public method to refresh and broadcast current tasks
  /// Call this when the UI needs to load existing tasks
  static Future<void> refreshTasks() async {
    await _broadcastProgress();
  }

  /// Adds a new upload task to the queue
  static Future<void> addTask(UploadTask task) async {
    final prefs = await SharedPreferences.getInstance();
    final tasks = await getAllTasks();
    tasks.add(task);
    await _saveTasks(tasks);
    await _broadcastProgress();
    print('Added upload task: ${task.fileName} (${task.id})');
  }

  /// Gets all upload tasks
  static Future<List<UploadTask>> getAllTasks() async {
    final prefs = await SharedPreferences.getInstance();
    // Force reload from disk to get updates from background isolate
    await prefs.reload();
    final jsonString = prefs.getString(_uploadQueueKey);
    if (jsonString == null) return [];

    try {
      final List<dynamic> jsonList = json.decode(jsonString);
      return jsonList.map((json) => UploadTask.fromJson(json)).toList();
    } catch (e) {
      print('Error loading upload tasks: $e');
      return [];
    }
  }

  /// Gets pending upload tasks (not completed)
  static Future<List<UploadTask>> getPendingTasks() async {
    final tasks = await getAllTasks();
    return tasks.where((task) => 
      task.status != 'completed' && task.retryCount < maxRetries
    ).toList();
  }

  /// Updates an existing task
  static Future<void> updateTask(UploadTask updatedTask) async {
    final tasks = await getAllTasks();
    final index = tasks.indexWhere((task) => task.id == updatedTask.id);
    if (index != -1) {
      tasks[index] = updatedTask;
      await _saveTasks(tasks);
      await _broadcastProgress();
      print('Updated upload task: ${updatedTask.fileName} - ${updatedTask.status}');
    }
  }

  /// Updates progress for a specific task
  static Future<void> updateProgress(String taskId, int uploadedBytes, int totalBytes, {String? sessionUri}) async {
    print('[UploadStateManager.updateProgress] Called with taskId=$taskId, uploaded=$uploadedBytes, total=$totalBytes');
    final tasks = await getAllTasks();
    final index = tasks.indexWhere((task) => task.id == taskId);
    if (index != -1) {
      tasks[index].uploadedBytes = uploadedBytes;
      tasks[index].totalBytes = totalBytes;
      tasks[index].status = 'uploading'; // Ensure status is set to uploading
      if (sessionUri != null) {
        tasks[index].resumableSessionUri = sessionUri;
      }
      await _saveTasks(tasks);
      await _broadcastProgress();
      final percentComplete = (uploadedBytes * 100 / totalBytes).toStringAsFixed(1);
      print('[UploadStateManager.updateProgress] Updated ${tasks[index].fileName}: $percentComplete% ($uploadedBytes/$totalBytes bytes)');
    } else {
      print('[UploadStateManager.updateProgress] ERROR: Task not found with id=$taskId');
    }
  }

  /// Marks a task as completed and removes it from the queue
  static Future<void> completeTask(String taskId) async {
    final tasks = await getAllTasks();
    final index = tasks.indexWhere((task) => task.id == taskId);
    if (index != -1) {
      tasks[index].status = 'completed';
      print('Completed upload task: ${tasks[index].fileName}');
      await _saveTasks(tasks);
      await _broadcastProgress();
      // Remove completed tasks after a delay to allow for status display
      await Future.delayed(const Duration(seconds: 2));
      tasks.removeAt(index);
      await _saveTasks(tasks);
      await _broadcastProgress();
    }
  }

  /// Marks a task as failed
  static Future<void> failTask(String taskId, String errorMessage) async {
    final tasks = await getAllTasks();
    final index = tasks.indexWhere((task) => task.id == taskId);
    if (index != -1) {
      tasks[index].status = 'failed';
      tasks[index].errorMessage = errorMessage;
      tasks[index].retryCount++;
      await _saveTasks(tasks);
      await _broadcastProgress();
      print('Failed upload task: ${tasks[index].fileName} - Retry ${tasks[index].retryCount}/$maxRetries');
    }
  }

  /// Removes a task from the queue
  static Future<void> removeTask(String taskId) async {
    final tasks = await getAllTasks();
    tasks.removeWhere((task) => task.id == taskId);
    await _saveTasks(tasks);
    await _broadcastProgress();
  }

  /// Clears all completed and failed tasks
  static Future<void> clearCompletedTasks() async {
    final tasks = await getAllTasks();
    final pendingTasks = tasks.where((task) => 
      task.status != 'completed' && 
      (task.status != 'failed' || task.retryCount < maxRetries)
    ).toList();
    await _saveTasks(pendingTasks);
  }

  /// Saves tasks to SharedPreferences
  static Future<void> _saveTasks(List<UploadTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = json.encode(tasks.map((task) => task.toJson()).toList());
    await prefs.setString(_uploadQueueKey, jsonString);
  }

  /// Checks if there are any pending uploads
  static Future<bool> hasPendingUploads() async {
    final pending = await getPendingTasks();
    return pending.isNotEmpty;
  }
}
