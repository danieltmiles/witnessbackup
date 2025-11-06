import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'cloud_storage_provider.dart';

/// WebDAV implementation of CloudStorageProvider
/// Supports uploading files to WebDAV servers with basic authentication
class WebDAVProvider implements CloudStorageProvider {
  @override
  String get displayName => 'WebDAV';
  
  @override
  String get providerId => 'webdav';
  
  @override
  Future<bool> authenticate(BuildContext context) => WebDAVAuth.authenticate(context);
  
  @override
  Future<bool> isAuthenticated() => WebDAVAuth.isAuthenticated();
  
  @override
  Future<void> signOut() => WebDAVAuth.signOut();
  
  @override
  Future<bool> uploadFile(
    String filePath, 
    String fileName, {
    String? taskId,
    String? existingSessionUri,
    int? startByte,
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  }) => WebDAVAuth.uploadFile(
    filePath, 
    fileName,
    taskId: taskId,
    existingSessionUri: existingSessionUri,
    startByte: startByte,
    onProgress: onProgress,
  );
}

/// Internal implementation class for WebDAV operations
/// This class is not exposed outside this file
class WebDAVAuth {
  // Secure storage instance
  static const _storage = FlutterSecureStorage();

  // Storage keys
  static const String _baseUriKey = 'webdav_base_uri';
  static const String _usernameKey = 'webdav_username';
  static const String _passwordKey = 'webdav_password';
  static const String _isAuthenticatedKey = 'webdav_is_authenticated';
  
  /// Checks if WebDAV is configured and authenticated
  static Future<bool> isAuthenticated() async {
    try {
      final isAuthenticated = await _storage.read(key: _isAuthenticatedKey);
      return isAuthenticated == 'true';
    } catch (e) {
      print('Error checking WebDAV authentication: $e');
      return false;
    }
  }
  
  /// Authenticates with WebDAV server - actually just a configuration dialog
  /// The real authentication happens during validation
  static Future<bool> authenticate(BuildContext context) async {
    // This will be handled through the settings UI
    // Return the current authentication status
    return await isAuthenticated();
  }
  
  /// Signs out by clearing stored credentials
  static Future<void> signOut() async {
    try {
      await _storage.delete(key: _baseUriKey);
      await _storage.delete(key: _usernameKey);
      await _storage.delete(key: _passwordKey);
      await _storage.write(key: _isAuthenticatedKey, value: 'false');
      print('Signed out from WebDAV');
    } catch (e) {
      print('Error signing out from WebDAV: $e');
    }
  }
  
  /// Saves WebDAV configuration
  static Future<void> saveConfiguration(String baseUri, String username, String password) async {
    await _storage.write(key: _baseUriKey, value: baseUri);
    await _storage.write(key: _usernameKey, value: username);
    await _storage.write(key: _passwordKey, value: password);
    await _storage.write(key: _isAuthenticatedKey, value: 'true');
  }
  
  /// Gets stored WebDAV configuration
  static Future<Map<String, String>> getConfiguration() async {
    final baseUri = await _storage.read(key: _baseUriKey) ?? '';
    final username = await _storage.read(key: _usernameKey) ?? '';
    final password = await _storage.read(key: _passwordKey) ?? '';
    return {
      'baseUri': baseUri,
      'username': username,
      'password': password,
    };
  }
  
  /// Validates the WebDAV connection using PROPFIND
  static Future<bool> validateConnection(String baseUri, String username, String password) async {
    try {
      print('Validating WebDAV connection to: $baseUri');
      
      // Ensure the base URI ends with a slash
      final normalizedUri = baseUri.endsWith('/') ? baseUri : '$baseUri/';
      
      // Create basic auth header
      final credentials = base64Encode(utf8.encode('$username:$password'));
      final authHeader = 'Basic $credentials';
      
      // Send PROPFIND request to list directory contents
      final request = http.Request('PROPFIND', Uri.parse(normalizedUri))
        ..headers.addAll({
          'Authorization': authHeader,
          'Depth': '0',
          'Content-Type': 'application/xml',
        })
        ..body = '<?xml version="1.0" encoding="utf-8" ?><propfind xmlns="DAV:"><prop><displayname/></prop></propfind>';
      
      final streamedResponse = await request.send();
      final statusCode = streamedResponse.statusCode;
      
      // Read the response body for debugging
      final responseBody = await streamedResponse.stream.bytesToString();
      
      print('PROPFIND response status: $statusCode');
      print('PROPFIND response body: ${responseBody.substring(0, responseBody.length > 200 ? 200 : responseBody.length)}...');
      
      // 207 Multi-Status is the expected success response for PROPFIND
      // 200 OK is also acceptable for some WebDAV servers
      if (statusCode == 207 || statusCode == 200) {
        print('WebDAV connection validated successfully');
        return true;
      } else if (statusCode == 401) {
        print('WebDAV authentication failed - invalid credentials');
        return false;
      } else if (statusCode == 404) {
        print('WebDAV endpoint not found - invalid URL');
        return false;
      } else {
        print('WebDAV validation failed with unexpected status: $statusCode');
        return false;
      }
    } catch (e, stackTrace) {
      print('Error validating WebDAV connection: $e');
      print('Stack trace: $stackTrace');
      return false;
    }
  }
  
  /// Uploads a file to the WebDAV server using chunked upload
  /// This prevents connection resets for large files
  static Future<bool> uploadFile(
    String filePath, 
    String fileName, {
    String? taskId,
    String? existingSessionUri,
    int? startByte,
    Function(int uploaded, int total, String? sessionUri)? onProgress,
  }) async {
    try {
      final config = await getConfiguration();
      final baseUri = config['baseUri']!;
      final username = config['username']!;
      final password = config['password']!;
      
      if (baseUri.isEmpty || username.isEmpty) {
        print('WebDAV not configured properly');
        return false;
      }
      
      print('Starting chunked upload of $fileName to WebDAV server...');
      
      // Read the file
      final file = File(filePath);
      if (!await file.exists()) {
        print('Error: File does not exist at path: $filePath');
        return false;
      }
      
      final fileSize = await file.length();
      print('File size: $fileSize bytes');
      
      // Use chunked upload for files larger than 5MB
      const chunkSize = 5 * 1024 * 1024; // 5 MB chunks
      
      if (fileSize <= chunkSize) {
        // For small files, use simple upload
        return await _uploadSimple(file, fileName, baseUri, username, password);
      } else {
        // For large files, use chunked upload
        return await _uploadChunked(file, fileName, baseUri, username, password, fileSize, chunkSize);
      }
    } catch (e, stackTrace) {
      print('Error uploading file to WebDAV: $e');
      print('Stack trace: $stackTrace');
      return false;
    }
  }
  
  /// Simple upload for small files
  static Future<bool> _uploadSimple(File file, String fileName, String baseUri, String username, String password) async {
    final fileBytes = await file.readAsBytes();
    
    // Ensure the base URI ends with a slash
    final normalizedUri = baseUri.endsWith('/') ? baseUri : '$baseUri/';
    final uploadUri = Uri.parse('$normalizedUri$fileName');
    
    // Create basic auth header
    final credentials = base64Encode(utf8.encode('$username:$password'));
    final authHeader = 'Basic $credentials';
    
    // Determine MIME type
    final mimeType = _getMimeType(fileName);
    print('MIME type: $mimeType');
    
    print('Uploading file (simple mode)...');
    final response = await http.put(
      uploadUri,
      headers: {
        'Authorization': authHeader,
        'Content-Type': mimeType,
        'Content-Length': fileBytes.length.toString(),
      },
      body: fileBytes,
    );
    
    print('Upload response status: ${response.statusCode}');
    
    if (response.statusCode == 201 || response.statusCode == 204 || response.statusCode == 200) {
      print('Successfully uploaded file to WebDAV server');
      return true;
    } else {
      print('Upload failed with status code: ${response.statusCode}');
      print('Response body: ${response.body}');
      return false;
    }
  }
  
  /// Chunked upload for large files
  static Future<bool> _uploadChunked(File file, String fileName, String baseUri, String username, String password, int fileSize, int chunkSize) async {
    // Ensure the base URI ends with a slash
    final normalizedUri = baseUri.endsWith('/') ? baseUri : '$baseUri/';
    final uploadUri = Uri.parse('$normalizedUri$fileName');
    
    // Create basic auth header
    final credentials = base64Encode(utf8.encode('$username:$password'));
    final authHeader = 'Basic $credentials';
    
    // Determine MIME type
    final mimeType = _getMimeType(fileName);
    print('MIME type: $mimeType');
    print('Using chunked upload with chunk size: ${chunkSize ~/ (1024 * 1024)} MB');
    
    // Open file for reading
    final randomAccessFile = await file.open(mode: FileMode.read);
    
    try {
      int uploadedBytes = 0;
      int chunkNumber = 0;
      
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
        
        // Upload chunk with Content-Range header
        final response = await http.put(
          uploadUri,
          headers: {
            'Authorization': authHeader,
            'Content-Type': mimeType,
            'Content-Range': 'bytes $rangeStart-$rangeEnd/$fileSize',
            'Content-Length': chunk.length.toString(),
          },
          body: chunk,
        );
        
        print('Chunk $chunkNumber response status: ${response.statusCode}');
        
        // Check response
        // 201/204/200 for complete upload, 308 for partial (resume incomplete)
        if (response.statusCode == 201 || response.statusCode == 204 || response.statusCode == 200 || response.statusCode == 308) {
          uploadedBytes += chunk.length;
          
          if (uploadedBytes >= fileSize) {
            print('Successfully uploaded all chunks to WebDAV server');
            return true;
          }
        } else {
          print('Chunk upload failed with status code: ${response.statusCode}');
          print('Response body: ${response.body}');
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
