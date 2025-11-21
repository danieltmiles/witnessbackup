import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_storage_provider.dart';
import 'webdav.dart' show WebDAVAuth;
import 'dart:io';

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

    // Validate that the stored value is actually a valid provider
    final availableProviders = CloudStorageFactory.getAvailableProviders();
    bool isValidProvider = false;
    for (var provider in availableProviders) {
      if (provider['id'] == cloudStorage) {
        isValidProvider = true;
        break;
      }
    }

    // If the stored value is not valid, default to 'none'
    final safeCloudStorage = isValidProvider ? cloudStorage : 'none';

    // Check authentication status for the current provider
    bool isAuthenticated = false;
    if (safeCloudStorage != 'none') {
      final provider = CloudStorageFactory.create(safeCloudStorage);
      if (provider != null) {
        isAuthenticated = await provider.isAuthenticated();
      }
    }

    // Load WebDAV configuration if it's the selected provider
    if (safeCloudStorage == 'webdav') {
      final config = await WebDAVAuth.getConfiguration();
      _webdavUriController.text = config['baseUri'] ?? '';
      _webdavUsernameController.text = config['username'] ?? '';
      _webdavPasswordController.text = config['password'] ?? '';
    }

    setState(() {
      _selectedCloudStorage = safeCloudStorage;
      _isGoogleDriveAuthenticated = safeCloudStorage == 'google_drive' && isAuthenticated;
      _isWebDAVAuthenticated = safeCloudStorage == 'webdav' && isAuthenticated;
      _isDropboxAuthenticated = safeCloudStorage == 'dropbox' && isAuthenticated;
    });
  }

  String _resolutionToDisplayString(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.low:
        return 'Low (${Platform.isAndroid ? '~240p' : '352x248'})';
      case ResolutionPreset.medium:
        return 'Medium (~480p)';
      case ResolutionPreset.high:
        return 'High (~720p)';
      case ResolutionPreset.veryHigh:
        return 'Very High (~1080p)';
      case ResolutionPreset.ultraHigh:
        return 'Ultra High (~2160p)';
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
            items: ResolutionPreset.values
                .where((preset) => preset != ResolutionPreset.max)
                .map((preset) {
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
