import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart' as custom_tabs;
import 'dart:async';
import 'dropbox.dart' show DropboxAuth;
import 'video_recorder.dart';

class WitnessBackupApp extends StatefulWidget {
  final List<CameraDescription> cameras;

  const WitnessBackupApp({super.key, required this.cameras});

  @override
  State<WitnessBackupApp> createState() => _WitnessBackupAppState();
}

class _WitnessBackupAppState extends State<WitnessBackupApp> {
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

  void _handleDeepLink(Uri uri) async {
    print('Received deep link: ${uri.toString()}');

    try {
      // Check if this is a Dropbox OAuth callback
      if (uri.scheme == 'org.doodledome.witnessbackup' && uri.host == 'oauth-callback') {
        // Close the Chrome Custom Tab / Safari View Controller
        try {
          await custom_tabs.closeCustomTabs();
          print('Closed Custom Tab browser');
        } catch (e) {
          print('Error closing Custom Tab: $e');
        }
        
        final context = _navigatorKey.currentContext;
        if (context != null) {
          await DropboxAuth.handleOAuthCallback(uri, context);
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
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
      home: VideoRecorder(cameras: widget.cameras),
    );
  }
}
