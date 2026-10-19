import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_merge_engine.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_client.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

final _logger = Logger('gdrive_sync_engine');

enum GoogleDriveSyncStatus {
  upToDate,
  uploaded,
  downloaded,
  merged,
  migrated,
  conflict,
  offline,
  error,
}

class GoogleDriveSyncResult {
  GoogleDriveSyncResult({
    required this.status,
    this.message,
    this.fileId,
    this.md5Checksum,
    this.version,
    this.mergeResult,
  });

  factory GoogleDriveSyncResult.upToDate(String? fileId, String? md5) =>
      GoogleDriveSyncResult(
        status: GoogleDriveSyncStatus.upToDate,
        message: 'Google Drive vault is up to date.',
        fileId: fileId,
        md5Checksum: md5,
      );

  factory GoogleDriveSyncResult.uploaded(
    String? fileId,
    String? md5,
    int? version,
  ) => GoogleDriveSyncResult(
    status: GoogleDriveSyncStatus.uploaded,
    message: 'Uploaded vault to Google Drive.',
    fileId: fileId,
    md5Checksum: md5,
    version: version,
  );

  factory GoogleDriveSyncResult.downloaded(
    String? fileId,
    String? md5,
    int? version,
  ) => GoogleDriveSyncResult(
    status: GoogleDriveSyncStatus.downloaded,
    message: 'Downloaded latest vault from Google Drive.',
    fileId: fileId,
    md5Checksum: md5,
    version: version,
  );

  factory GoogleDriveSyncResult.merged({
    required DropboxMergeResult mergeResult,
    required String? fileId,
    required String? md5,
    required int? version,
  }) => GoogleDriveSyncResult(
    status: GoogleDriveSyncStatus.merged,
    message: 'Merged: ${mergeResult.summary}',
    fileId: fileId,
    md5Checksum: md5,
    version: version,
    mergeResult: mergeResult,
  );

  factory GoogleDriveSyncResult.migrated({
    required String fileId,
    required String? md5,
    required int? version,
    String? message,
  }) => GoogleDriveSyncResult(
    status: GoogleDriveSyncStatus.migrated,
    message:
        message ?? 'Migrated vault to visible KeyNest folder on Google Drive.',
    fileId: fileId,
    md5Checksum: md5,
    version: version,
  );

  factory GoogleDriveSyncResult.conflict(String msg) => GoogleDriveSyncResult(
    status: GoogleDriveSyncStatus.conflict,
    message: msg,
  );

  factory GoogleDriveSyncResult.offline(String msg) => GoogleDriveSyncResult(
    status: GoogleDriveSyncStatus.offline,
    message: msg,
  );

  factory GoogleDriveSyncResult.error(String msg) => GoogleDriveSyncResult(
    status: GoogleDriveSyncStatus.error,
    message: msg,
  );

  final GoogleDriveSyncStatus status;
  final String? message;
  final String? fileId;
  final String? md5Checksum;
  final int? version;
  final DropboxMergeResult? mergeResult;
}

/// Synchronization engine for Google Drive AppData Folder.
class GoogleDriveSyncEngine {
  GoogleDriveSyncEngine({
    required this.client,
    required this.stateStore,
  });

  final GoogleDriveClient client;
  final GoogleDriveSyncStateStore stateStore;

  // Single-flight lock per vault to serialize sync operations
  final Map<String, Lock> _vaultLocks = {};

  Lock _getLockForVault(String vaultId) =>
      _vaultLocks.putIfAbsent(vaultId, () => Lock());

  /// Validates KDBX signature and header bytes.
  static bool isValidKdbxBytes(Uint8List bytes) {
    if (bytes.length < 8) {
      return false;
    }
    final bdata = ByteData.sublistView(bytes);
    final sig1 = bdata.getUint32(0, Endian.little);
    final sig2 = bdata.getUint32(4, Endian.little);
    return sig1 == 0x9AA2D903 && (sig2 == 0xB54BFB67 || sig2 == 0xB54BFB66);
  }

  /// Synchronizes the vault file according to the decision table and mitigations.
  Future<GoogleDriveSyncResult> syncVault({
    required String vaultId,
    required String vaultFilename,
    required Future<Uint8List> Function() getLocalBytes,
    required Future<void> Function(Uint8List bytes) saveLocalBytes,
    KdbxFile? unlockedLocalFile,
    Credentials? credentials,
  }) async {
    final lock = _getLockForVault(vaultId);
    return await lock.synchronized(() async {
      return await _syncVaultInternal(
        vaultId: vaultId,
        vaultFilename: vaultFilename,
        getLocalBytes: getLocalBytes,
        saveLocalBytes: saveLocalBytes,
        unlockedLocalFile: unlockedLocalFile,
        credentials: credentials,
      );
    });
  }

  static String ensureKdbxExtension(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'vault.kdbx';
    }
    if (trimmed.toLowerCase().endsWith('.kdbx')) {
      return trimmed;
    }
    return '$trimmed.kdbx';
  }

  Future<GoogleDriveSyncResult> _syncVaultInternal({
    required String vaultId,
    required String vaultFilename,
    required Future<Uint8List> Function() getLocalBytes,
    required Future<void> Function(Uint8List bytes) saveLocalBytes,
    KdbxFile? unlockedLocalFile,
    Credentials? credentials,
  }) async {
    final effectiveFilename = ensureKdbxExtension(vaultFilename);
    try {
      String keynestFolderId;
      try {
        keynestFolderId = await client.getOrCreateKeyNestFolder(
          stateStore: stateStore,
        );
      } on SocketException {
        return GoogleDriveSyncResult.offline(
          'Offline: no connection to Google Drive.',
        );
      } catch (e) {
        _logger.warning('Error resolving KeyNest visible folder: $e');
        return GoogleDriveSyncResult.error(
          'Google Drive folder resolution error: $e',
        );
      }

      final isMigrated = await stateStore.isVaultMigrated(vaultId);
      String? storedFileId = await stateStore.getDriveFileId(vaultId);
      GoogleDriveFileMetadata? remoteMeta;

      try {
        if (isMigrated) {
          if (storedFileId != null) {
            remoteMeta = await client.getFileMetadata(storedFileId);
            if (remoteMeta == null || remoteMeta.trashed == true) {
              _logger.warning(
                'Stored file ID $storedFileId missing or trashed in KeyNest folder. Searching...',
              );
              storedFileId = null;
              remoteMeta = null;
            } else if (!remoteMeta.name.toLowerCase().endsWith('.kdbx')) {
              try {
                remoteMeta = await client.renameFile(
                  fileId: remoteMeta.id,
                  newName: effectiveFilename,
                );
                _logger.info(
                  'Renamed remote vault file ${remoteMeta.id} to $effectiveFilename',
                );
              } catch (e) {
                _logger.warning('Failed to rename remote vault file to include .kdbx: $e');
              }
            }
          }

          if (storedFileId == null) {
            final foundFiles = await client.findFilesInFolder(
              keynestFolderId,
              effectiveFilename,
            );

            // Filter out files that already belong to a different registered local vault
            final availableFiles = <GoogleDriveFileMetadata>[];
            for (final f in foundFiles) {
              final owner = await stateStore.findVaultIdByDriveFileId(f.id);
              if (owner == null || owner == stateStore.sanitizeVaultId(vaultId)) {
                availableFiles.add(f);
              } else {
                _logger.warning(
                  'Remote file "${f.name}" (${f.id}) is mapped to another vault ($owner). Not adopting for $vaultId.',
                );
              }
            }

            if (availableFiles.isEmpty) {
              final bareName = effectiveFilename.substring(
                0,
                effectiveFilename.length - 5,
              );
              final legacyFiles = await client.findFilesInFolder(
                keynestFolderId,
                bareName,
              );
              for (final legacyFile in legacyFiles) {
                final owner = await stateStore.findVaultIdByDriveFileId(legacyFile.id);
                if (owner == null || owner == stateStore.sanitizeVaultId(vaultId)) {
                  try {
                    final renamed = await client.renameFile(
                      fileId: legacyFile.id,
                      newName: effectiveFilename,
                    );
                    availableFiles.add(renamed);
                  } catch (_) {
                    availableFiles.add(legacyFile);
                  }
                  break;
                }
              }
            }

            if (availableFiles.isNotEmpty) {
              remoteMeta = availableFiles.first;
              storedFileId = remoteMeta.id;
              await stateStore.setDriveFileId(vaultId, storedFileId);

              if (availableFiles.length > 1) {
                _logger.warning(
                  'Anomaly: Multiple Drive files (${availableFiles.length}) matched "$effectiveFilename" in KeyNest folder. Using newest (${remoteMeta.id}).',
                );
              }
            }
          }
        } else {
          // Vault not yet marked as migrated.
          // 1. Check if it already exists in the visible KeyNest folder (e.g. from previous run or another device)
          final visibleFiles = await client.findFilesInFolder(
            keynestFolderId,
            effectiveFilename,
          );

          // Filter out files that already belong to a different registered local vault
          final availableFiles = <GoogleDriveFileMetadata>[];
          for (final f in visibleFiles) {
            final owner = await stateStore.findVaultIdByDriveFileId(f.id);
            if (owner == null || owner == stateStore.sanitizeVaultId(vaultId)) {
              availableFiles.add(f);
            } else {
              _logger.warning(
                'Remote file "${f.name}" (${f.id}) is mapped to another vault ($owner). Not adopting for $vaultId.',
              );
            }
          }

          if (availableFiles.isEmpty) {
            final bareName = effectiveFilename.substring(
              0,
              effectiveFilename.length - 5,
            );
            final legacyFiles = await client.findFilesInFolder(
              keynestFolderId,
              bareName,
            );
            for (final legacyFile in legacyFiles) {
              final owner = await stateStore.findVaultIdByDriveFileId(legacyFile.id);
              if (owner == null || owner == stateStore.sanitizeVaultId(vaultId)) {
                try {
                  final renamed = await client.renameFile(
                    fileId: legacyFile.id,
                    newName: effectiveFilename,
                  );
                  availableFiles.add(renamed);
                } catch (_) {
                  availableFiles.add(legacyFile);
                }
                break;
              }
            }
          }

          if (availableFiles.isNotEmpty) {
            remoteMeta = availableFiles.first;
            storedFileId = remoteMeta.id;
            await stateStore.setDriveFileId(vaultId, storedFileId);
            await stateStore.setVaultMigrated(vaultId, true);
          } else {
            // 2. Check if legacy vault exists in appDataFolder
            GoogleDriveFileMetadata? legacyMeta;
            if (storedFileId != null) {
              try {
                legacyMeta = await client.getFileMetadata(storedFileId);
              } catch (_) {}
            }
            if (legacyMeta == null) {
              try {
                final appDataFiles = await client.findFilesInAppDataFolder(
                  effectiveFilename,
                );
                if (appDataFiles.isNotEmpty) {
                  legacyMeta = appDataFiles.first;
                } else {
                  final bareName = effectiveFilename.substring(
                    0,
                    effectiveFilename.length - 5,
                  );
                  final bareAppDataFiles = await client.findFilesInAppDataFolder(
                    bareName,
                  );
                  if (bareAppDataFiles.isNotEmpty) {
                    legacyMeta = bareAppDataFiles.first;
                  }
                }
              } catch (_) {}
            }

            if (legacyMeta != null) {
              // Execute safe migration from appDataFolder to KeyNest visible folder
              return await _migrateLegacyVaultToVisibleFolder(
                vaultId: vaultId,
                vaultFilename: effectiveFilename,
                legacyMeta: legacyMeta,
                keynestFolderId: keynestFolderId,
                getLocalBytes: getLocalBytes,
                saveLocalBytes: saveLocalBytes,
                unlockedLocalFile: unlockedLocalFile,
                credentials: credentials,
              );
            } else {
              // Brand new vault with no legacy counterpart
              await stateStore.setVaultMigrated(vaultId, true);
            }
          }
        }
      } on SocketException {
        return GoogleDriveSyncResult.offline(
          'Offline: no connection to Google Drive.',
        );
      } catch (e) {
        _logger.warning('Error querying Google Drive: $e');
        return GoogleDriveSyncResult.error('Google Drive network error: $e');
      }

      final lastSyncedMd5 = await stateStore.getLastSyncedMd5(vaultId);
      final lastSyncedVersion = await stateStore.getLastSyncedVersion(vaultId);
      final localDirty = await stateStore.isLocalDirty(vaultId);
      final localBytes = await getLocalBytes();

      // Case 0: Remote file does not exist yet (Initial upload into visible KeyNest folder)
      if (remoteMeta == null) {
        _logger.info(
          'Remote vault does not exist on Drive. Performing initial upload to KeyNest folder...',
        );
        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: localBytes,
        );

        final uploadedMeta = await client.createInitialVault(
          vaultFilename: effectiveFilename,
          bytes: localBytes,
          folderId: keynestFolderId,
        );

        await stateStore.setSyncCheckpoint(
          vaultId: vaultId,
          md5: uploadedMeta.md5Checksum,
          version: uploadedMeta.version,
          driveFileId: uploadedMeta.id,
        );
        await stateStore.setBaseCopy(vaultId, localBytes);
        await stateStore.setLocalDirty(vaultId, false);
        await stateStore.setVaultMigrated(vaultId, true);

        return GoogleDriveSyncResult.uploaded(
          uploadedMeta.id,
          uploadedMeta.md5Checksum,
          uploadedMeta.version,
        );
      }

      final remoteMd5Changed =
          (remoteMeta.md5Checksum != null &&
          remoteMeta.md5Checksum != lastSyncedMd5);
      final remoteVersionChanged =
          (remoteMeta.version != null &&
          remoteMeta.version != lastSyncedVersion);
      final remoteChanged = remoteMd5Changed || remoteVersionChanged;

      final baseCopy = await stateStore.getBaseCopy(vaultId);
      final hasLocalBytesChangedFromBase =
          baseCopy != null && !listEquals(baseCopy, localBytes);
      final localCalculatedMd5 = GoogleDriveClient.computeMd5(localBytes);
      final md5DiffersFromLastSync =
          lastSyncedMd5 != null && lastSyncedMd5 != localCalculatedMd5;
      final effectiveLocalDirty = localDirty ||
          hasLocalBytesChangedFromBase ||
          md5DiffersFromLastSync;

      // Decision Branch 1: Neither changed -> Up to date
      if (!effectiveLocalDirty && !remoteChanged) {
        _logger.fine('Neither local nor remote changed. Vault is up to date.');
        return GoogleDriveSyncResult.upToDate(
          remoteMeta.id,
          remoteMeta.md5Checksum,
        );
      }

      // Decision Branch 2: local_dirty + remote unchanged -> Upload with mitigations
      if (effectiveLocalDirty && !remoteChanged) {
        _logger.info(
          'Local vault dirty and remote unchanged. Uploading to Google Drive...',
        );
        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: localBytes,
        );

        // Mitigation 1: Pre-upload re-check
        final preCheckMeta = await client.getFileMetadata(remoteMeta.id);
        if (preCheckMeta != null && preCheckMeta.md5Checksum != lastSyncedMd5) {
          _logger.warning(
            'Remote changed right before upload. Switching to 3-way merge.',
          );
          return await _runMergeProcedure(
            vaultId: vaultId,
            remoteFileId: remoteMeta.id,
            getLocalBytes: getLocalBytes,
            saveLocalBytes: saveLocalBytes,
            unlockedLocalFile: unlockedLocalFile,
            credentials: credentials,
          );
        }

        final updatedMeta = await client.updateVault(
          fileId: remoteMeta.id,
          bytes: localBytes,
        );

        // Mitigation 2: Post-upload verification
        if (updatedMeta.md5Checksum != null &&
            updatedMeta.md5Checksum != localCalculatedMd5) {
          _logger.severe(
            'Post-upload verification failed: MD5 mismatch! Triggering merge recovery.',
          );
          return await _runMergeProcedure(
            vaultId: vaultId,
            remoteFileId: remoteMeta.id,
            getLocalBytes: getLocalBytes,
            saveLocalBytes: saveLocalBytes,
            unlockedLocalFile: unlockedLocalFile,
            credentials: credentials,
          );
        }

        // Mitigation 2 (cont): Check version jump for race window
        final postMeta = await client.getFileMetadata(remoteMeta.id);
        if (postMeta != null &&
            updatedMeta.version != null &&
            postMeta.version != null &&
            postMeta.version! > updatedMeta.version!) {
          _logger.warning(
            'Race condition detected: another device modified file simultaneously!',
          );
          return await _runMergeProcedure(
            vaultId: vaultId,
            remoteFileId: remoteMeta.id,
            getLocalBytes: getLocalBytes,
            saveLocalBytes: saveLocalBytes,
            unlockedLocalFile: unlockedLocalFile,
            credentials: credentials,
          );
        }

        await stateStore.setSyncCheckpoint(
          vaultId: vaultId,
          md5: updatedMeta.md5Checksum,
          version: updatedMeta.version,
          driveFileId: updatedMeta.id,
        );
        await stateStore.setBaseCopy(vaultId, localBytes);
        await stateStore.setLocalDirty(vaultId, false);

        return GoogleDriveSyncResult.uploaded(
          updatedMeta.id,
          updatedMeta.md5Checksum,
          updatedMeta.version,
        );
      }

      // Decision Branch 3: not local_dirty + remote changed -> Download & replace local
      if (!effectiveLocalDirty && remoteChanged) {
        _logger.info(
          'Remote vault updated on Drive and local clean. Downloading...',
        );
        final remoteBytes = await client.downloadFile(remoteMeta.id);

        if (!isValidKdbxBytes(remoteBytes)) {
          return GoogleDriveSyncResult.error(
            'Downloaded file is not a valid KDBX database.',
          );
        }

        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: localBytes,
        );

        await saveLocalBytes(remoteBytes);
        await stateStore.setSyncCheckpoint(
          vaultId: vaultId,
          md5: remoteMeta.md5Checksum,
          version: remoteMeta.version,
          driveFileId: remoteMeta.id,
        );
        await stateStore.setBaseCopy(vaultId, remoteBytes);
        await stateStore.setLocalDirty(vaultId, false);

        return GoogleDriveSyncResult.downloaded(
          remoteMeta.id,
          remoteMeta.md5Checksum,
          remoteMeta.version,
        );
      }

      // Decision Branch 4: local_dirty + remote changed -> 3-WAY MERGE
      _logger.info('Both local and remote modified. Initiating 3-way merge...');
      return await _runMergeProcedure(
        vaultId: vaultId,
        remoteFileId: remoteMeta.id,
        getLocalBytes: getLocalBytes,
        saveLocalBytes: saveLocalBytes,
        unlockedLocalFile: unlockedLocalFile,
        credentials: credentials,
      );
    } catch (e) {
      _logger.severe('Unexpected error during Google Drive sync: $e');
      return GoogleDriveSyncResult.error('Sync error: $e');
    }
  }

  /// Executes 3-way in-memory merge and uploads merged vault. Retries up to 3 times on conflict.
  Future<GoogleDriveSyncResult> _runMergeProcedure({
    required String vaultId,
    required String remoteFileId,
    required Future<Uint8List> Function() getLocalBytes,
    required Future<void> Function(Uint8List bytes) saveLocalBytes,
    KdbxFile? unlockedLocalFile,
    Credentials? credentials,
  }) async {
    final effectiveCreds = credentials ?? unlockedLocalFile?.credentials;
    if (effectiveCreds == null || unlockedLocalFile == null) {
      return GoogleDriveSyncResult.error(
        'Sync paused: unlock vault to merge concurrent changes.',
      );
    }

    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      _logger.info('Merge attempt $attempt of $maxAttempts...');

      // 1. Download current remote file
      final remoteBytes = await client.downloadFile(remoteFileId);
      if (!isValidKdbxBytes(remoteBytes)) {
        return GoogleDriveSyncResult.error(
          'Remote file is corrupt or invalid KDBX format.',
        );
      }

      // 2. Open remote file in memory with current credentials
      final kdbxFormat = KdbxFormat();
      KdbxFile remoteFile;
      try {
        remoteFile = await kdbxFormat.read(remoteBytes, effectiveCreds);
      } catch (e) {
        _logger.warning(
          'Failed to decrypt remote file with current credentials: $e',
        );
        return GoogleDriveSyncResult.error(
          'Master password mismatch: remote vault password was changed on another device.',
        );
      }

      // 3. Open BASE file if present
      KdbxFile? baseFile;
      final baseBytes = await stateStore.getBaseCopy(vaultId);
      if (baseBytes != null && isValidKdbxBytes(baseBytes)) {
        try {
          baseFile = await kdbxFormat.read(baseBytes, effectiveCreds);
        } catch (e) {
          _logger.warning(
            'Could not decrypt base copy with current credentials: $e',
          );
        }
      }

      // 4. Pre-merge local backup
      final currentLocalBytes = await getLocalBytes();
      await stateStore.createBackup(
        vaultId: vaultId,
        currentVaultBytes: currentLocalBytes,
      );

      // 5. Run in-memory 3-way merge using DropboxVaultMergeEngine unchanged
      final mergeResult = DropboxVaultMergeEngine.merge(
        localFile: unlockedLocalFile,
        remoteFile: remoteFile,
        baseFile: baseFile,
      );

      // 6. Save merged file locally
      final mergedBytes = await unlockedLocalFile.save();
      await saveLocalBytes(mergedBytes);

      // 7. Mitigation 1: Pre-upload re-check
      final preUploadMeta = await client.getFileMetadata(remoteFileId);
      if (preUploadMeta != null &&
          preUploadMeta.md5Checksum != null &&
          preUploadMeta.md5Checksum !=
              GoogleDriveClient.computeMd5(remoteBytes)) {
        if (attempt < maxAttempts) {
          _logger.warning(
            'Remote changed during merge. Retrying merge (attempt $attempt)...',
          );
          continue;
        }
      }

      // 8. Upload merged database
      final updatedMeta = await client.updateVault(
        fileId: remoteFileId,
        bytes: mergedBytes,
      );

      // 9. Post-upload verification
      final expectedMd5 = GoogleDriveClient.computeMd5(mergedBytes);
      if (updatedMeta.md5Checksum != null &&
          updatedMeta.md5Checksum != expectedMd5) {
        if (attempt < maxAttempts) {
          _logger.warning('Post-upload MD5 mismatch. Retrying merge...');
          continue;
        }
      }

      // 10. Update state store checkpoints
      await stateStore.setSyncCheckpoint(
        vaultId: vaultId,
        md5: updatedMeta.md5Checksum,
        version: updatedMeta.version,
        driveFileId: remoteFileId,
      );
      await stateStore.setBaseCopy(vaultId, mergedBytes);
      await stateStore.setLocalDirty(vaultId, false);

      return GoogleDriveSyncResult.merged(
        mergeResult: mergeResult,
        fileId: remoteFileId,
        md5: updatedMeta.md5Checksum,
        version: updatedMeta.version,
      );
    }

    return GoogleDriveSyncResult.error(
      'Unable to automatically merge after $maxAttempts attempts due to high contention.',
    );
  }

  Future<GoogleDriveSyncResult> _migrateLegacyVaultToVisibleFolder({
    required String vaultId,
    required String vaultFilename,
    required GoogleDriveFileMetadata legacyMeta,
    required String keynestFolderId,
    required Future<Uint8List> Function() getLocalBytes,
    required Future<void> Function(Uint8List bytes) saveLocalBytes,
    KdbxFile? unlockedLocalFile,
    Credentials? credentials,
  }) async {
    _logger.info(
      'Migrating legacy vault "$vaultFilename" (${legacyMeta.id}) from appDataFolder to visible KeyNest folder...',
    );

    // 1. Create and verify a recoverable backup before migration
    final localBytes = await getLocalBytes();
    final backupFile = await stateStore.createBackup(
      vaultId: vaultId,
      currentVaultBytes: localBytes,
    );
    if (!backupFile.existsSync() ||
        backupFile.lengthSync() != localBytes.length) {
      return GoogleDriveSyncResult.error(
        'Pre-migration backup verification failed. Aborting migration.',
      );
    }

    // 2. Determine authoritative bytes and check for conflict / stale cache
    final lastSyncedMd5 = await stateStore.getLastSyncedMd5(vaultId);
    final localDirty = await stateStore.isLocalDirty(vaultId);
    final localMd5 = GoogleDriveClient.computeMd5(localBytes);
    final remoteLegacyMd5 = legacyMeta.md5Checksum;

    Uint8List authoritativeBytes;
    bool localUpdatedFromRemote = false;

    final remoteLegacyChanged =
        remoteLegacyMd5 != null && remoteLegacyMd5 != lastSyncedMd5;

    if (remoteLegacyChanged) {
      if (!localDirty && (lastSyncedMd5 == null || localMd5 == lastSyncedMd5)) {
        // Remote legacy has newer changes and local is clean -> Download remote authoritative bytes
        _logger.info(
          'Remote legacy vault has newer changes. Downloading authoritative bytes for migration...',
        );
        final remoteBytes = await client.downloadFile(legacyMeta.id);
        if (!isValidKdbxBytes(remoteBytes)) {
          return GoogleDriveSyncResult.error(
            'Downloaded legacy vault is corrupted or invalid KDBX format.',
          );
        }
        await saveLocalBytes(remoteBytes);
        authoritativeBytes = remoteBytes;
        localUpdatedFromRemote = true;
      } else if (localDirty) {
        // Both local and remote legacy changed -> CONFLICT!
        final effectiveCreds = credentials ?? unlockedLocalFile?.credentials;
        if (unlockedLocalFile != null && effectiveCreds != null) {
          _logger.info(
            'Both local and legacy remote modified. Performing 3-way merge before migration...',
          );
          final mergeRes = await _runMergeProcedure(
            vaultId: vaultId,
            remoteFileId: legacyMeta.id,
            getLocalBytes: getLocalBytes,
            saveLocalBytes: saveLocalBytes,
            unlockedLocalFile: unlockedLocalFile,
            credentials: effectiveCreds,
          );
          if (mergeRes.status == GoogleDriveSyncStatus.error) {
            return mergeRes;
          }
          authoritativeBytes = await getLocalBytes();
        } else {
          return GoogleDriveSyncResult.conflict(
            'Conflict detected during migration: both local vault and Google Drive appData vault have unsynced changes. Unlock vault to resolve.',
          );
        }
      } else {
        // Local not marked dirty, but localMd5 != lastSyncedMd5 and remoteLegacyChanged -> stale local cache protection
        _logger.warning(
          'Stale local cache detected during migration. Downloading authoritative remote legacy vault.',
        );
        final remoteBytes = await client.downloadFile(legacyMeta.id);
        if (!isValidKdbxBytes(remoteBytes)) {
          return GoogleDriveSyncResult.error(
            'Downloaded legacy vault is corrupted or invalid KDBX format.',
          );
        }
        await saveLocalBytes(remoteBytes);
        authoritativeBytes = remoteBytes;
        localUpdatedFromRemote = true;
      }
    } else {
      // Remote legacy is unchanged since last sync -> Local is authoritative
      authoritativeBytes = localBytes;
    }

    // 3. Upload authoritative vault to visible KeyNest folder
    GoogleDriveFileMetadata visibleMeta;
    try {
      visibleMeta = await client.copyFile(
        fileId: legacyMeta.id,
        destinationFolderId: keynestFolderId,
        newName: vaultFilename,
      );
      if (localDirty ||
          localUpdatedFromRemote ||
          authoritativeBytes != localBytes) {
        visibleMeta = await client.updateVault(
          fileId: visibleMeta.id,
          bytes: authoritativeBytes,
        );
      }
    } catch (e) {
      _logger.info(
        'Direct Drive copy failed or cross-space copy unsupported ($e); uploading authoritative bytes directly.',
      );
      visibleMeta = await client.createInitialVault(
        vaultFilename: vaultFilename,
        bytes: authoritativeBytes,
        folderId: keynestFolderId,
      );
    }

    // 4. Verify destination file content / checksum
    final expectedMd5 = GoogleDriveClient.computeMd5(authoritativeBytes);
    if (visibleMeta.md5Checksum != null &&
        visibleMeta.md5Checksum != expectedMd5) {
      final checkMeta = await client.getFileMetadata(visibleMeta.id);
      if (checkMeta?.md5Checksum != expectedMd5) {
        return GoogleDriveSyncResult.error(
          'Migration checksum verification failed for visible KeyNest vault.',
        );
      }
      visibleMeta = checkMeta!;
    }

    // 5. Update state store checkpoints without deleting the legacy file
    await stateStore.setLegacyDriveFileId(vaultId, legacyMeta.id);
    await stateStore.recordLegacyMigration(legacyMeta.id, visibleMeta.id);
    await stateStore.setDriveFileId(vaultId, visibleMeta.id);
    await stateStore.setSyncCheckpoint(
      vaultId: vaultId,
      md5: visibleMeta.md5Checksum,
      version: visibleMeta.version,
      driveFileId: visibleMeta.id,
    );
    await stateStore.setBaseCopy(vaultId, authoritativeBytes);
    await stateStore.setLocalDirty(vaultId, false);
    await stateStore.setVaultMigrated(vaultId, true);

    _logger.info(
      'Successfully migrated vault "$vaultFilename" to KeyNest visible folder (${visibleMeta.id}). Legacy file ${legacyMeta.id} preserved.',
    );

    return GoogleDriveSyncResult.migrated(
      fileId: visibleMeta.id,
      md5: visibleMeta.md5Checksum,
      version: visibleMeta.version,
    );
  }
}
