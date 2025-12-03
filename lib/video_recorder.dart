import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:witnessbackup/upload_state_manager.dart';
import 'cloud_storage_provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gallery_saver_plus/gallery_saver.dart';
import 'background_upload_service.dart';
import 'settings_page.dart';
import 'camera_foreground_service.dart';

class VideoRecorder extends StatefulWidget {
  final List<CameraDescription> cameras;

  const VideoRecorder({super.key, required this.cameras});

  @override
  _VideoRecorderState createState() => _VideoRecorderState();
}

class _VideoRecorderState extends State<VideoRecorder> with WidgetsBindingObserver {
  CameraController? _controller;
  late Future<void> _initializeControllerFuture;
  bool _isRecording = false;
  ResolutionPreset _currentResolution = ResolutionPreset.medium;
  CameraDescription? _currentCamera;
  bool _isFlashlightOn = false;
  
  // Timer for polling upload progress (needed because WorkManager runs in separate isolate)
  Timer? _uploadProgressTimer;
  bool _showUploadProgress = true; // Default to true, will be overridden by settings

  // Global key for showing snackbars from background tasks
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeControllerFuture = _loadResolution();
    _loadExistingUploadTasks();
    _startUploadProgressPolling();
    _loadShowUploadProgressSetting();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Reload settings when returning from settings page
      _loadShowUploadProgressSetting();
    }
  }

  /// Loads existing upload tasks to display in progress bar
  Future<void> _loadExistingUploadTasks() async {
    // Refresh and broadcast existing tasks to the UI
    await UploadStateManager.refreshTasks();
  }

  /// Loads the setting for whether to show upload progress
  Future<void> _loadShowUploadProgressSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final showProgress = prefs.getBool('show_upload_progress') ?? true; // Default to true for backward compatibility
    setState(() {
      _showUploadProgress = showProgress;
    });
  }

  /// Gets the current show upload progress setting directly from SharedPreferences
  Future<bool> _getShowUploadProgressSetting() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('show_upload_progress') ?? true;
  }
  
  /// Starts polling for upload progress updates
  /// This is needed because WorkManager runs in a separate isolate
  /// and cannot share the StreamController with the UI
  /// Polls to ensure all state changes are broadcast, including when tasks are removed
  void _startUploadProgressPolling() {
    _uploadProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      // Always poll to ensure UI gets notified of all state changes including removals
      // Add a small delay to prevent dominating compute resources
      await Future.delayed(const Duration(milliseconds: 100));
      // Refresh tasks from SharedPreferences and broadcast to UI
      await UploadStateManager.refreshTasks();
    });
  }

  /// Uploads a file to cloud storage in the background
  /// This runs independently and won't block the UI
  Future<void> _uploadToCloudStorage(String filePath, String fileName) async {
    try {
      print('Starting background upload task for: $fileName');

      final prefs = await SharedPreferences.getInstance();
      final cloudStorageId = prefs.getString('cloud_storage') ?? 'none';

      if (cloudStorageId == 'none') {
        print('No cloud storage configured, skipping upload');
        return;
      }

      final provider = CloudStorageFactory.create(cloudStorageId);

      if (provider == null) {
        print('Failed to create provider for: $cloudStorageId');
        return;
      }

      final isAuthenticated = await provider.isAuthenticated();

      if (!isAuthenticated) {
        print('Cloud storage provider ${provider.displayName} is not authenticated');
        _scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('${provider.displayName} not authenticated. Upload skipped.'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      print('Starting upload to ${provider.displayName}...');
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Uploading to ${provider.displayName}...'),
          duration: const Duration(seconds: 2),
        ),
      );

      final uploadSuccess = await provider.uploadFile(filePath, fileName);

      print('Upload completed. Success: $uploadSuccess');

      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
              uploadSuccess
                  ? 'Successfully uploaded $fileName to ${provider.displayName}'
                  : 'Failed to upload to ${provider.displayName}'
          ),
          duration: const Duration(seconds: 3),
          backgroundColor: uploadSuccess ? Colors.green : Colors.red,
        ),
      );
    } catch (e, stackTrace) {
      print('Error in background upload task: $e');
      print('Stack trace: $stackTrace');

      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Upload error: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _loadResolution() async {
    // If no cameras available, skip initialization (for testing)
    if (widget.cameras.isEmpty) {
      return;
    }
    
    final prefs = await SharedPreferences.getInstance();
    final resolutionString = prefs.getString('video_resolution') ?? 'medium';
    setState(() {
      _currentResolution = _stringToResolution(resolutionString);
      _currentCamera = widget.cameras.first;
    });
    _controller = CameraController(
      _currentCamera!,
      _currentResolution,
    );
    await _controller!.initialize();
  }

  ResolutionPreset _stringToResolution(String value) {
    switch (value) {
      case 'low':
        return ResolutionPreset.low;
      case 'medium':
        return ResolutionPreset.medium;
      case 'high':
        return ResolutionPreset.high;
      case 'veryHigh':
        return ResolutionPreset.veryHigh;
      case 'ultraHigh':
        return ResolutionPreset.ultraHigh;
      case 'max':
        return ResolutionPreset.max;
      default:
        return ResolutionPreset.medium;
    }
  }

  String _resolutionToString(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.low:
        return 'low';
      case ResolutionPreset.medium:
        return 'medium';
      case ResolutionPreset.high:
        return 'high';
      case ResolutionPreset.veryHigh:
        return 'veryHigh';
      case ResolutionPreset.ultraHigh:
        return 'ultraHigh';
      case ResolutionPreset.max:
        return 'max';
    }
  }

  /// Handles graceful exit of the app with pending upload completion
  Future<void> _handleExit() async {
    // Check if there are any pending uploads
    final hasPendingUploads = await UploadStateManager.hasPendingUploads();
    
    if (hasPendingUploads) {
      // Show a message that the app is waiting for uploads to complete
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: const Text('Waiting for uploads to complete before exit...'),
          duration: const Duration(seconds: 5),
        ),
      );
      
      // For Android, we can't actually prevent the app from closing in this context,
      // but we can show a notification that uploads are still running
      print('App exit requested with pending uploads. Showing notification...');
      
      // In a real implementation, we would:
      // 1. Show a persistent notification that uploads are in progress
      // 2. Allow the app to close but let background tasks continue
      // 3. The system will handle cleanup of the app process once uploads complete
      
      // For now, we'll just show a message and let the system handle it
      // The actual background upload handling is already managed by WorkManager
      SystemNavigator.pop();
    } else {
      // No pending uploads, safe to exit
      SystemNavigator.pop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uploadProgressTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      return;
    }
    
    // Check if background recording is enabled in settings
    final prefs = await SharedPreferences.getInstance();
    final backgroundRecordingEnabled = prefs.getBool('background_recording_enabled') ?? false;
    
    // Start foreground service only if background recording is enabled
    if (backgroundRecordingEnabled) {
      await CameraForegroundService.startService();
    }
    
    setState(() {
      _isRecording = true;
    });
    await _controller!.startVideoRecording();
  }

  /// Toggles the flashlight on/off
  Future<void> _toggleFlashlight() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      return;
    }

    try {
      if (_isFlashlightOn) {
        await _controller!.setFlashMode(FlashMode.off);
        setState(() {
          _isFlashlightOn = false;
        });
        _scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('Flashlight OFF'),
            duration: Duration(seconds: 1),
          ),
        );
      } else {
        await _controller!.setFlashMode(FlashMode.torch);
        setState(() {
          _isFlashlightOn = true;
        });
        _scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('Flashlight ON'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      print('Error toggling flashlight: $e');
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Error toggling flashlight: $e'),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _stopRecording() async {
    if (_controller == null || !_controller!.value.isRecordingVideo) {
      return;
    }

    try {
      final xFile = await _controller!.stopVideoRecording();
      
      // Stop foreground service if it was started
      await CameraForegroundService.stopService();
      
      setState(() {
        _isRecording = false;
      });

      // Generate RFC3339 timestamp filename (with filesystem-safe characters)
      // Example: 2025-10-29T23-10-00.123456-07-00.mp4
      final timestamp = DateTime.now().toIso8601String();
      // Replace colons with hyphens to make it filesystem-safe
      final safeTimestamp = timestamp.replaceAll(':', '-');
      final filename = '$safeTimestamp.mp4';

      // Determine the destination directory based on platform
      Directory destinationDir;
      String destinationPath;

      if (Platform.isAndroid) {
        // On Android, save to external storage Movies directory
        final externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          // Navigate to /storage/emulated/0/Movies
          final moviesDirPath = externalDir.path.replaceFirst(
              RegExp(r'/Android/data/[^/]+/files'),
              '/Movies'
          );
          destinationDir = Directory(moviesDirPath);
        } else {
          // Fallback to app-specific directory if external storage not available
          destinationDir = await getApplicationDocumentsDirectory();
        }
      } else if (Platform.isIOS) {
        // On iOS, save to documents directory (accessible via Files app)
        destinationDir = await getApplicationDocumentsDirectory();
      } else {
        // Fallback for other platforms
        destinationDir = await getApplicationDocumentsDirectory();
      }

      // Create the directory if it doesn't exist
      if (!await destinationDir.exists()) {
        await destinationDir.create(recursive: true);
      }

      // Copy the file directly to the destination (single copy)
      destinationPath = '${destinationDir.path}/$filename';
      final originalFile = File(xFile.path);
      await originalFile.copy(destinationPath);

      // Clean up the temporary file
      await originalFile.delete();

      print("Video saved to $destinationPath");

      // Show snackbar using the global key
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Video saved as $filename to ${Platform.isAndroid ? 'Movies' : 'Documents'}'),
          duration: const Duration(seconds: 2),
        ),
      );

      // On Android, notify the system to scan for the new media file
      if (Platform.isAndroid) {
        unawaited(GallerySaver.saveVideo(destinationPath));
      }

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

        _scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('Upload scheduled - will continue even if app is closed'),
            duration: Duration(seconds: 3),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      // Ensure we stop the foreground service even on error
      await CameraForegroundService.stopService();
      
      setState(() {
        _isRecording = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving video: $e'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
      }

      print("Error saving video: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _scaffoldMessengerKey,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Video Recorder'),
          actions: [
            InkWell(
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => SettingsPage(
                      currentResolution: _currentResolution,
                      onResolutionChanged: (newResolution) async {
                        if (_controller == null || _currentCamera == null) return;
                        
                        // Save the new resolution
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('video_resolution', _resolutionToString(newResolution));

                        // Reinitialize camera with new resolution
                        await _controller!.dispose();
                        setState(() {
                          _currentResolution = newResolution;
                          _controller = CameraController(
                            _currentCamera!,
                            _currentResolution,
                          );
                          _initializeControllerFuture = _controller!.initialize();
                        });
                      },
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.settings),
                    const SizedBox(height: 2),
                    const Text(
                      'Settings',
                      style: TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
            if (Platform.isAndroid) 
              InkWell(
                onTap: _handleExit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.exit_to_app),
                      const SizedBox(height: 2),
                      const Text(
                        'Exit',
                        style: TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        body: FutureBuilder<void>(
          future: _initializeControllerFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done && _controller != null) {
              // Calculate the scale to fit the preview in the screen
              final size = MediaQuery.of(context).size;
              var scale = size.aspectRatio * _controller!.value.aspectRatio;

              // to prevent scaling down, invert the scale
              if (scale < 1) scale = 1 / scale;

              return Transform.scale(
                scale: scale,
                child: Center(
                  child: CameraPreview(_controller!),
                ),
              );
            } else {
              return const Center(child: CircularProgressIndicator());
            }
          },
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Upload Progress Bar
            FutureBuilder<bool>(
              future: _getShowUploadProgressSetting(),
              builder: (context, settingSnapshot) {
                return StreamBuilder<List<UploadTask>>(
                  stream: UploadStateManager.progressStream,
                  builder: (context, snapshot) {
                    // Always read current setting to ensure we have the latest value
                    final showProgress = settingSnapshot.data ?? true;
                    
                    print('[VideoRecorder.StreamBuilder] Received snapshot: hasData=${snapshot.hasData}, connectionState=${snapshot.connectionState}, showProgress=$showProgress');
                    final tasks = snapshot.data ?? [];
                    print('[VideoRecorder.StreamBuilder] Total tasks: ${tasks.length}');
                    for (final t in tasks) {
                      print('[VideoRecorder.StreamBuilder] Task: ${t.fileName}, status=${t.status}, uploaded=${t.uploadedBytes}/${t.totalBytes}');
                    }
                    final uploadingTasks = tasks.where((t) => 
                      t.status == 'uploading' || t.status == 'pending' || t.status == 'completed'
                    ).toList();
                    print('[VideoRecorder.StreamBuilder] Visible tasks: ${uploadingTasks.length}');
                    
                    // Don't show if setting is disabled or no tasks
                    if (!showProgress || uploadingTasks.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    
                    return Container(
                      color: Colors.black87,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: uploadingTasks.map((task) {
                          final progress = (task.totalBytes != null && task.totalBytes! > 0)
                              ? (task.uploadedBytes ?? 0) / task.totalBytes!
                              : 0.0;
                          final percentText = (progress * 100).toStringAsFixed(1);
                          
                          // Determine status color and icon
                          Color statusColor;
                          IconData statusIcon;
                          String statusText;
                          
                          switch (task.status) {
                            case 'completed':
                              statusColor = Colors.green;
                              statusIcon = Icons.check_circle;
                              statusText = 'Completed';
                              break;
                            case 'failed':
                              statusColor = Colors.red;
                              statusIcon = Icons.error;
                              statusText = 'Failed';
                              break;
                            case 'uploading':
                              statusColor = Colors.blue;
                              statusIcon = Icons.cloud_upload;
                              statusText = 'Uploading $percentText%';
                              break;
                            default: // pending
                              statusColor = Colors.orange;
                              statusIcon = Icons.hourglass_empty;
                              statusText = 'Pending...';
                          }
                          
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(statusIcon, color: statusColor, size: 16),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        task.fileName,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      statusText,
                                      style: TextStyle(
                                        color: statusColor,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: task.status == 'completed' ? 1.0 : progress,
                                    backgroundColor: Colors.grey[700],
                                    valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                                    minHeight: 6,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    );
                  },
                );
              },
            ),
            // Bottom Navigation Bar
            BottomAppBar(
              color: Colors.transparent,
              elevation: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: <Widget>[
                  IconButton(
                    icon: Icon(_isFlashlightOn ? Icons.flash_on : Icons.flash_off),
                    onPressed: _toggleFlashlight,
                  ),
                  FloatingActionButton(
                    onPressed: () {
                      if (_isRecording) {
                        _stopRecording();
                      } else {
                        _startRecording();
                      }
                    },
                    child: Icon(_isRecording ? Icons.stop : Icons.videocam),
                  ),
                  IconButton(
                    icon: const Icon(Icons.autorenew),
                    onPressed: () async {
                      if (_isRecording) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Cannot switch camera while recording'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                        return;
                      }

                      if (_controller == null || _currentCamera == null) return;

                      // Find the opposite camera
                      CameraDescription? targetCamera;
                      if (_currentCamera!.lensDirection == CameraLensDirection.back) {
                        targetCamera = widget.cameras.firstWhere(
                              (camera) => camera.lensDirection == CameraLensDirection.front,
                          orElse: () => _currentCamera!,
                        );
                      } else {
                        targetCamera = widget.cameras.firstWhere(
                              (camera) => camera.lensDirection == CameraLensDirection.back,
                          orElse: () => _currentCamera!,
                        );
                      }

                      if (targetCamera != _currentCamera) {
                        await _controller!.dispose();
                        setState(() {
                          _currentCamera = targetCamera!;
                          _controller = CameraController(
                            _currentCamera!,
                            _currentResolution,
                          );
                          _initializeControllerFuture = _controller!.initialize();
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
