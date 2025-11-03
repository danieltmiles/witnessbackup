import 'package:flutter/material.dart';
import 'google_drive.dart' show GoogleDriveProvider;
import 'webdav.dart' show WebDAVProvider;

/// Abstract interface for cloud storage providers
/// Each provider (Google Drive, Dropbox, OneDrive, etc.) implements this interface
abstract class CloudStorageProvider {
  /// Display name of the provider (e.g., "Google Drive", "Dropbox")
  String get displayName;
  
  /// Unique identifier for the provider (e.g., "google_drive", "dropbox")
  String get providerId;
  
  /// Initiates the authentication flow
  /// Returns true if authentication was initiated successfully
  Future<bool> authenticate(BuildContext context);
  
  /// Checks if the user is currently authenticated with this provider
  Future<bool> isAuthenticated();
  
  /// Signs out the user from this provider
  Future<void> signOut();
  
  /// Uploads a file to the cloud storage
  /// [filePath] - Local path to the file
  /// [fileName] - Name to give the file in cloud storage
  /// [taskId] - Optional task ID for tracking progress
  /// [existingSessionUri] - Optional existing resumable session URI to resume from
  /// [startByte] - Optional starting byte position for resuming
  /// [onProgress] - Optional callback for upload progress updates
  /// Returns true if upload was successful
  Future<bool> uploadFile(
    String filePath, 
    String fileName, {
    String? taskId,
    String? existingSessionUri,
    int? startByte,
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  });
  
  /// Optional: Get current upload progress (0.0 to 1.0)
  /// Can be used for progress indicators
  // Stream<double>? get uploadProgress => null;
}

/// Factory for creating cloud storage provider instances
class CloudStorageFactory {
  static CloudStorageProvider? create(String providerId) {
    switch (providerId) {
      case 'google_drive':
        // This will import your google_drive.dart which can use google_sign_in internally
        return GoogleDriveProvider();
      case 'webdav':
        return WebDAVProvider();
      // Future providers:
      // case 'dropbox':
      //   return DropboxProvider();
      // case 'onedrive':
      //   return OneDriveProvider();
      default:
        return null;
    }
  }
  
  static List<Map<String, String>> getAvailableProviders() {
    return [
      {'id': 'none', 'name': 'None'},
      {'id': 'google_drive', 'name': 'Google Drive'},
      {'id': 'webdav', 'name': 'WebDAV'},
      // Future providers:
      // {'id': 'dropbox', 'name': 'Dropbox'},
      // {'id': 'onedrive', 'name': 'OneDrive'},
    ];
  }
}
