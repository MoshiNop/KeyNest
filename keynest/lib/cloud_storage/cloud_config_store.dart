import 'dart:convert';
import 'dart:io';

import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/cloud_storage/cloud_storage_helper.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

final _logger = Logger('cloud_config_store');

/// Build-time default OAuth identifiers from --dart-define or --dart-define-from-file.
const String kDefaultGoogleWebClientId = String.fromEnvironment(
  'KEYNEST_GOOGLE_WEB_CLIENT_ID',
  defaultValue: '',
);

const String kDefaultGoogleDesktopClientId = String.fromEnvironment(
  'KEYNEST_GOOGLE_DESKTOP_CLIENT_ID',
  defaultValue: '',
);

const String kDefaultGoogleDesktopClientSecret = String.fromEnvironment(
  'KEYNEST_GOOGLE_DESKTOP_CLIENT_SECRET',
  defaultValue: '',
);

const String kDefaultDropboxAppKey = String.fromEnvironment(
  'KEYNEST_DROPBOX_APP_KEY',
  defaultValue: String.fromEnvironment(
    'DROPBOX_APP_KEY',
    defaultValue: '',
  ),
);

/// Indicates where an active cloud configuration value originates from.
enum CloudConfigSource {
  /// Provided at runtime by user via UI or local cloud_config.json override.
  runtime,

  /// Provided at compile time via --dart-define or --dart-define-from-file.
  buildTime,

  /// Not configured in any source.
  none,
}

/// Persistent store for user-configured non-sensitive cloud settings (e.g. Dropbox App Key, Google Client ID).
/// Sensitive credentials (OAuth tokens, WebDAV passwords) are stored exclusively in platform-backed encrypted storage.
class CloudConfigStore {
  CloudConfigStore._();
  static final CloudConfigStore instance = CloudConfigStore._();

  String? _dropboxAppKey;
  String? _googleWebClientId;
  String? _googleDesktopClientId;
  String? _googleDesktopClientSecret;
  bool _loaded = false;

  Future<void> load({
    File? legacyFileOverride,
    File? configFileOverride,
  }) async {
    if (_loaded && legacyFileOverride == null && configFileOverride == null) {
      return;
    }
    try {
      final File? legacyFile;
      if (legacyFileOverride != null) {
        legacyFile = legacyFileOverride;
      } else if (configFileOverride != null) {
        legacyFile = null;
      } else {
        final appDir = await PathUtils().getAppDataDirectory();
        legacyFile = File('${appDir.path}/cloud_credentials.json');
      }

      final File configFile;
      if (configFileOverride != null) {
        configFile = configFileOverride;
      } else {
        final appDir = await PathUtils().getAppDataDirectory();
        configFile = File('${appDir.path}/cloud_config.json');
      }

      // 1. Detect and migrate any legacy plaintext credentials file
      if (legacyFile != null && legacyFile.existsSync()) {
        if (Env.value != null) {
          final helper = CloudStorageHelper(
            Env.value!,
            PathUtils(),
            Analytics(env: Env.value!),
          );
          await helper.migrateLegacyPlaintextFile(
            legacyFileOverride: legacyFile,
            configFileOverride: configFile,
          );
        } else {
          // If Env.value not yet set, parse legacy non-sensitive config as fallback
          try {
            final content = await legacyFile.readAsString();
            final map = json.decode(content) as Map<String, dynamic>;
            _dropboxAppKey =
                (map['KEYNEST_DROPBOX_APP_KEY'] ?? map['dropboxAppKey'])
                    as String?;
            _googleWebClientId =
                (map['KEYNEST_GOOGLE_WEB_CLIENT_ID'] ??
                        map['googleWebClientId'])
                    as String?;
            _googleDesktopClientId =
                (map['KEYNEST_GOOGLE_DESKTOP_CLIENT_ID'] ??
                        map['googleDesktopClientId'])
                    as String?;
            _googleDesktopClientSecret =
                (map['KEYNEST_GOOGLE_DESKTOP_CLIENT_SECRET'] ??
                        map['googleDesktopClientSecret'])
                    as String?;
          } catch (_) {}
        }
      }

      // 2. Load non-sensitive configuration from cloud_config.json
      if (configFile.existsSync()) {
        final content = configFile.readAsStringSync();
        final map = json.decode(content) as Map<String, dynamic>;
        _dropboxAppKey =
            (map['KEYNEST_DROPBOX_APP_KEY'] ?? map['dropboxAppKey']) as String?;
        _googleWebClientId =
            (map['KEYNEST_GOOGLE_WEB_CLIENT_ID'] ?? map['googleWebClientId'])
                as String?;
        _googleDesktopClientId =
            (map['KEYNEST_GOOGLE_DESKTOP_CLIENT_ID'] ??
                    map['googleDesktopClientId'])
                as String?;
        _googleDesktopClientSecret =
            (map['KEYNEST_GOOGLE_DESKTOP_CLIENT_SECRET'] ??
                    map['googleDesktopClientSecret'])
                as String?;
        _logger.info('Loaded custom cloud configuration from storage.');
      }
    } catch (e, stack) {
      _logger.warning('Failed to load cloud config: $e', e, stack);
    }
    _loaded = true;
  }

  Future<void> save({
    String? dropboxAppKey,
    String? googleWebClientId,
    String? googleDesktopClientId,
    String? googleDesktopClientSecret,
    File? configFileOverride,
  }) async {
    if (dropboxAppKey != null) {
      _dropboxAppKey = dropboxAppKey.trim().isEmpty
          ? null
          : dropboxAppKey.trim();
    }
    if (googleWebClientId != null) {
      _googleWebClientId = googleWebClientId.trim().isEmpty
          ? null
          : googleWebClientId.trim();
    }
    if (googleDesktopClientId != null) {
      _googleDesktopClientId = googleDesktopClientId.trim().isEmpty
          ? null
          : googleDesktopClientId.trim();
    }
    if (googleDesktopClientSecret != null) {
      _googleDesktopClientSecret = googleDesktopClientSecret.trim().isEmpty
          ? null
          : googleDesktopClientSecret.trim();
    }

    await _writeConfigFile(configFileOverride);
    _loaded = true;
  }

  Future<void> _writeConfigFile(File? configFileOverride) async {
    try {
      final File file;
      if (configFileOverride != null) {
        file = configFileOverride;
      } else {
        final appDir = await PathUtils().getAppDataDirectory();
        file = File('${appDir.path}/cloud_config.json');
      }
      final data = <String, dynamic>{};
      if (_dropboxAppKey != null && _dropboxAppKey!.isNotEmpty) {
        data['KEYNEST_DROPBOX_APP_KEY'] = _dropboxAppKey;
        data['dropboxAppKey'] = _dropboxAppKey;
      }
      if (_googleWebClientId != null && _googleWebClientId!.isNotEmpty) {
        data['KEYNEST_GOOGLE_WEB_CLIENT_ID'] = _googleWebClientId;
        data['googleWebClientId'] = _googleWebClientId;
      }
      if (_googleDesktopClientId != null &&
          _googleDesktopClientId!.isNotEmpty) {
        data['KEYNEST_GOOGLE_DESKTOP_CLIENT_ID'] = _googleDesktopClientId;
        data['googleDesktopClientId'] = _googleDesktopClientId;
      }
      if (_googleDesktopClientSecret != null &&
          _googleDesktopClientSecret!.isNotEmpty) {
        data['KEYNEST_GOOGLE_DESKTOP_CLIENT_SECRET'] =
            _googleDesktopClientSecret;
        data['googleDesktopClientSecret'] = _googleDesktopClientSecret;
      }
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(
        json.encode(data),
        flush: true,
      );
      _logger.info('Saved custom cloud configuration to storage.');
    } catch (e, stack) {
      _logger.warning('Failed to save cloud config: $e', e, stack);
    }
  }

  /// Clears user runtime override for Google Web Client ID and persists.
  Future<void> clearGoogleWebClientId({File? configFileOverride}) async {
    _googleWebClientId = null;
    await _writeConfigFile(configFileOverride);
  }

  /// Clears user runtime override for Google Desktop Client ID and persists.
  Future<void> clearGoogleDesktopClientId({File? configFileOverride}) async {
    _googleDesktopClientId = null;
    await _writeConfigFile(configFileOverride);
  }

  /// Clears user runtime override for Dropbox App Key and persists.
  Future<void> clearDropboxAppKey({File? configFileOverride}) async {
    _dropboxAppKey = null;
    await _writeConfigFile(configFileOverride);
  }

  /// Clears all runtime cloud configuration overrides and persists.
  Future<void> clearAll({File? configFileOverride}) async {
    _googleWebClientId = null;
    _googleDesktopClientId = null;
    _googleDesktopClientSecret = null;
    _dropboxAppKey = null;
    await _writeConfigFile(configFileOverride);
  }

  String? get dropboxAppKey => _dropboxAppKey;
  String? get googleWebClientId => _googleWebClientId;
  String? get googleDesktopClientId => _googleDesktopClientId;
  String? get googleDesktopClientSecret => _googleDesktopClientSecret;

  String get effectiveGoogleDesktopClientSecret {
    final runtime = _googleDesktopClientSecret?.trim();
    if (runtime != null && runtime.isNotEmpty) {
      return runtime;
    }
    if (kDefaultGoogleDesktopClientSecret.isNotEmpty) {
      return kDefaultGoogleDesktopClientSecret;
    }
    final secret = Env.value?.secrets?.googleClientSecret;
    if (secret != null && secret.isNotEmpty) {
      return secret;
    }
    return '';
  }

  /// Effective Google Web Client ID with strict precedence:
  /// 1. User runtime override (_googleWebClientId)
  /// 2. Build-time --dart-define (kDefaultGoogleWebClientId)
  /// 3. Environment secrets fallback
  String get effectiveGoogleWebClientId {
    final runtime = _googleWebClientId?.trim();
    if (runtime != null && runtime.isNotEmpty) {
      return runtime;
    }
    if (kDefaultGoogleWebClientId.isNotEmpty) {
      return kDefaultGoogleWebClientId;
    }
    final secret = Env.value?.secrets?.googleClientId?.call();
    if (secret != null && secret.isNotEmpty) {
      return secret;
    }
    return '';
  }

  CloudConfigSource get googleWebClientIdSource {
    final runtime = _googleWebClientId?.trim();
    if (runtime != null && runtime.isNotEmpty) {
      return CloudConfigSource.runtime;
    }
    if (kDefaultGoogleWebClientId.isNotEmpty) {
      return CloudConfigSource.buildTime;
    }
    final secret = Env.value?.secrets?.googleClientId?.call();
    if (secret != null && secret.isNotEmpty) {
      return CloudConfigSource.buildTime;
    }
    return CloudConfigSource.none;
  }

  /// Effective Google Desktop Client ID with strict precedence:
  /// 1. User runtime override (_googleDesktopClientId)
  /// 2. Build-time --dart-define (kDefaultGoogleDesktopClientId)
  /// 3. Fallback to runtime Web Client ID if set
  /// 4. Fallback to build-time Web Client ID
  /// 5. Environment secrets fallback
  String get effectiveGoogleDesktopClientId {
    final runtime = _googleDesktopClientId?.trim();
    if (runtime != null && runtime.isNotEmpty) {
      return runtime;
    }
    if (kDefaultGoogleDesktopClientId.isNotEmpty) {
      return kDefaultGoogleDesktopClientId;
    }
    final runtimeWeb = _googleWebClientId?.trim();
    if (runtimeWeb != null && runtimeWeb.isNotEmpty) {
      return runtimeWeb;
    }
    if (kDefaultGoogleWebClientId.isNotEmpty) {
      return kDefaultGoogleWebClientId;
    }
    final secret = Env.value?.secrets?.googleClientId?.call();
    if (secret != null && secret.isNotEmpty) {
      return secret;
    }
    return '';
  }

  CloudConfigSource get googleDesktopClientIdSource {
    final runtime = _googleDesktopClientId?.trim();
    if (runtime != null && runtime.isNotEmpty) {
      return CloudConfigSource.runtime;
    }
    if (kDefaultGoogleDesktopClientId.isNotEmpty) {
      return CloudConfigSource.buildTime;
    }
    final runtimeWeb = _googleWebClientId?.trim();
    if (runtimeWeb != null && runtimeWeb.isNotEmpty) {
      return CloudConfigSource.runtime;
    }
    if (kDefaultGoogleWebClientId.isNotEmpty) {
      return CloudConfigSource.buildTime;
    }
    final secret = Env.value?.secrets?.googleClientId?.call();
    if (secret != null && secret.isNotEmpty) {
      return CloudConfigSource.buildTime;
    }
    return CloudConfigSource.none;
  }

  /// Effective Dropbox App Key with strict precedence:
  /// 1. User runtime override (_dropboxAppKey)
  /// 2. Build-time --dart-define (kDefaultDropboxAppKey)
  /// 3. Environment secrets fallback
  String get effectiveDropboxAppKey {
    final runtime = _dropboxAppKey?.trim();
    if (runtime != null && runtime.isNotEmpty) {
      return runtime;
    }
    if (kDefaultDropboxAppKey.isNotEmpty) {
      return kDefaultDropboxAppKey;
    }
    final secret = Env.value?.secrets?.dropboxKey;
    if (secret != null && secret.isNotEmpty) {
      return secret;
    }
    return '';
  }

  CloudConfigSource get dropboxAppKeySource {
    final runtime = _dropboxAppKey?.trim();
    if (runtime != null && runtime.isNotEmpty) {
      return CloudConfigSource.runtime;
    }
    if (kDefaultDropboxAppKey.isNotEmpty) {
      return CloudConfigSource.buildTime;
    }
    final secret = Env.value?.secrets?.dropboxKey;
    if (secret != null && secret.isNotEmpty) {
      return CloudConfigSource.buildTime;
    }
    return CloudConfigSource.none;
  }

  /// Validates format of a Google OAuth Client ID
  static String? validateGoogleClientId(String? value, {bool required = true}) {
    if (value == null || value.trim().isEmpty) {
      return required ? 'Google Client ID is required.' : null;
    }
    final trimmed = value.trim();
    if (trimmed.contains('@')) {
      return 'This is an email address, not an OAuth Client ID. Enter the Client ID ending with .apps.googleusercontent.com';
    }
    if (trimmed.startsWith('GOCSPX-')) {
      return 'This is a Client Secret, not a Client ID. Enter the Client ID ending with .apps.googleusercontent.com';
    }
    if (!trimmed.endsWith('.apps.googleusercontent.com')) {
      return 'Client ID must end with ".apps.googleusercontent.com".';
    }
    final hyphenIdx = trimmed.indexOf('-');
    if (hyphenIdx < 8) {
      return 'Invalid Client ID format (must begin with project number e.g. 123456789-abcdef.apps.googleusercontent.com).';
    }
    return null;
  }

  /// Validates format of a Dropbox App Key
  static String? validateDropboxAppKey(String? value, {bool required = true}) {
    if (value == null || value.trim().isEmpty) {
      return required ? 'Dropbox App Key is required.' : null;
    }
    final trimmed = value.trim();
    if (trimmed.length < 3) {
      return 'Dropbox App Key must be at least 3 characters.';
    }
    if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(trimmed)) {
      return 'Dropbox App Key must only contain alphanumeric characters.';
    }
    return null;
  }

  @visibleForTesting
  void resetForTesting() {
    _loaded = false;
    _dropboxAppKey = null;
    _googleWebClientId = null;
    _googleDesktopClientId = null;
    _googleDesktopClientSecret = null;
  }
}
