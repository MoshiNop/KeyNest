import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keynest/cloud_storage/cloud_config_store.dart';
import 'package:keynest/cloud_storage/cloud_storage_helper.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_provider.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/env/_base.dart';

import 'util/test_util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File configFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('keynest_config_test_');
    configFile = File('${tempDir.path}/cloud_config.json');
    CloudConfigStore.instance.resetForTesting();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('CloudConfigStore Precedence & Persistence', () {
    test(
      'Defaults fall back to build-time constants when no runtime config exists',
      () async {
        await CloudConfigStore.instance.load(configFileOverride: configFile);

        expect(
          CloudConfigStore.instance.effectiveGoogleWebClientId,
          equals(kDefaultGoogleWebClientId),
        );
        expect(
          CloudConfigStore.instance.effectiveGoogleDesktopClientId,
          equals(kDefaultGoogleDesktopClientId),
        );
        expect(
          CloudConfigStore.instance.effectiveDropboxAppKey,
          equals(kDefaultDropboxAppKey),
        );

        final webSource = CloudConfigStore.instance.googleWebClientIdSource;
        final desktopSource =
            CloudConfigStore.instance.googleDesktopClientIdSource;
        final dropboxSource = CloudConfigStore.instance.dropboxAppKeySource;

        expect(
          webSource,
          equals(
            kDefaultGoogleWebClientId.isNotEmpty
                ? CloudConfigSource.buildTime
                : CloudConfigSource.none,
          ),
        );
        expect(
          desktopSource,
          equals(
            kDefaultGoogleDesktopClientId.isNotEmpty
                ? CloudConfigSource.buildTime
                : CloudConfigSource.none,
          ),
        );
        expect(
          dropboxSource,
          equals(
            kDefaultDropboxAppKey.isNotEmpty
                ? CloudConfigSource.buildTime
                : CloudConfigSource.none,
          ),
        );
      },
    );

    test(
      'Runtime overrides take highest precedence over build-time defaults',
      () async {
        const customWebId = '987654321-weboverride.apps.googleusercontent.com';
        const customDesktopId =
            '987654321-desktopoverride.apps.googleusercontent.com';
        const customDropboxKey = 'customAppKey123';

        await CloudConfigStore.instance.save(
          googleWebClientId: customWebId,
          googleDesktopClientId: customDesktopId,
          dropboxAppKey: customDropboxKey,
          configFileOverride: configFile,
        );

        expect(configFile.existsSync(), isTrue);

        // Verify immediate in-memory resolution
        expect(
          CloudConfigStore.instance.effectiveGoogleWebClientId,
          equals(customWebId),
        );
        expect(
          CloudConfigStore.instance.effectiveGoogleDesktopClientId,
          equals(customDesktopId),
        );
        expect(
          CloudConfigStore.instance.effectiveDropboxAppKey,
          equals(customDropboxKey),
        );

        expect(
          CloudConfigStore.instance.googleWebClientIdSource,
          equals(CloudConfigSource.runtime),
        );
        expect(
          CloudConfigStore.instance.googleDesktopClientIdSource,
          equals(CloudConfigSource.runtime),
        );
        expect(
          CloudConfigStore.instance.dropboxAppKeySource,
          equals(CloudConfigSource.runtime),
        );

        // Simulate app restart: reset store and reload from file
        CloudConfigStore.instance.resetForTesting();
        await CloudConfigStore.instance.load(configFileOverride: configFile);

        expect(
          CloudConfigStore.instance.effectiveGoogleWebClientId,
          equals(customWebId),
        );
        expect(
          CloudConfigStore.instance.effectiveGoogleDesktopClientId,
          equals(customDesktopId),
        );
        expect(
          CloudConfigStore.instance.effectiveDropboxAppKey,
          equals(customDropboxKey),
        );
        expect(
          CloudConfigStore.instance.googleWebClientIdSource,
          equals(CloudConfigSource.runtime),
        );
      },
    );

    test(
      'Clearing individual runtime overrides reverts to build-time defaults',
      () async {
        const customWebId = '111-web.apps.googleusercontent.com';
        const customDesktopId = '222-desktop.apps.googleusercontent.com';
        const customDropboxKey = 'myKey999';

        await CloudConfigStore.instance.save(
          googleWebClientId: customWebId,
          googleDesktopClientId: customDesktopId,
          dropboxAppKey: customDropboxKey,
          configFileOverride: configFile,
        );

        // Clear Google Web Client ID
        await CloudConfigStore.instance.clearGoogleWebClientId(
          configFileOverride: configFile,
        );
        expect(
          CloudConfigStore.instance.effectiveGoogleWebClientId,
          equals(kDefaultGoogleWebClientId),
        );
        expect(
          CloudConfigStore.instance.googleWebClientIdSource,
          equals(
            kDefaultGoogleWebClientId.isNotEmpty
                ? CloudConfigSource.buildTime
                : CloudConfigSource.none,
          ),
        );
        // Other fields remain untouched
        expect(
          CloudConfigStore.instance.effectiveGoogleDesktopClientId,
          equals(customDesktopId),
        );
        expect(
          CloudConfigStore.instance.effectiveDropboxAppKey,
          equals(customDropboxKey),
        );

        // Clear Google Desktop Client ID
        await CloudConfigStore.instance.clearGoogleDesktopClientId(
          configFileOverride: configFile,
        );
        expect(
          CloudConfigStore.instance.effectiveGoogleDesktopClientId,
          equals(kDefaultGoogleDesktopClientId),
        );

        // Clear Dropbox App Key
        await CloudConfigStore.instance.clearDropboxAppKey(
          configFileOverride: configFile,
        );
        expect(
          CloudConfigStore.instance.effectiveDropboxAppKey,
          equals(kDefaultDropboxAppKey),
        );

        // File content should now have null / removed fields
        final raw =
            json.decode(await configFile.readAsString())
                as Map<String, dynamic>;
        expect(raw.containsKey('googleWebClientId'), isFalse);
        expect(raw.containsKey('googleDesktopClientId'), isFalse);
        expect(raw.containsKey('dropboxAppKey'), isFalse);
      },
    );

    test('clearAll() clears all stored runtime overrides at once', () async {
      await CloudConfigStore.instance.save(
        googleWebClientId: 'web-id.apps.googleusercontent.com',
        googleDesktopClientId: 'desktop-id.apps.googleusercontent.com',
        dropboxAppKey: 'appKey123',
        configFileOverride: configFile,
      );

      await CloudConfigStore.instance.clearAll(configFileOverride: configFile);

      expect(
        CloudConfigStore.instance.effectiveGoogleWebClientId,
        equals(kDefaultGoogleWebClientId),
      );
      expect(
        CloudConfigStore.instance.effectiveGoogleDesktopClientId,
        equals(kDefaultGoogleDesktopClientId),
      );
      expect(
        CloudConfigStore.instance.effectiveDropboxAppKey,
        equals(kDefaultDropboxAppKey),
      );
    });

    test(
      'Loads KEYNEST_* formatted keys directly from cloud_config.json',
      () async {
        await configFile.writeAsString(
          json.encode({
            'KEYNEST_GOOGLE_WEB_CLIENT_ID':
                'web-env.apps.googleusercontent.com',
            'KEYNEST_GOOGLE_DESKTOP_CLIENT_ID':
                'desktop-env.apps.googleusercontent.com',
            'KEYNEST_DROPBOX_APP_KEY': 'envDropboxKey123',
          }),
        );

        await CloudConfigStore.instance.load(configFileOverride: configFile);

        expect(
          CloudConfigStore.instance.effectiveGoogleWebClientId,
          equals('web-env.apps.googleusercontent.com'),
        );
        expect(
          CloudConfigStore.instance.effectiveGoogleDesktopClientId,
          equals('desktop-env.apps.googleusercontent.com'),
        );
        expect(
          CloudConfigStore.instance.effectiveDropboxAppKey,
          equals('envDropboxKey123'),
        );
        expect(
          CloudConfigStore.instance.googleWebClientIdSource,
          equals(CloudConfigSource.runtime),
        );
      },
    );
  });

  group('OAuth Field Format Validation', () {
    test('validateGoogleClientId validates required flag and format', () {
      // Optional: empty or null is allowed
      expect(
        CloudConfigStore.validateGoogleClientId(null, required: false),
        isNull,
      );
      expect(
        CloudConfigStore.validateGoogleClientId('', required: false),
        isNull,
      );
      expect(
        CloudConfigStore.validateGoogleClientId('   ', required: false),
        isNull,
      );

      // Required: empty produces error
      expect(
        CloudConfigStore.validateGoogleClientId(null, required: true),
        isNotNull,
      );
      expect(
        CloudConfigStore.validateGoogleClientId('', required: true),
        isNotNull,
      );

      // Invalid formats
      expect(
        CloudConfigStore.validateGoogleClientId(
          'invalid_client_id_without_suffix',
        ),
        contains('.apps.googleusercontent.com'),
      );
      expect(
        CloudConfigStore.validateGoogleClientId(
          'nohyphen.apps.googleusercontent.com',
        ),
        contains('Invalid Client ID format'),
      );
      expect(
        CloudConfigStore.validateGoogleClientId(
          'short-.apps.googleusercontent.com',
        ),
        contains('Invalid Client ID format'),
      );
      expect(
        CloudConfigStore.validateGoogleClientId('user@gmail.com'),
        contains('email address'),
      );
      expect(
        CloudConfigStore.validateGoogleClientId('GOCSPX-secretkey123'),
        contains('Client Secret'),
      );

      // Valid format
      expect(
        CloudConfigStore.validateGoogleClientId(
          '123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com',
        ),
        isNull,
      );
    });

    test('validateDropboxAppKey validates required flag and length', () {
      // Optional: empty is allowed
      expect(
        CloudConfigStore.validateDropboxAppKey(null, required: false),
        isNull,
      );
      expect(
        CloudConfigStore.validateDropboxAppKey('', required: false),
        isNull,
      );

      // Required: empty produces error
      expect(
        CloudConfigStore.validateDropboxAppKey(null, required: true),
        isNotNull,
      );
      expect(
        CloudConfigStore.validateDropboxAppKey('', required: true),
        isNotNull,
      );

      // Invalid formats
      expect(
        CloudConfigStore.validateDropboxAppKey('ab'),
        contains('at least 3 characters'),
      );
      expect(
        CloudConfigStore.validateDropboxAppKey('invalid key with spaces'),
        contains('alphanumeric characters'),
      );
      expect(
        CloudConfigStore.validateDropboxAppKey('invalid@key#special!'),
        contains('alphanumeric characters'),
      );

      // Valid format
      expect(CloudConfigStore.validateDropboxAppKey('abc123xyz789'), isNull);
    });
  });

  group('Provider Reinitialization on Configuration Change', () {
    test(
      'GoogleDriveProvider resetForNewConfiguration recreates tokenSource and client',
      () {
        final env = TestEnv(EnvSecrets.nullSecrets);
        final pathUtil = TestPathUtil();
        final analytics = MockAnalytics();
        final helper = CloudStorageHelper(
          env,
          pathUtil,
          analytics,
        );

        final provider = GoogleDriveProvider(
          env: env,
          helper: helper,
        );

        final originalTokenSource = provider.tokenSource;
        final originalDriveClient = provider.driveClient;
        final originalSyncEngine = provider.syncEngine;

        expect(provider.isAuthorized, isFalse);
        expect(provider.isAuthenticated, isFalse);

        // Reset
        provider.resetForNewConfiguration();

        expect(provider.tokenSource, isNot(same(originalTokenSource)));
        expect(provider.driveClient, isNot(same(originalDriveClient)));
        expect(provider.syncEngine, isNot(same(originalSyncEngine)));
      },
    );

    test('DropboxProvider updateConfiguredAppKey reinitializes components', () {
      final env = TestEnv(EnvSecrets.nullSecrets);
      final pathUtil = TestPathUtil();
      final analytics = MockAnalytics();
      final helper = CloudStorageHelper(
        env,
        pathUtil,
        analytics,
      );

      final provider = DropboxProvider(
        env: env,
        helper: helper,
      );

      final originalClient = provider.dropboxClient;
      final originalSyncEngine = provider.syncEngine;

      provider.updateConfiguredAppKey();

      expect(provider.dropboxClient, isNot(same(originalClient)));
      expect(provider.syncEngine, isNot(same(originalSyncEngine)));
    });
  });
}
