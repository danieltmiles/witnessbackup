# Google Drive Setup Guide (using google_sign_in)

This guide will walk you through setting up Google Drive authentication for the WitnessBackup app using the `google_sign_in` package, which simplifies the OAuth process significantly.

## Prerequisites

- Google Cloud Console account
- Android Studio or Xcode (depending on your platform)
- Flutter SDK installed

## Step 1: Create a Google Cloud Project

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Enable the **Google Drive API**:
   - Navigate to "APIs & Services" > "Library"
   - Search for "Google Drive API"
   - Click on it and press "Enable"

## Step 2: Configure OAuth Consent Screen

1. Go to "APIs & Services" > "OAuth consent screen"
2. Select "External" user type (or "Internal" if you're in a Google Workspace organization)
3. Fill in the required information:
   - App name: `WitnessBackup`
   - User support email: Your email
   - Developer contact information: Your email
4. Click "Save and Continue"
5. On the Scopes page, you can skip adding scopes manually (the app requests them at runtime)
6. Add test users if you're in testing mode
7. Complete the consent screen setup

## Step 3: Create OAuth 2.0 Credentials

### For Android:

1. Go to "APIs & Services" > "Credentials"
2. Click "Create Credentials" > "OAuth client ID"
3. Select "Android" as the application type
4. Enter the following:
   - **Name**: `WitnessBackup Android`
   - **Package name**: `org.doodledome.witnessbackup`
   - **SHA-1 certificate fingerprint**: Get this from your Android keystore (see below)

#### Getting SHA-1 Fingerprint:

**For debug builds** (testing in emulator/device):
```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

**For release builds** (production):
```bash
keytool -list -v -keystore /path/to/your-release-key.keystore -alias your-key-alias
```

Copy the SHA-1 fingerprint and paste it into the Google Cloud Console.

5. Click "Create"

**Important**: You do NOT need to copy the Client ID for Android when using `google_sign_in`. The package automatically uses the credentials based on your package name and SHA-1 fingerprint.

### For iOS:

1. Go to "APIs & Services" > "Credentials"
2. Click "Create Credentials" > "OAuth client ID"
3. Select "iOS" as the application type
4. Enter the following:
   - **Name**: `WitnessBackup iOS`
   - **Bundle ID**: Get this from your iOS project (typically `org.doodledome.witnessbackup`)

To find your iOS Bundle ID:
- Open `ios/Runner.xcodeproj` in Xcode
- Select the Runner target
- Look for "Bundle Identifier" under the General tab

5. Click "Create"
6. **Download the configuration** and note the Client ID (you'll need this for iOS)

#### iOS Additional Setup:

Add the Client ID to your `ios/Runner/Info.plist`:

```xml
<key>GIDClientID</key>
<string>YOUR_IOS_CLIENT_ID_HERE.apps.googleusercontent.com</string>
```

Also add the URL scheme (already configured in your project):
```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>com.googleusercontent.apps.YOUR_REVERSED_CLIENT_ID</string>
        </array>
    </dict>
</array>
```

Replace `YOUR_REVERSED_CLIENT_ID` with your iOS client ID in reverse notation (e.g., if your client ID is `123456-abc.apps.googleusercontent.com`, the reversed version would be `com.googleusercontent.apps.123456-abc`).

## Step 4: No Code Changes Required!

With `google_sign_in`, you don't need to manually configure Client IDs in your Dart code! The package automatically:
- Uses your Android package name + SHA-1 to identify your app
- Uses your iOS Bundle ID + configuration in Info.plist

**The code is already set up and ready to use!**

## Step 5: Testing the Authentication Flow

### Android Testing:

1. Make sure you've registered your debug keystore's SHA-1 in Google Cloud Console
2. Build and run the app on an emulator or device with Google Play Services
3. Navigate to Settings > Cloud Storage
4. Select "Google Drive"
5. You'll see Google's sign-in screen
6. Sign in with your Google account
7. Grant permissions when prompted

### iOS Testing:

1. Make sure you've added the Client ID to Info.plist
2. Build and run the app on a simulator or device
3. Navigate to Settings > Cloud Storage
4. Select "Google Drive"
5. Sign in with your Google account
6. Grant permissions when prompted

## Troubleshooting

### Android Issues:

**"Developer Error" or "Sign-in failed"**
- Verify your package name is correct: `org.doodledome.witnessbackup`
- Verify you've registered the correct SHA-1 fingerprint
- For debug builds, make sure you're using the debug keystore's SHA-1
- Wait a few minutes after creating credentials (Google needs time to propagate changes)

**"Google Play Services not available"**
- The emulator must have Google Play Services installed
- Use an emulator image with "Google APIs" or "Google Play"
- On physical devices, ensure Google Play Services is up to date

### iOS Issues:

**"Sign-in failed" or redirect doesn't work**
- Verify the Client ID in Info.plist is correct
- Verify the reversed client ID URL scheme is correct
- Check that CFBundleURLTypes is properly configured

### General Issues:

**"Access Denied" or scope errors**
- Make sure Google Drive API is enabled in your Cloud Console project
- The app requests the drive.file scope, which allows access to files created by the app
- You may need to go through the OAuth consent screen verification if deploying publicly

**Silent sign-in fails**
- This is normal for first-time users
- The app will fall back to interactive sign-in
- After first successful sign-in, silent sign-in should work

## Advantages of google_sign_in

✅ **Simpler setup**: No need to manage client secrets or implement PKCE
✅ **Automatic token refresh**: The package handles token expiration
✅ **Platform integration**: Uses native sign-in flows on Android/iOS
✅ **Secure**: Follows Google's best practices for mobile OAuth
✅ **No redirect URI configuration**: Works without custom URL schemes for OAuth

## Security Considerations

1. **SHA-1 Security**: Keep your release keystore secure and never commit it to version control
2. **OAuth Scope**: The app only requests `drive.file` scope, limiting access to files it creates
3. **Token Storage**: google_sign_in handles secure token storage automatically
4. **Consent Screen**: Users see exactly what permissions they're granting

## Next Steps

After completing the setup, the next phase will be:
1. Implementing the actual file upload functionality in `GoogleDriveAuth.uploadFile()`
2. Adding background task support for uploads after recording stops
3. Implementing retry logic for failed uploads
4. Adding upload progress indicators
5. Testing with real video files

## References

- [google_sign_in package documentation](https://pub.dev/packages/google_sign_in)
- [Google Drive API Documentation](https://developers.google.com/drive/api/guides/about-sdk)
- [Google Sign-In for Android](https://developers.google.com/identity/sign-in/android/start)
- [Google Sign-In for iOS](https://developers.google.com/identity/sign-in/ios/start)
