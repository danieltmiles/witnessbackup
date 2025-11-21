import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_storage_provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gallery_saver_plus/gallery_saver.dart';
import 'background_upload_service.dart';
import 'settings_page.dart';

class VideoRecorder extends StatefulWidget {
  final List<CameraDescription> cameras;

  const VideoRecorder({super.key, required this.cameras});

  @override
  _VideoRecorderState createState() => _VideoRecorderState();
}

class _VideoRecorderState extends State<VideoRecorder> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  bool _isRecording = false;
  ResolutionPreset _currentResolution = ResolutionPreset.medium;
  late CameraDescription _currentCamera;

  // Global key for showing snackbars from background tasks
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _loadResolution();
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
    final prefs = await SharedPreferences.getInstance();
    final resolutionString = prefs.getString('video_resolution') ?? 'medium';
    setState(() {
      _currentResolution = _stringToResolution(resolutionString);
      _currentCamera = widget.cameras.first;
    });
    _controller = CameraController(
      _currentCamera,
      _currentResolution,
    );
    _initializeControllerFuture = _controller.initialize();
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (!_controller.value.isInitialized) {
      return;
    }
    setState(() {
      _isRecording = true;
    });
    await _controller.startVideoRecording();
  }

  Future<void> _stopRecording() async {
    if (!_controller.value.isRecordingVideo) {
      return;
    }

    try {
      final xFile = await _controller.stopVideoRecording();
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
                        // Save the new resolution
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('video_resolution', _resolutionToString(newResolution));

                        // Reinitialize camera with new resolution
                        await _controller.dispose();
                        setState(() {
                          _currentResolution = newResolution;
                          _controller = CameraController(
                            _currentCamera,
                            _currentResolution,
                          );
                          _initializeControllerFuture = _controller.initialize();
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
            InkWell(
              onTap: () {
                SystemNavigator.pop();
              },
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
            if (snapshot.connectionState == ConnectionState.done) {
              // Calculate the scale to fit the preview in the screen
              final size = MediaQuery.of(context).size;
              var scale = size.aspectRatio * _controller.value.aspectRatio;

              // to prevent scaling down, invert the scale
              if (scale < 1) scale = 1 / scale;

              return Transform.scale(
                scale: scale,
                child: Center(
                  child: CameraPreview(_controller),
                ),
              );
            } else {
              return const Center(child: CircularProgressIndicator());
            }
          },
        ),
        bottomNavigationBar: BottomAppBar(
          color: Colors.transparent,
          elevation: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: <Widget>[
              const SizedBox(width: 48), // Placeholder for left side
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

                  // Find the opposite camera
                  CameraDescription? targetCamera;
                  if (_currentCamera.lensDirection == CameraLensDirection.back) {
                    targetCamera = widget.cameras.firstWhere(
                          (camera) => camera.lensDirection == CameraLensDirection.front,
                      orElse: () => _currentCamera,
                    );
                  } else {
                    targetCamera = widget.cameras.firstWhere(
                          (camera) => camera.lensDirection == CameraLensDirection.back,
                      orElse: () => _currentCamera,
                    );
                  }

                  if (targetCamera != _currentCamera) {
                    await _controller.dispose();
                    setState(() {
                      _currentCamera = targetCamera!;
                      _controller = CameraController(
                        _currentCamera,
                        _currentResolution,
                      );
                      _initializeControllerFuture = _controller.initialize();
                    });
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
