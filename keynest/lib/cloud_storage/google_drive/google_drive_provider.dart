import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/cloud_storage_ui_adapt.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_auth.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_client.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_engine.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:logging/logging.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('keynest.google_drive_provider');

@NonNls
const _METADATA_KEY_GOOGLE_DRIVE_DATA = 'googledrive.file_metadata';

class GoogleDriveProvider extends CloudStorageProvider
    implements CloudStorageCustomLoginButtonAdapter {
  GoogleDriveProvider({
    required this.env,
    required super.helper,
    this.onAuthChanged,
  }) {
    _initGoogleDriveComponents();
  }

  @NonNls
  @override
  final String id = 'GoogleDriveProvider';

  final Env env;
  final VoidCallback? onAuthChanged;

  late GoogleDriveTokenSource tokenSource;
  late GoogleDriveClient driveClient;
  late GoogleDriveSyncStateStore stateStore;
  late GoogleDriveSyncEngine syncEngine;

  bool isAuthorized = false;

  void _initGoogleDriveComponents() {
    tokenSource = GoogleDriveAuthService.create(
      env: env,
      helper: helper,
    );
    driveClient = GoogleDriveClient(tokenSource: tokenSource);
    stateStore = GoogleDriveSyncStateStore(
      pathUtils: helper.pathUtil is PathUtils
          ? helper.pathUtil as PathUtils
          : PathUtils(),
    );
    syncEngine = GoogleDriveSyncEngine(
      client: driveClient,
      stateStore: stateStore,
    );
  }

  @override
  String get displayName => 'Google Drive';

  @override
  FileSourceIcon get displayIcon => FileSourceIcon.googleDrive;

  @override
  bool get supportSearch => true;

  @override
  bool get isAuthenticated => isAuthorized;

  String? get connectedAccountEmail => tokenSource.currentAccountEmail;
  String? get connectedDisplayName => tokenSource.currentDisplayName;

  /// Resets cached token sources and initialization state when user modifies OAuth client IDs.
  void resetForNewConfiguration() {
    _initGoogleDriveComponents();
  }

  @override
  Future<bool> loadSavedAuth() async {
    isAuthorized = await tokenSource.isSignedIn();
    return isAuthorized;
  }

  @override
  Future<void> logout() async {
    isAuthorized = false;
    try {
      await tokenSource.disconnect();
      await stateStore.clearSyncState();
      await helper.saveCredentials(id, '');
      await helper.saveCredentials('GoogleDriveDesktop', '');
      await helper.saveCredentials('google_drive_desktop_refresh_token', '');
      await helper.saveCredentials('GoogleDriveAccount', '');
    } catch (e) {
      _logger.warning('Error during Google Drive logout: $e');
    }
    onAuthChanged?.call();
  }

  @override
  Future<bool> startAuth<
    RESULT extends UserAuthenticationPromptResult,
    DATA extends UserAuthenticationPromptData<RESULT>
  >(PromptUserForCode<RESULT, DATA> prompt) async {
    try {
      final success = await tokenSource.signIn();
      isAuthorized = success;
      onAuthChanged?.call();
      return isAuthorized;
    } catch (e) {
      _logger.warning('startAuth failed: $e');
      isAuthorized = false;
      onAuthChanged?.call();
      rethrow;
    }
  }

  Future<String> _resolveEffectiveFileId(String originalId) async {
    final migrated = await stateStore.getMigratedFileIdForLegacyId(originalId);
    return migrated ?? originalId;
  }

  @override
  Future<SearchResponse> search({String name = Env.KeePassExtension}) async {
    try {
      final keynestFolderId = await driveClient.getOrCreateKeyNestFolder(
        stateStore: stateStore,
      );
      final files = await driveClient.findFilesInFolder(keynestFolderId, name);

      final results = <CloudStorageEntity>[];
      final seenNames = <String>{};

      for (final f in files) {
        seenNames.add(f.name);
        results.add(
          CloudStorageEntity(
            (b) => b
              ..id = f.id
              ..type = CloudStorageEntityType.file
              ..name = f.name,
          ),
        );
      }

      // Check legacy appDataFolder for any vaults not yet migrated
      try {
        final legacyFiles = await driveClient.findFilesInAppDataFolder(name);
        for (final lf in legacyFiles) {
          if (!seenNames.contains(lf.name)) {
            results.add(
              CloudStorageEntity(
                (b) => b
                  ..id = lf.id
                  ..type = CloudStorageEntityType.file
                  ..name = lf.name,
              ),
            );
          }
        }
      } catch (e) {
        _logger.fine('Legacy appDataFolder search skipped or failed: $e');
      }

      return SearchResponse(
        (srb) => srb
          ..hasMore = false
          ..results.addAll(results),
      );
    } catch (e) {
      _logger.warning('search failed in KeyNest folder: $e');
      return SearchResponse((srb) => srb..hasMore = false);
    }
  }

  @override
  Future<SearchResponse> list({CloudStorageEntity? parent}) async {
    return search();
  }

  @override
  Future<FileContent> loadEntity(CloudStorageEntity file) async {
    final effectiveId = await _resolveEffectiveFileId(file.id);
    final bytes = await driveClient.downloadFile(effectiveId);
    final meta = await driveClient.getFileMetadata(effectiveId);
    return FileContent(
      bytes,
      {
        _METADATA_KEY_GOOGLE_DRIVE_DATA: {
          'id': effectiveId,
          'version': meta?.version,
          'md5Checksum': meta?.md5Checksum,
        },
      },
    );
  }

  @override
  Future<Map<String, dynamic>> saveEntity(
    CloudStorageEntity file,
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async {
    final effectiveId = await _resolveEffectiveFileId(file.id);
    final updated = await driveClient.updateVault(
      fileId: effectiveId,
      bytes: bytes,
    );
    return {
      _METADATA_KEY_GOOGLE_DRIVE_DATA: {
        'id': updated.id,
        'version': updated.version,
        'md5Checksum': updated.md5Checksum,
      },
    };
  }

  @override
  Future<FileSource> createEntity(
    CloudStorageSelectorSaveResult saveAs,
    Uint8List bytes,
  ) async {
    final keynestFolderId = await driveClient.getOrCreateKeyNestFolder(
      stateStore: stateStore,
    );
    final newFile = await driveClient.createInitialVault(
      vaultFilename: saveAs.fileName,
      bytes: bytes,
      folderId: keynestFolderId,
    );
    return toFileSource(
      CloudStorageEntity(
        (b) => b
          ..id = newFile.id
          ..name = newFile.name
          ..type = CloudStorageEntityType.file,
      ),
      uuid: AppDataBloc.createUuid(),
      initialCachedContent: FileContent(
        bytes,
        {
          _METADATA_KEY_GOOGLE_DRIVE_DATA: {
            'id': newFile.id,
            'version': newFile.version,
            'md5Checksum': newFile.md5Checksum,
          },
        },
      ),
    );
  }

  @override
  Widget getCustomLoginWidget({
    required VoidCallback onSuccess,
    required Widget defaultWidget,
  }) {
    return defaultWidget;
  }
}
