import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart' as custom_tabs;
import 'package:crypto/crypto.dart';
import 'dart:math';
import 'cloud_storage_provider.dart';

/// Dropbox implementation of CloudStorageProvider
/// Encapsulates all Dropbox-specific authentication and upload logic
class DropboxProvider implements CloudStorageProvider {
  @override
  String get displayName => 'Dropbox';
  
  @override
  String get providerId => 'dropbox';
  
  @override
  Future<bool> authenticate(BuildContext context) => DropboxAuth.authenticate(context);
  
  @override
  Future<bool> isAuthenticated() => DropboxAuth.isAuthenticated();
  
  @override
  Future<void> signOut() => DropboxAuth.signOut();
  
  @override
  Future<bool> uploadFile(
    String filePath, 
    String fileName, {
    String? taskId,
    String? existingSessionUri,
    int? startByte,
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  }) => DropboxAuth.uploadFile(
    filePath, 
    fileName,
    taskId: taskId,
    existingSessionUri: existingSessionUri,
    startByte: startByte,
    onProgress: onProgress,
  );
}

/// Internal implementation class for Dropbox OAuth 2.0 and API
/// This class is not exposed outside this file
class DropboxAuth {
  // Secure storage instance
  static const _storage = FlutterSecureStorage();

  // Dropbox OAuth configuration
  // NOTE: Replace these with your actual Dropbox app credentials
  static const String _appKey = 'wc10ca6zcclali8';
  // Use custom scheme for mobile OAuth callback (matches AndroidManifest.xml)
  static const String _redirectUri = 'org.doodledome.witnessbackup://oauth-callback';
  
  // Storage keys
  static const String _accessTokenKey = 'dropbox_access_token';
  static const String _refreshTokenKey = 'dropbox_refresh_token';
  static const String _isAuthenticatedKey = 'dropbox_is_authenticated';
  
  // Dropbox API endpoints
  static const String _authorizationEndpoint = 'https://www.dropbox.com/oauth2/authorize';
  static const String _tokenEndpoint = 'https://api.dropbox.com/oauth2/token';
  static const String _apiEndpoint = 'https://api.dropboxapi.com/2';
  static const String _contentEndpoint = 'https://content.dropboxapi.com/2';
  
  /// Initiates the OAuth 2.0 flow with PKCE
  static Future<bool> authenticate(BuildContext context) async {
    try {
      print('=== Dropbox OAuth Debug ===');
      
      // Generate PKCE parameters
      final codeVerifier = _generateCodeVerifier();
      final codeChallenge = _generateCodeChallenge(codeVerifier);
      final state = _generateRandomString(32);
      
      // Store PKCE parameters temporarily
      await _storage.write(key: 'dropbox_code_verifier', value: codeVerifier);
      await _storage.write(key: 'dropbox_state', value: state);
      
      // Build authorization URL
      final authUrl = Uri.parse(_authorizationEndpoint).replace(queryParameters: {
        'client_id': _appKey,
        'response_type': 'code',
        'redirect_uri': _redirectUri,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'state': state,
        'token_access_type': 'offline', // Request refresh token
      });
      
      print('Authorization URL: ${authUrl.toString()}');
      print('Redirect URI: $_redirectUri');
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Opening Dropbox authorization...\n\nThis will use an in-app browser for better security and experience.'),
            duration: Duration(seconds: 4),
            backgroundColor: Colors.blue,
          ),
        );
      }
      
      // Launch authorization URL using Chrome Custom Tabs (Android) / Safari View Controller (iOS)
      // This provides a better user experience and works consistently across all browsers
      print('Launching Chrome Custom Tabs...');
      try {
        await custom_tabs.launchUrl(
          authUrl,
          customTabsOptions: custom_tabs.CustomTabsOptions(
            colorSchemes: custom_tabs.CustomTabsColorSchemes.defaults(
              toolbarColor: Theme.of(context).primaryColor,
            ),
            shareState: custom_tabs.CustomTabsShareState.off,
            urlBarHidingEnabled: true,
            showTitle: true,
            closeButton: custom_tabs.CustomTabsCloseButton(
              icon: custom_tabs.CustomTabsCloseButtonIcons.back,
            ),
          ),
          safariVCOptions: custom_tabs.SafariViewControllerOptions(
            preferredBarTintColor: Theme.of(context).primaryColor,
            preferredControlTintColor: Colors.white,
            barCollapsingEnabled: true,
            dismissButtonStyle: custom_tabs.SafariViewControllerDismissButtonStyle.close,
          ),
        );
        
        print('Chrome Custom Tabs launched successfully. Waiting for callback via deep link...');
        
        // Return true - the actual token exchange will happen when the app receives the deep link
        // For now, we're just initiating the OAuth flow
        return true;
        
      } catch (e) {
        print('Error launching URL: $e');
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error opening browser: $e'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return false;
      }
    } catch (e, stackTrace) {
      print('=== Dropbox OAuth Error ===');
      print('Error: $e');
      print('Stack trace: $stackTrace');
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error during sign-in: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return false;
    }
  }
  
  /// Handles the OAuth callback from deep link
  /// Call this method when the app receives a deep link callback
  static Future<bool> handleOAuthCallback(Uri uri, BuildContext context) async {
    try {
      print('=== Dropbox OAuth Callback ===');
      print('Received URI: ${uri.toString()}');
      
      // Extract parameters from URI
      final code = uri.queryParameters['code'];
      final returnedState = uri.queryParameters['state'];
      final error = uri.queryParameters['error'];
      
      // Get stored state for validation
      final expectedState = await _storage.read(key: 'dropbox_state');
      final codeVerifier = await _storage.read(key: 'dropbox_code_verifier');
      
      // Validate state parameter
      if (returnedState != expectedState) {
        print('State parameter mismatch - possible CSRF attack');
        print('Expected: $expectedState, Got: $returnedState');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Security validation failed'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return false;
      }
      
      // Handle errors
      if (error != null) {
        print('Authorization error: $error');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Authorization failed: $error'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return false;
      }
      
      // Exchange authorization code for tokens
      if (code != null && codeVerifier != null) {
        print('Exchanging authorization code for tokens...');

        final tokenResponse = await http.post(
          Uri.parse(_tokenEndpoint),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: {
            'code': code,
            'grant_type': 'authorization_code',
            'client_id': _appKey,
            'redirect_uri': _redirectUri,
            'code_verifier': codeVerifier,
          },
        );

        if (tokenResponse.statusCode == 200) {
          final tokenData = jsonDecode(tokenResponse.body);
          final accessToken = tokenData['access_token'];
          final refreshToken = tokenData['refresh_token'];

          // Store tokens
          await _storage.write(key: _accessTokenKey, value: accessToken);
          if (refreshToken != null) {
            await _storage.write(key: _refreshTokenKey, value: refreshToken);
          }
          await _storage.write(key: _isAuthenticatedKey, value: 'true');

          // Clean up temporary PKCE parameters
          await _storage.delete(key: 'dropbox_code_verifier');
          await _storage.delete(key: 'dropbox_state');

          print('Successfully authenticated with Dropbox');

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Successfully signed in to Dropbox'),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 3),
              ),
            );
          }
          return true;
        } else {
          print('Token exchange failed: ${tokenResponse.statusCode}');
          print('Response: ${tokenResponse.body}');
          return false;
        }
      }

      return false;
    } catch (e, stackTrace) {
      print('=== Dropbox OAuth Error ===');
      print('Error: $e');
      print('Stack trace: $stackTrace');
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error during sign-in: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return false;
    }
  }
  
  /// Checks if user is authenticated
  static Future<bool> isAuthenticated() async {
    try {
      final isAuthenticated = await _storage.read(key: _isAuthenticatedKey);
      final accessToken = await _storage.read(key: _accessTokenKey);
      
      return isAuthenticated == 'true' && accessToken != null && accessToken.isNotEmpty;
    } catch (e) {
      print('Error checking authentication: $e');
      return false;
    }
  }
  
  /// Gets the current access token, refreshing if necessary
  static Future<String?> getAccessToken() async {
    try {
      final accessToken = await _storage.read(key: _accessTokenKey);
      
      // For simplicity, we'll assume the token is valid
      // In a production app, you should check token expiration and refresh if needed
      return accessToken;
    } catch (e) {
      print('Error getting access token: $e');
      return null;
    }
  }
  
  /// Signs out the user
  static Future<void> signOut() async {
    try {
      await _storage.delete(key: _accessTokenKey);
      await _storage.delete(key: _refreshTokenKey);
      await _storage.write(key: _isAuthenticatedKey, value: 'false');
      print('Signed out from Dropbox');
    } catch (e) {
      print('Error signing out: $e');
    }
  }
  
  /// Uploads a file to Dropbox
  static Future<bool> uploadFile(
    String filePath, 
    String fileName, {
    String? taskId,
    String? existingSessionUri,
    int? startByte,
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  }) async {
    try {
      final accessToken = await getAccessToken();
      if (accessToken == null) {
        print('Not authenticated with Dropbox');
        return false;
      }
      
      print('Starting upload of $fileName to Dropbox...');
      
      // Read the file
      final file = File(filePath);
      if (!await file.exists()) {
        print('Error: File does not exist at path: $filePath');
        return false;
      }
      
      final fileSize = await file.length();
      print('File size: $fileSize bytes');
      
      // Use upload session for files larger than 150MB
      // Dropbox recommends using sessions for files > 150MB
      const sessionThreshold = 150 * 1024 * 1024; // 150 MB
      
      if (fileSize <= sessionThreshold) {
        // For smaller files, use simple upload
        return await _uploadSimple(file, fileName, accessToken, onProgress: onProgress);
      } else {
        // For large files, use upload session
        return await _uploadSession(
          file, 
          fileName, 
          accessToken, 
          fileSize,
          existingSessionUri: existingSessionUri,
          startByte: startByte ?? 0,
          onProgress: onProgress,
        );
      }
    } catch (e, stackTrace) {
      print('Error uploading file: $e');
      print('Stack trace: $stackTrace');
      return false;
    }
  }
  
  /// Simple upload for smaller files
  static Future<bool> _uploadSimple(
    File file, 
    String fileName, 
    String accessToken, {
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  }) async {
    final fileBytes = await file.readAsBytes();
    
    print('Uploading file (simple mode)...');
    
    // Dropbox API parameters
    final apiArg = {
      'path': '/$fileName',
      'mode': 'add',
      'autorename': true,
      'mute': false,
    };
    
    final response = await http.post(
      Uri.parse('$_contentEndpoint/files/upload'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': jsonEncode(apiArg),
      },
      body: fileBytes,
    );
    
    if (response.statusCode == 200) {
      final responseData = jsonDecode(response.body);
      final fileId = responseData['id'];
      print('Successfully uploaded file to Dropbox');
      print('File ID: $fileId');
      return true;
    } else {
      print('Upload failed with status code: ${response.statusCode}');
      print('Response: ${response.body}');
      return false;
    }
  }
  
  /// Upload session for large files
  static Future<bool> _uploadSession(
    File file, 
    String fileName, 
    String accessToken, 
    int fileSize, {
    String? existingSessionUri,
    int startByte = 0,
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  }) async {
    print('Using upload session for large file');
    
    String? sessionId = existingSessionUri;
    
    // Step 1: Start or resume upload session
    if (sessionId == null || sessionId.isEmpty) {
      print('Starting new upload session...');
      
      final startResponse = await http.post(
        Uri.parse('$_contentEndpoint/files/upload_session/start'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/octet-stream',
        },
        body: [],
      );
      
      if (startResponse.statusCode != 200) {
        print('Failed to start upload session: ${startResponse.statusCode}');
        print('Response: ${startResponse.body}');
        return false;
      }
      
      final sessionData = jsonDecode(startResponse.body);
      sessionId = sessionData['session_id'];
      print('Upload session started: $sessionId');
      
      // Call progress callback with session ID
      if (onProgress != null) {
        onProgress(0, fileSize, sessionId);
      }
    } else {
      print('Resuming upload session: $sessionId');
      print('Starting from byte: $startByte');
    }
    
    // Step 2: Upload file in chunks
    const chunkSize = 8 * 1024 * 1024; // 8 MB chunks
    final randomAccessFile = await file.open(mode: FileMode.read);
    
    try {
      // Seek to start byte if resuming
      if (startByte > 0) {
        await randomAccessFile.setPosition(startByte);
      }
      
      int uploadedBytes = startByte;
      int chunkNumber = startByte ~/ chunkSize;
      
      while (uploadedBytes < fileSize) {
        chunkNumber++;
        final remainingBytes = fileSize - uploadedBytes;
        final currentChunkSize = remainingBytes < chunkSize ? remainingBytes : chunkSize;
        
        // Read chunk
        final chunk = await randomAccessFile.read(currentChunkSize);
        
        print('Uploading chunk $chunkNumber: bytes $uploadedBytes-${uploadedBytes + chunk.length - 1}/$fileSize (${(uploadedBytes + chunk.length) * 100 ~/ fileSize}%)');
        
        // Append chunk to session
        final cursor = {
          'session_id': sessionId,
          'offset': uploadedBytes,
        };
        
        final appendResponse = await http.post(
          Uri.parse('$_contentEndpoint/files/upload_session/append_v2'),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/octet-stream',
            'Dropbox-API-Arg': jsonEncode({'cursor': cursor}),
          },
          body: chunk,
        );
        
        print('Chunk $chunkNumber response status: ${appendResponse.statusCode}');
        
        if (appendResponse.statusCode != 200) {
          print('Chunk upload failed with status code: ${appendResponse.statusCode}');
          print('Response: ${appendResponse.body}');
          return false;
        }
        
        uploadedBytes += chunk.length;
        
        // Call progress callback
        if (onProgress != null) {
          onProgress(uploadedBytes, fileSize, sessionId);
        }
      }
      
      // Step 3: Finish upload session
      print('Finishing upload session...');
      
      final cursor = {
        'session_id': sessionId,
        'offset': uploadedBytes,
      };
      
      final commit = {
        'path': '/$fileName',
        'mode': 'add',
        'autorename': true,
        'mute': false,
      };
      
      final finishResponse = await http.post(
        Uri.parse('$_contentEndpoint/files/upload_session/finish'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/octet-stream',
          'Dropbox-API-Arg': jsonEncode({
            'cursor': cursor,
            'commit': commit,
          }),
        },
        body: [],
      );
      
      if (finishResponse.statusCode == 200) {
        final responseData = jsonDecode(finishResponse.body);
        final fileId = responseData['id'];
        print('Successfully uploaded file to Dropbox');
        print('File ID: $fileId');
        
        // Call final progress callback
        if (onProgress != null) {
          onProgress(fileSize, fileSize, null);
        }
        
        return true;
      } else {
        print('Finish upload failed with status code: ${finishResponse.statusCode}');
        print('Response: ${finishResponse.body}');
        return false;
      }
    } finally {
      await randomAccessFile.close();
    }
  }
  
  /// Generates a cryptographically secure random string for PKCE code verifier
  static String _generateCodeVerifier() {
    final random = Random.secure();
    final values = List<int>.generate(32, (i) => random.nextInt(256));
    return base64UrlEncode(values).replaceAll('=', '');
  }
  
  /// Generates PKCE code challenge from verifier
  static String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }
  
  /// Generates a random string of specified length
  static String _generateRandomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(length, (i) => chars[random.nextInt(chars.length)]).join();
  }
}
