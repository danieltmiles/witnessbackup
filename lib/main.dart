import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_storage_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final cameraStatus = await Permission.camera.request();
  final microphoneStatus = await Permission.microphone.request();

  if (cameraStatus.isGranted && microphoneStatus.isGranted) {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      runApp(const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('No cameras found'),
          ),
        ),
      ));
      return;
    }
    runApp(MyApp(cameras: cameras));
  } else {
    runApp(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Camera and microphone permissions are required.'),
        ),
      ),
    ));
  }
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const MyApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Recorder',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: VideoRecorder(cameras: cameras),
    );
  }
}

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

  @override
  void initState() {
    super.initState();
    _loadResolution();
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
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Video saved as $filename to ${Platform.isAndroid ? 'Movies' : 'Documents'}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      
      print("Video saved to $destinationPath");
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Video Recorder'),
        actions: [
          InkWell(
            onTap: () async {
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.autorenew),
                  const SizedBox(height: 2),
                  Text(
                    _currentCamera.lensDirection == CameraLensDirection.back
                        ? 'Front Camera'
                        : 'Rear Camera',
                    style: const TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ),
          ),
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
            return CameraPreview(_controller);
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_isRecording) {
            _stopRecording();
          } else {
            _startRecording();
          }
        },
        child: Icon(_isRecording ? Icons.stop : Icons.videocam),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final ResolutionPreset currentResolution;
  final Function(ResolutionPreset) onResolutionChanged;

  const SettingsPage({
    super.key,
    required this.currentResolution,
    required this.onResolutionChanged,
  });

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ResolutionPreset _selectedResolution;
  String _selectedCloudStorage = 'none';
  bool _isGoogleDriveAuthenticated = false;

  @override
  void initState() {
    super.initState();
    _selectedResolution = widget.currentResolution;
    _loadCloudStorage();
  }

  Future<void> _loadCloudStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final cloudStorage = prefs.getString('cloud_storage') ?? 'none';
    
    // Check authentication status for the current provider
    bool isAuthenticated = false;
    if (cloudStorage != 'none') {
      final provider = CloudStorageFactory.create(cloudStorage);
      if (provider != null) {
        isAuthenticated = await provider.isAuthenticated();
      }
    }
    
    setState(() {
      _selectedCloudStorage = cloudStorage;
      _isGoogleDriveAuthenticated = isAuthenticated;
    });
  }

  String _resolutionToDisplayString(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.low:
        return 'Low (352x288)';
      case ResolutionPreset.medium:
        return 'Medium (720x480)';
      case ResolutionPreset.high:
        return 'High (1280x720)';
      case ResolutionPreset.veryHigh:
        return 'Very High (1920x1080)';
      case ResolutionPreset.ultraHigh:
        return 'Ultra High (3840x2160)';
      case ResolutionPreset.max:
        return 'Max (Highest Available)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          const Text(
            'Video Resolution',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<ResolutionPreset>(
            value: _selectedResolution,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Select Resolution',
            ),
            items: ResolutionPreset.values.map((preset) {
              return DropdownMenuItem(
                value: preset,
                child: Text(_resolutionToDisplayString(preset)),
              );
            }).toList(),
            onChanged: (newValue) {
              if (newValue != null) {
                setState(() {
                  _selectedResolution = newValue;
                });
                widget.onResolutionChanged(newValue);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Resolution updated. Camera will reinitialize.'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
          const SizedBox(height: 24),
          const Text(
            'Note: Actual resolution may vary depending on your device capabilities.',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),
          const Text(
            'Cloud Storage',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _selectedCloudStorage,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Select Cloud Storage',
            ),
            items: CloudStorageFactory.getAvailableProviders().map((provider) {
              return DropdownMenuItem(
                value: provider['id'],
                child: Text(provider['name']!),
              );
            }).toList(),
            onChanged: (newValue) async {
              if (newValue != null) {
                if (newValue == 'none') {
                  // Sign out from current provider if authenticated
                  if (_selectedCloudStorage != '0A0F1CFFnone') {
                    final currentProvider = CloudStorageFactory.create(_selectedCloudStorage);
                    if (currentProvider != null && await currentProvider.isAuthenticated()) {
                      await currentProvider.signOut();
                    }
                  }
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('cloud_storage', newValue);
                  setState(() {
                    _selectedCloudStorage = newValue;
                    _isGoogleDriveAuthenticated = false;
                  });
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cloud storage disabled'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } else {
                  // Initiate authentication with the selected provider
                  final provider = CloudStorageFactory.create(newValue);
                  if (provider != null) {
                    final success = await provider.authenticate(context);
                    if (success) {
                      // Save the selection
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('cloud_storage', newValue);
                      setState(() {
                        _selectedCloudStorage = newValue;
                      });
                      await _loadCloudStorage();
                    }
                  }
                }
              }
            },
          ),
          if (_selectedCloudStorage == 'google_drive') ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  _isGoogleDriveAuthenticated ? Icons.check_circle : Icons.warning,
                  color: _isGoogleDriveAuthenticated ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isGoogleDriveAuthenticated
                        ? 'Connected to Google Drive'
                        : 'Not authenticated. Complete authorization in your browser.',
                    style: TextStyle(
                      color: _isGoogleDriveAuthenticated ? Colors.green : Colors.orange,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            if (!_isGoogleDriveAuthenticated) ...[
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () async {
                  final provider = CloudStorageFactory.create(_selectedCloudStorage);
                  if (provider != null) {
                    await provider.authenticate(context);
                    await _loadCloudStorage();
                  }
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry Authorization'),
              ),
            ],
          ],
          const SizedBox(height: 16),
          const Text(
            'Note: Videos will be automatically uploaded to your configured cloud storage after recording stops.',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}
