import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
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
  Future<bool> uploadFile(String filePath, String fileName) => 
      GoogleDriveAuth.uploadFile(filePath, fileName);
}

/// Internal implementation class for Google Drive OAuth using google_sign_in
/// This class is not exposed outside this file
class GoogleDriveAuth {
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
      final prefs = await SharedPreferences.getInstance();
      final savedState = prefs.getBool(_isAuthenticatedKey) ?? false;
      
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
      if (currentUser == null && savedState) {
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isAuthenticatedKey, isAuthenticated);
  }
  
  /// Uploads a file to Google Drive
  static Future<bool> uploadFile(String filePath, String fileName) async {
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
      
      final fileBytes = await file.readAsBytes();
      print('File size: ${fileBytes.length} bytes');
      
      // Determine MIME type based on file extension
      final mimeType = _getMimeType(fileName);
      print('MIME type: $mimeType');
      
      // Create metadata for the file
      final metadata = {
        'name': fileName,
        'mimeType': mimeType,
      };
      final metadataJson = jsonEncode(metadata);
      
      // Create multipart request body
      // Using multipart/related as per Google Drive API v3 documentation
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
        print('File name: ${responseData['name']}');
        return true;
      } else {
        print('Upload failed with status code: ${response.statusCode}');
        print('Response: ${response.body}');
        return false;
      }
    } catch (e, stackTrace) {
      print('Error uploading file: $e');
      print('Stack trace: $stackTrace');
      return false;
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
