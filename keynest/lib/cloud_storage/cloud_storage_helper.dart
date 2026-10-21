import 'dart:convert';
import 'dart:io';

import 'package:biometric_storage/biometric_storage.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/utils/path_util.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('cloud_storage_helper');

/// Common functionality shared across all cloud storages,
/// storing cloud credentials securely using platform encrypted storage.
class CloudStorageHelper implements CloudStorageHelperBase {
  CloudStorageHelper(
    this.env,
    this.pathUtil,
    this.analytics, {
    BiometricStorageFile? storageFile,
  }) : _storageFile = storageFile;

  final Env env;
  @override
  final PathUtil pathUtil;
  @override
  final Analytics analytics;
  BiometricStorageFile? _storageFile;
  bool _migrationAttempted = false;

  bool get _useDesktopFileStorage =>
      _storageFile == null &&
      (KeyNestPlatform.isWindows || KeyNestPlatform.isLinux);

  Future<File> _getDesktopStorageFile() async {
    final appDir = await PathUtils().getAppDataDirectory();
    return File('${appDir.path}/cloud_credentials.json');
  }

  Future<BiometricStorageFile> _getStorageFile() async =>
      _storageFile ??= await BiometricStorage().getStorage(
        nonNls('${env.storageNamespace ?? ''}CloudProviderCreds'),
        options: StorageFileInitOptions(authenticationRequired: false),
      );

  Future<Map<String, dynamic>> _readDataMap() async {
    if (!_useDesktopFileStorage) {
      final file = await _getStorageFile();
      final data = await file.read();
      if (data != null && data.trim().isNotEmpty) {
        try {
          return json.decode(data) as Map<String, dynamic>;
        } catch (e) {
          _logger.warning(
            'Failed to parse credentials data from secure storage: $e',
          );
          return <String, dynamic>{};
        }
      }
      return <String, dynamic>{};
    } else {
      final file = await _getDesktopStorageFile();
      if (file.existsSync()) {
        try {
          final content = await file.readAsString();
          if (content.trim().isNotEmpty) {
            final decoded = json.decode(content);
            if (decoded is Map<String, dynamic>) {
              return decoded;
            }
          }
        } catch (e) {
          _logger.warning('Failed to parse desktop cloud credentials: $e');
        }
      }
      return <String, dynamic>{};
    }
  }

  Future<void> _writeDataMap(Map<String, dynamic> dataMap) async {
    if (!_useDesktopFileStorage) {
      final file = await _getStorageFile();
      await file.write(json.encode(dataMap));
    } else {
      final file = await _getDesktopStorageFile();
      if (!file.parent.existsSync()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(json.encode(dataMap), flush: true);
    }
  }

  /// Migrates any legacy plaintext configuration file containing credentials
  /// into platform-backed encrypted secure storage.
  /// Verifies secure write succeeds before deleting the plaintext file.
  /// Safe to retry after interruption.
  Future<void> migrateLegacyPlaintextFile({
    File? legacyFileOverride,
    File? configFileOverride,
  }) async {
    if (_useDesktopFileStorage && legacyFileOverride == null) {
      // BiometricStorage is not supported on Windows/desktop.
      // Credentials remain in desktop storage.
      return;
    }
    try {
      File legacyFile;
      File configFile;
      if (legacyFileOverride != null) {
        legacyFile = legacyFileOverride;
      } else {
        final appDir = await PathUtils().getAppDataDirectory();
        legacyFile = File('${appDir.path}/cloud_credentials.json');
      }

      if (!legacyFile.existsSync()) {
        return;
      }

      if (configFileOverride != null) {
        configFile = configFileOverride;
      } else {
        final appDir = await PathUtils().getAppDataDirectory();
        configFile = File('${appDir.path}/cloud_config.json');
      }

      final content = await legacyFile.readAsString();
      if (content.trim().isEmpty) {
        await legacyFile.delete();
        return;
      }

      Map<String, dynamic> legacyMap;
      try {
        final decoded = json.decode(content);
        if (decoded is! Map<String, dynamic>) {
          _logger.warning(
            'Legacy cloud credentials file has unexpected structure; skipping delete.',
          );
          return;
        }
        legacyMap = decoded;
      } catch (e) {
        _logger.warning(
          'Failed to parse legacy cloud credentials JSON; preserving file.',
        );
        return;
      }

      final sensitiveKeysToMigrate = <String, String>{};
      final nonSensitiveConfig = <String, dynamic>{};

      const nonSensitiveKeys = {
        'dropboxAppKey',
        'googleWebClientId',
        'googleDesktopClientId',
      };

      for (final entry in legacyMap.entries) {
        final key = entry.key;
        final value = entry.value;
        if (value == null) {
          continue;
        }

        if (nonSensitiveKeys.contains(key)) {
          nonSensitiveConfig[key] = value;
          continue;
        }

        // Provider credential mappings
        if (key == 'dropbox' ||
            key == 'dropboxRefreshToken' ||
            key == 'dropbox_refresh_token') {
          sensitiveKeysToMigrate['dropbox'] = value is String
              ? value
              : json.encode(value);
        } else if (key == 'webdav' ||
            key == 'webdavPassword' ||
            key == 'webdav_password') {
          String strVal;
          if (value is Map) {
            strVal = json.encode(value);
          } else if (value is String) {
            try {
              final parsed = json.decode(value);
              strVal = parsed is Map ? value : json.encode({'password': value});
            } catch (_) {
              strVal = json.encode({'password': value});
            }
          } else {
            strVal = value.toString();
          }
          sensitiveKeysToMigrate['webdav'] = strVal;
        } else if (key == 'GoogleDriveDesktop' ||
            key == 'google_drive' ||
            key == 'googleRefreshToken' ||
            key == 'google_refresh_token') {
          sensitiveKeysToMigrate['GoogleDriveDesktop'] = value is String
              ? value
              : json.encode(value);
        } else if (key == 'onedrive' ||
            key == 'onedriveRefreshToken' ||
            key == 'onedrive_refresh_token') {
          sensitiveKeysToMigrate['onedrive'] = value is String
              ? value
              : json.encode(value);
        } else {
          final lower = key.toLowerCase();
          if (lower.contains('token') ||
              lower.contains('password') ||
              lower.contains('secret') ||
              lower.contains('cred')) {
            sensitiveKeysToMigrate[key] = value is String
                ? value
                : json.encode(value);
          } else {
            nonSensitiveConfig[key] = value;
          }
        }
      }

      if (sensitiveKeysToMigrate.isNotEmpty) {
        final secureMap = await _readDataMap();
        for (final item in sensitiveKeysToMigrate.entries) {
          secureMap.putIfAbsent(item.key, () => item.value);
        }
        await _writeDataMap(secureMap);

        // Verification step: read back to ensure secure write succeeded
        final verifiedMap = await _readDataMap();
        var allVerified = true;
        for (final item in sensitiveKeysToMigrate.entries) {
          final saved = verifiedMap[item.key];
          if (saved == null || (saved is String && saved.trim().isEmpty)) {
            allVerified = false;
            break;
          }
        }

        if (!allVerified) {
          _logger.warning(
            'Failed to verify migrated credentials in secure storage. Preserving legacy file.',
          );
          return;
        }
      }

      // Preserve non-sensitive configuration in ordinary cloud_config.json
      if (nonSensitiveConfig.isNotEmpty) {
        Map<String, dynamic> existingConfig = {};
        if (configFile.existsSync()) {
          try {
            final c = await configFile.readAsString();
            final d = json.decode(c);
            if (d is Map<String, dynamic>) {
              existingConfig = d;
            }
          } catch (_) {}
        }
        existingConfig.addAll(nonSensitiveConfig);
        await configFile.writeAsString(
          json.encode(existingConfig),
          flush: true,
        );
      }

      // Only delete legacy plaintext file after secure write has succeeded and verified
      await legacyFile.delete();
      _logger.info(
        'Legacy cloud credentials successfully migrated to secure storage and plaintext file removed.',
      );
    } catch (e, stack) {
      _logger.warning(
        'Failed to migrate cloud credentials; preserving legacy file: $e',
        e,
        stack,
      );
    }
  }

  @override
  Future<String?> loadCredentials(String cloudStorageId) async {
    if (!_migrationAttempted) {
      _migrationAttempted = true;
      await migrateLegacyPlaintextFile();
    }
    final dataMap = await _readDataMap();
    var val = dataMap[cloudStorageId] as String?;
    if (val != null && val.trim().isNotEmpty) {
      return val;
    }
    if (cloudStorageId == 'DropboxProvider') {
      val = dataMap['dropbox'] as String? ??
          dataMap['dropboxRefreshToken'] as String?;
    } else if (cloudStorageId == 'GoogleDriveDesktop') {
      val = dataMap['google_drive'] as String? ??
          dataMap['googleRefreshToken'] as String?;
    } else if (cloudStorageId == 'WebDavProvider') {
      val = dataMap['webdav'] as String?;
    }
    if (val == null || val.trim().isEmpty) {
      return null;
    }
    return val;
  }

  @override
  Future<void> saveCredentials(String cloudStorageId, String data) async {
    final dataMap = await _readDataMap();
    if (data.trim().isEmpty) {
      dataMap.remove(cloudStorageId);
      if (cloudStorageId == 'DropboxProvider') {
        dataMap.remove('dropbox');
        dataMap.remove('dropboxRefreshToken');
        dataMap.remove('dropbox_refresh_token');
      } else if (cloudStorageId == 'GoogleDriveDesktop') {
        dataMap.remove('google_drive');
        dataMap.remove('googleRefreshToken');
        dataMap.remove('google_refresh_token');
      } else if (cloudStorageId == 'WebDavProvider') {
        dataMap.remove('webdav');
        dataMap.remove('webdavPassword');
        dataMap.remove('webdav_password');
      }
    } else {
      dataMap[cloudStorageId] = data;
    }
    await _writeDataMap(dataMap);
  }
}
