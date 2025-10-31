import 'dart:async';
import 'dart:convert';
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
      
      // If google_sign_in says not authenticated, update our saved state
      if (currentUser == null && savedState) {
        await _saveAuthState(false);
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
      
      print('Access token available for upload');
      
      // TODO: Implement actual file upload to Google Drive API
      // This would involve:
      // 1. Reading the file
      // 2. Creating metadata JSON
      // 3. Using multipart/related to upload file + metadata
      // 4. Making POST request to https://www.googleapis.com/upload/drive/v3/files
      //    with Authorization: Bearer {accessToken}
      
      print('Upload to Google Drive not yet fully implemented');
      print('Would upload: $filePath as $fileName');
      print('Using access token: ${accessToken.substring(0, 20)}...');
      
      return true;
    } catch (e) {
      print('Error uploading file: $e');
      return false;
    }
  }
}
