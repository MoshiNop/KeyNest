import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:keynest/cloud_storage/cloud_config_store.dart';
import 'package:keynest/cloud_storage/cloud_storage_helper.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_auth.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/screens/keynest_cloud_vault_browser_screen.dart';
import 'package:keynest/utils/path_utils.dart';

import 'util/test_util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File configFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('keynest_desktop_cloud_test_');
    configFile = File('${tempDir.path}/cloud_config.json');
    CloudConfigStore.instance.resetForTesting();
    try {
      final appDir = await PathUtils().getAppDataDirectory();
      final credsFile = File('${appDir.path}/cloud_credentials.json');
      if (credsFile.existsSync()) {
        await credsFile.delete();
      }
    } catch (_) {}
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
      final appDir = await PathUtils().getAppDataDirectory();
      final credsFile = File('${appDir.path}/cloud_credentials.json');
      if (credsFile.existsSync()) {
        await credsFile.delete();
      }
    } catch (_) {}
  });

  group('Desktop Cloud Storage Helper', () {
    test('Stores and retrieves Dropbox and Google Drive credentials on desktop without biometric_storage', () async {
      final env = TestEnv(EnvSecrets.nullSecrets);
      final pathUtil = TestPathUtil();
      final analytics = MockAnalytics();

      final helper = CloudStorageHelper(
        env,
        pathUtil,
        analytics,
      );

      // Save Dropbox credentials
      const dropboxCreds = '{"access_token":"test_token","refresh_token":"test_refresh"}';
      await helper.saveCredentials('DropboxProvider', dropboxCreds);

      // Save Google Drive Desktop credentials
      const gdriveCreds = '{"google_drive_desktop_refresh_token":"test_gdrive_refresh","email":"test@example.com"}';
      await helper.saveCredentials('GoogleDriveDesktop', gdriveCreds);

      // Retrieve them back
      final loadedDropbox = await helper.loadCredentials('DropboxProvider');
      expect(loadedDropbox, equals(dropboxCreds));

      final loadedGdrive = await helper.loadCredentials('GoogleDriveDesktop');
      expect(loadedGdrive, equals(gdriveCreds));

      // Overwrite / Clear
      await helper.saveCredentials('DropboxProvider', '');
      final clearedDropbox = await helper.loadCredentials('DropboxProvider');
      expect(clearedDropbox, isNull);

      // Google Drive remains intact
      final persistentGdrive = await helper.loadCredentials('GoogleDriveDesktop');
      expect(persistentGdrive, equals(gdriveCreds));
    });

    test('Loads legacy key aliases for backwards compatibility', () async {
      final env = TestEnv(EnvSecrets.nullSecrets);
      final pathUtil = TestPathUtil();
      final analytics = MockAnalytics();

      final helper = CloudStorageHelper(
        env,
        pathUtil,
        analytics,
      );

      // Directly write legacy key aliases into desktop credentials file
      final appDir = await PathUtils().getAppDataDirectory();
      final credsFile = File('${appDir.path}/cloud_credentials.json');
      await credsFile.parent.create(recursive: true);
      await credsFile.writeAsString(json.encode({
        'dropbox': 'legacy_dropbox_token',
        'google_drive': 'legacy_gdrive_token',
        'webdav': '{"password":"secret_pass"}',
      }));

      expect(await helper.loadCredentials('DropboxProvider'), equals('legacy_dropbox_token'));
      expect(await helper.loadCredentials('GoogleDriveDesktop'), equals('legacy_gdrive_token'));
      expect(await helper.loadCredentials('WebDavProvider'), equals('{"password":"secret_pass"}'));
    });
  });

  group('Google Desktop PKCE Client Secret Exchange', () {
    test('Token exchange includes client_secret and passes desktop OAuth validation', () async {
      Map<String, String>? capturedBody;

      final mockHttpClient = MockClient((request) async {
        if (request.url.toString() == 'https://oauth2.googleapis.com/token') {
          capturedBody = request.bodyFields;
          return http.Response(
            json.encode({
              'access_token': 'mock_access_token_123',
              'refresh_token': 'mock_refresh_token_456',
              'expires_in': 3600,
              'token_type': 'Bearer',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      await CloudConfigStore.instance.save(
        googleDesktopClientId: '123456789-desktop.apps.googleusercontent.com',
        googleDesktopClientSecret: 'GOCSPX-mockDesktopSecret123',
        configFileOverride: configFile,
      );

      final env = TestEnv(EnvSecrets.nullSecrets);
      final pathUtil = TestPathUtil();
      final analytics = MockAnalytics();
      final helper = CloudStorageHelper(env, pathUtil, analytics);

      final source = PkceDesktopGoogleTokenSource(
        env: env,
        helper: helper,
        httpClient: mockHttpClient,
      );

      // Verify effective secret is present
      expect(
        CloudConfigStore.instance.effectiveGoogleDesktopClientSecret,
        equals('GOCSPX-mockDesktopSecret123'),
      );

      // Simulate token refresh
      final tokens = await source.getAccessToken();
      expect(tokens, isNull); // no stored token yet

      // Save a stored refresh token
      await helper.saveCredentials(
        'GoogleDriveDesktop',
        json.encode({
          'google_drive_desktop_refresh_token': 'refresh_abc',
        }),
      );

      final refreshedToken = await source.getAccessToken(forceRefresh: true);
      expect(refreshedToken, equals('mock_access_token_123'));
      expect(capturedBody, isNotNull);
      expect(capturedBody!['grant_type'], equals('refresh_token'));
      expect(capturedBody!['client_id'], equals('123456789-desktop.apps.googleusercontent.com'));
      expect(capturedBody!['client_secret'], equals('GOCSPX-mockDesktopSecret123'));
      expect(capturedBody!['refresh_token'], equals('refresh_abc'));
    });
  });

  group('Cloud Vault Browser Route Adaptivity', () {
    test('Returns KeyNestDesktopDialogRoute on desktop/web without full window expansion', () {
      final env = TestEnv(EnvSecrets.nullSecrets);
      final pathUtil = TestPathUtil();
      final analytics = MockAnalytics();
      final helper = CloudStorageHelper(env, pathUtil, analytics);
      final provider = GoogleDriveProvider(env: env, helper: helper);

      final route = KeyNestCloudVaultBrowserScreen.route(provider);
      expect(route, isA<KeyNestDesktopDialogRoute<void>>());
    });
  });
}
