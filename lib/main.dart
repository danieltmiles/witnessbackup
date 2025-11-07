import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_links/app_links.dart';
import 'cloud_storage_provider.dart';
import 'webdav.dart' show WebDAVAuth;
import 'dropbox.dart' show DropboxAuth;
import 'background_upload_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize background upload service (works on both Android and iOS)
  await BackgroundUploadService.initialize();

  // Attempt to restore cloud storage authentication on app startup
  await _restoreCloudStorageAuth();

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

class MyApp extends StatefulWidget {
  final List<CameraDescription> cameras;

  const MyApp({super.key, required this.cameras});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _initDeepLinkListener();
  }

  void _initDeepLinkListener() {
    _appLinks = AppLinks();
    
    // Handle links when app is already running
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    }, onError: (err) {
      print('Error listening to deep links: $err');
    });
    
    // Handle the initial link if app was launched from a deep link
    _handleInitialLink();
  }

  Future<void> _handleInitialLink() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        print('App launched with deep link: ${uri.toString()}');
        _handleDeepLink(uri);
      } else {
        print('No initial deep link (app not launched from link)');
      }
    } catch (e) {
      print('Error getting initial link: $e');
    }
  }

  void _handleDeepLink(Uri uri) {
    print('Received deep link: ${uri.toString()}');
    
    try {
      // Check if this is a Dropbox OAuth callback
      if (uri.scheme == 'org.doodledome.witnessbackup' && uri.host == 'oauth-callback') {
        final context = _navigatorKey.currentContext;
        if (context != null) {
          DropboxAuth.handleOAuthCallback(uri, context);
        }
      }
    } catch (e) {
      print('Error handling deep link: $e');
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Video Recorder',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: VideoRecorder(cameras: widget.cameras),
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
            final orientation = MediaQuery.of(context).orientation;
            final previewSize = _controller.value.previewSize!;
            return Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: (orientation == Orientation.landscape)
                      ? previewSize.width
                      : previewSize.height,
                  height: (orientation == Orientation.landscape)
                      ? previewSize.height
                      : previewSize.width,
                  child: CameraPreview(_controller),
                ),
              ),
            );
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
  bool _isWebDAVAuthenticated = false;
  bool _isDropboxAuthenticated = false;
  
  // WebDAV configuration controllers
  final TextEditingController _webdavUriController = TextEditingController();
  final TextEditingController _webdavUsernameController = TextEditingController();
  final TextEditingController _webdavPasswordController = TextEditingController();
  bool _webdavPasswordVisible = false;

  @override
  void initState() {
    super.initState();
    _selectedResolution = widget.currentResolution;
    _loadCloudStorage();
  }

  @override
  void dispose() {
    _webdavUriController.dispose();
    _webdavUsernameController.dispose();
    _webdavPasswordController.dispose();
    super.dispose();
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
    
    // Load WebDAV configuration if it's the selected provider
    if (cloudStorage == 'webdav') {
      final config = await WebDAVAuth.getConfiguration();
      _webdavUriController.text = config['baseUri'] ?? '';
      _webdavUsernameController.text = config['username'] ?? '';
      _webdavPasswordController.text = config['password'] ?? '';
    }
    
    setState(() {
      _selectedCloudStorage = cloudStorage;
      _isGoogleDriveAuthenticated = cloudStorage == 'google_drive' && isAuthenticated;
      _isWebDAVAuthenticated = cloudStorage == 'webdav' && isAuthenticated;
      _isDropboxAuthenticated = cloudStorage == 'dropbox' && isAuthenticated;
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
                  if (_selectedCloudStorage != 'none') {
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
                    _isWebDAVAuthenticated = false;
                  });
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cloud storage disabled'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } else if (newValue == 'webdav') {
                  // For WebDAV, just save the selection and show the configuration UI
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('cloud_storage', newValue);
                  setState(() {
                    _selectedCloudStorage = newValue;
                  });
                  await _loadCloudStorage();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Please configure your WebDAV server settings below'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } else {
                  // For other providers (like Google Drive), initiate authentication
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
          if (_selectedCloudStorage == 'dropbox') ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  _isDropboxAuthenticated ? Icons.check_circle : Icons.warning,
                  color: _isDropboxAuthenticated ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isDropboxAuthenticated
                        ? 'Connected to Dropbox'
                        : 'Not authenticated. Complete authorization in your browser.',
                    style: TextStyle(
                      color: _isDropboxAuthenticated ? Colors.green : Colors.orange,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            if (!_isDropboxAuthenticated) ...[
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
          if (_selectedCloudStorage == 'webdav') ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  _isWebDAVAuthenticated ? Icons.check_circle : Icons.warning,
                  color: _isWebDAVAuthenticated ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isWebDAVAuthenticated
                        ? 'WebDAV configured and connected'
                        : 'Please configure WebDAV settings',
                    style: TextStyle(
                      color: _isWebDAVAuthenticated ? Colors.green : Colors.orange,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _webdavUriController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'WebDAV Server URI',
                hintText: 'https://example.com/webdav/',
                prefixIcon: Icon(Icons.cloud),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _webdavUsernameController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Username',
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _webdavPasswordController,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(
                    _webdavPasswordVisible ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () {
                    setState(() {
                      _webdavPasswordVisible = !_webdavPasswordVisible;
                    });
                  },
                ),
              ),
              obscureText: !_webdavPasswordVisible,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () async {
                final uri = _webdavUriController.text.trim();
                final username = _webdavUsernameController.text.trim();
                final password = _webdavPasswordController.text;
                
                if (uri.isEmpty || username.isEmpty || password.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please fill in all WebDAV fields'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }
                
                // Show loading indicator
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const Center(
                    child: CircularProgressIndicator(),
                  ),
                );
                
                // Validate connection
                final isValid = await WebDAVAuth.validateConnection(uri, username, password);
                
                // Dismiss loading indicator
                if (mounted) Navigator.of(context).pop();
                
                if (isValid) {
                  // Save configuration
                  await WebDAVAuth.saveConfiguration(uri, username, password);
                  await _loadCloudStorage();
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('WebDAV configuration saved successfully'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } else {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Failed to connect to WebDAV server. Please check your credentials and URI.'),
                        backgroundColor: Colors.red,
                        duration: Duration(seconds: 4),
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.save),
              label: const Text('Save and Test Connection'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              ),
            ),
            if (_isWebDAVAuthenticated) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  await WebDAVAuth.signOut();
                  _webdavUriController.clear();
                  _webdavUsernameController.clear();
                  _webdavPasswordController.clear();
                  await _loadCloudStorage();
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('WebDAV configuration cleared'),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear Configuration'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                ),
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
