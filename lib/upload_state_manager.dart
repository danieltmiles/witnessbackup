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
    );
  }
}

/// Manages the state of upload tasks, persisting them to SharedPreferences
class UploadStateManager {
  static const String _uploadQueueKey = 'upload_queue';
  static const int maxRetries = 3;

  /// Adds a new upload task to the queue
  static Future<void> addTask(UploadTask task) async {
    final prefs = await SharedPreferences.getInstance();
    final tasks = await getAllTasks();
    tasks.add(task);
    await _saveTasks(tasks);
    print('Added upload task: ${task.fileName} (${task.id})');
  }

  /// Gets all upload tasks
  static Future<List<UploadTask>> getAllTasks() async {
    final prefs = await SharedPreferences.getInstance();
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
      print('Updated upload task: ${updatedTask.fileName} - ${updatedTask.status}');
    }
  }

  /// Marks a task as completed and removes it from the queue
  static Future<void> completeTask(String taskId) async {
    final tasks = await getAllTasks();
    final index = tasks.indexWhere((task) => task.id == taskId);
    if (index != -1) {
      tasks[index].status = 'completed';
      print('Completed upload task: ${tasks[index].fileName}');
      // Remove completed tasks after a delay to allow for status display
      tasks.removeAt(index);
      await _saveTasks(tasks);
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
      print('Failed upload task: ${tasks[index].fileName} - Retry ${tasks[index].retryCount}/$maxRetries');
    }
  }

  /// Removes a task from the queue
  static Future<void> removeTask(String taskId) async {
    final tasks = await getAllTasks();
    tasks.removeWhere((task) => task.id == taskId);
    await _saveTasks(tasks);
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
