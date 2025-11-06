import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'cloud_storage_provider.dart';

/// Google Drive implementation of CloudStorageProvider
/// Encapsulates all Google Drive-specific authentication and upload logic
class GoogleDriveProvider implements CloudStorageProvider {
  @override
  String get displayName => 'Google Drive';
  
  @override
  String get providerId => 'google_drive';
  
  @override
  Future<bool> authenticate(BuildContext context) => GoogleDriveAuth.authenticate(context);
  
  @override
  Future<bool> isAuthenticated() => GoogleDriveAuth.isAuthenticated();
  
  @override
  Future<void> signOut() => GoogleDriveAuth.signOut();
  
  @override
  Future<bool> uploadFile(
    String filePath, 
    String fileName, {
    String? taskId,
    String? existingSessionUri,
    int? startByte,
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  }) => GoogleDriveAuth.uploadFile(
    filePath, 
    fileName,
    taskId: taskId,
    existingSessionUri: existingSessionUri,
    startByte: startByte,
    onProgress: onProgress,
  );
}

/// Internal implementation class for Google Drive OAuth using google_sign_in
/// This class is not exposed outside this file
class GoogleDriveAuth {
  // Secure storage instance
  static const _storage = FlutterSecureStorage();

  // GoogleSignIn instance configured for Drive access
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'https://www.googleapis.com/auth/drive.file',
    ],
  );
  
  // Storage keys
  static const String _isAuthenticatedKey = 'google_drive_is_authenticated';
  
  /// Initiates the OAuth flow using google_sign_in
  static Future<bool> authenticate(BuildContext context) async {
    try {
      print('=== Google Drive Sign-In Debug ===');
      
      // Check if already signed in
      final currentUser = _googleSignIn.currentUser;
      if (currentUser != null) {
        print('Already signed in as: ${currentUser.email}');
        await _saveAuthState(true);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Already signed in as ${currentUser.email}'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return true;
      }
      
      // Attempt silent sign-in first
      print('Attempting silent sign-in...');
      var account = await _googleSignIn.signInSilently();
      
      // If silent sign-in fails, try interactive sign-in
      if (account == null) {
        print('Silent sign-in failed, attempting interactive sign-in...');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Opening Google Sign-In...'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        
        account = await _googleSignIn.signIn();
      }
      
      if (account != null) {
        print('Successfully signed in as: ${account.email}');
        
        // Get authentication headers to verify we have the required scope
        final auth = await account.authentication;
        print('Access token obtained: ${auth.accessToken != null}');
        
        await _saveAuthState(true);
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Signed in as ${account.email}'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return true;
      } else {
        print('Sign-in was cancelled or failed');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Sign-in cancelled'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return false;
      }
    } catch (e, stackTrace) {
      print('=== Google Sign-In Error ===');
      print('Error: $e');
      print('Stack trace: $stackTrace');
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error during sign-in: $e\nCheck console for details.'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return false;
    }
  }
  
  /// Attempts to silently restore authentication session
  /// This should be called on app startup to restore previous sessions
  static Future<bool> attemptSilentSignIn() async {
    try {
      print('Attempting silent sign-in to restore Google Drive session...');
      
      // Check if already signed in
      final currentUser = _googleSignIn.currentUser;
      if (currentUser != null) {
        print('Already signed in as: ${currentUser.email}');
        await _saveAuthState(true);
        return true;
      }
      
      // Attempt silent sign-in
      final account = await _googleSignIn.signInSilently();
      
      if (account != null) {
        print('Successfully restored session for: ${account.email}');
        await _saveAuthState(true);
        return true;
      } else {
        print('No previous session to restore');
        await _saveAuthState(false);
        return false;
      }
    } catch (e) {
      print('Error during silent sign-in: $e');
      await _saveAuthState(false);
      return false;
    }
  }
  
  /// Checks if user is authenticated
  static Future<bool> isAuthenticated() async {
    try {
      final savedState = await _storage.read(key: _isAuthenticatedKey);
      
      // Also verify with google_sign_in
      final currentUser = _googleSignIn.currentUser;
      
      if (currentUser != null) {
        // Verify the access token is still valid
        final auth = await currentUser.authentication;
        if (auth.accessToken != null && auth.accessToken!.isNotEmpty) {
          await _saveAuthState(true);
          return true;
        }
      }
      
      // If google_sign_in says not authenticated but we have saved state,
      // attempt silent sign-in to restore the session
      if (currentUser == null && savedState == 'true') {
        print('User should be authenticated but no current session. Attempting silent sign-in...');
        return await attemptSilentSignIn();
      }
      
      return currentUser != null;
    } catch (e) {
      print('Error checking authentication: $e');
      return false;
    }
  }
  
  /// Gets the current access token
  static Future<String?> getAccessToken() async {
    try {
      final currentUser = _googleSignIn.currentUser;
      if (currentUser == null) {
        return null;
      }
      
      final auth = await currentUser.authentication;
      return auth.accessToken;
    } catch (e) {
      print('Error getting access token: $e');
      return null;
    }
  }
  
  /// Signs out the user
  static Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      await _saveAuthState(false);
      print('Signed out from Google Drive');
    } catch (e) {
      print('Error signing out: $e');
    }
  }
  
  /// Saves authentication state to SharedPreferences
  static Future<void> _saveAuthState(bool isAuthenticated) async {
    await _storage.write(key: _isAuthenticatedKey, value: isAuthenticated.toString());
  }
  
  /// Uploads a file to Google Drive using resumable upload for large files
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
        print('Not authenticated with Google Drive');
        return false;
      }
      
      print('Starting upload of $fileName to Google Drive...');
      
      // Read the file
      final file = File(filePath);
      if (!await file.exists()) {
        print('Error: File does not exist at path: $filePath');
        return false;
      }
      
      final fileSize = await file.length();
      print('File size: $fileSize bytes');
      
      // Use resumable upload for files larger than 5MB
      const resumableThreshold = 5 * 1024 * 1024; // 5 MB
      
      if (fileSize <= resumableThreshold) {
        // For small files, use simple multipart upload
        return await _uploadSimple(file, fileName, accessToken, onProgress: onProgress);
      } else {
        // For large files, use resumable upload with progress tracking
        return await _uploadResumable(
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
  
  /// Simple multipart upload for small files
  static Future<bool> _uploadSimple(
    File file, 
    String fileName, 
    String accessToken, {
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  }) async {
    final fileBytes = await file.readAsBytes();
    final mimeType = _getMimeType(fileName);
    print('MIME type: $mimeType');
    
    // Create metadata for the file
    final metadata = {
      'name': fileName,
      'mimeType': mimeType,
    };
    final metadataJson = jsonEncode(metadata);
    
    // Create multipart request body
    final boundary = 'boundary_${DateTime.now().millisecondsSinceEpoch}';
    
    final List<int> body = [];
    
    // Part 1: Metadata
    body.addAll(utf8.encode('--$boundary\r\n'));
    body.addAll(utf8.encode('Content-Type: application/json; charset=UTF-8\r\n\r\n'));
    body.addAll(utf8.encode(metadataJson));
    body.addAll(utf8.encode('\r\n'));
    
    // Part 2: File content
    body.addAll(utf8.encode('--$boundary\r\n'));
    body.addAll(utf8.encode('Content-Type: $mimeType\r\n\r\n'));
    body.addAll(fileBytes);
    body.addAll(utf8.encode('\r\n'));
    
    // End boundary
    body.addAll(utf8.encode('--$boundary--'));
    
    // Make the upload request
    print('Uploading file (simple mode)...');
    final uploadUrl = 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart';
    
    final response = await http.post(
      Uri.parse(uploadUrl),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'multipart/related; boundary=$boundary',
        'Content-Length': body.length.toString(),
      },
      body: body,
    );
    
    if (response.statusCode == 200 || response.statusCode == 201) {
      final responseData = jsonDecode(response.body);
      final fileId = responseData['id'];
      print('Successfully uploaded file to Google Drive');
      print('File ID: $fileId');
      return true;
    } else {
      print('Upload failed with status code: ${response.statusCode}');
      print('Response: ${response.body}');
      return false;
    }
  }
  
  /// Resumable upload for large files
  static Future<bool> _uploadResumable(
    File file, 
    String fileName, 
    String accessToken, 
    int fileSize, {
    String? existingSessionUri,
    int startByte = 0,
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  }) async {
    final mimeType = _getMimeType(fileName);
    print('MIME type: $mimeType');
    print('Using resumable upload');
    
    String uploadUri;
    
    // Step 1: Get or create resumable upload session
    if (existingSessionUri != null && existingSessionUri.isNotEmpty) {
      // Resume existing session
      print('Resuming upload from existing session: $existingSessionUri');
      print('Starting from byte: $startByte');
      uploadUri = existingSessionUri;
    } else {
      // Initiate new resumable upload session
      final metadata = {
        'name': fileName,
        'mimeType': mimeType,
      };
      final metadataJson = jsonEncode(metadata);
      
      print('Initiating new resumable upload session...');
      final initResponse = await http.post(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json; charset=UTF-8',
          'X-Upload-Content-Type': mimeType,
          'X-Upload-Content-Length': fileSize.toString(),
        },
        body: metadataJson,
      );
      
      if (initResponse.statusCode != 200) {
        print('Failed to initiate resumable upload: ${initResponse.statusCode}');
        print('Response: ${initResponse.body}');
        return false;
      }
      
      uploadUri = initResponse.headers['location'] ?? '';
      if (uploadUri.isEmpty) {
        print('No upload URI returned in Location header');
        return false;
      }
      
      print('Resumable upload session created: $uploadUri');
      
      // Call progress callback with session URI
      if (onProgress != null) {
        onProgress(0, fileSize, uploadUri);
      }
    }
    
    // Step 2: Upload file in chunks
    const chunkSize = 5 * 1024 * 1024; // 5 MB chunks (multiple of 256 KB as required by Google)
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
        
        // Calculate range
        final rangeStart = uploadedBytes;
        final rangeEnd = uploadedBytes + chunk.length - 1;
        
        print('Uploading chunk $chunkNumber: bytes $rangeStart-$rangeEnd/$fileSize (${(rangeEnd + 1) * 100 ~/ fileSize}%)');
        
        // Upload chunk
        final chunkResponse = await http.put(
          Uri.parse(uploadUri),
          headers: {
            'Content-Length': chunk.length.toString(),
            'Content-Range': 'bytes $rangeStart-$rangeEnd/${fileSize}',
          },
          body: chunk,
        );
        
        print('Chunk $chunkNumber response status: ${chunkResponse.statusCode}');
        
        // Check response
        // 308 Resume Incomplete - continue uploading
        // 200 or 201 - upload complete
        if (chunkResponse.statusCode == 308) {
          // Continue uploading
          uploadedBytes += chunk.length;
          
          // Call progress callback
          if (onProgress != null) {
            onProgress(uploadedBytes, fileSize, uploadUri);
          }
        } else if (chunkResponse.statusCode == 200 || chunkResponse.statusCode == 201) {
          // Upload complete
          final responseData = jsonDecode(chunkResponse.body);
          final fileId = responseData['id'];
          print('Successfully uploaded file to Google Drive');
          print('File ID: $fileId');
          
          // Call final progress callback
          if (onProgress != null) {
            onProgress(fileSize, fileSize, null);
          }
          
          return true;
        } else {
          print('Chunk upload failed with status code: ${chunkResponse.statusCode}');
          print('Response: ${chunkResponse.body}');
          return false;
        }
      }
      
      return true;
    } finally {
      await randomAccessFile.close();
    }
  }
  
  /// Determines MIME type based on file extension
  static String _getMimeType(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    
    switch (extension) {
      case 'txt':
        return 'text/plain';
      case 'pdf':
        return 'application/pdf';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'zip':
        return 'application/zip';
      case 'json':
        return 'application/json';
      case 'xml':
        return 'application/xml';
      default:
        return 'application/octet-stream';
    }
  }
}
