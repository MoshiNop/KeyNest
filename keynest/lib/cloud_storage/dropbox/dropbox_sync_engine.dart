import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_client.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_merge_engine.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_state.dart';
import 'package:logging/logging.dart';

final _logger = Logger('dropbox_sync_engine');

enum SyncStatus {
  upToDate,
  uploaded,
  downloaded,
  merged,
  paused,
  offline,
  conflict,
  error,
}

class DropboxSyncResult {
  DropboxSyncResult({
    required this.status,
    this.message,
    this.rev,
    this.mergeSummary,
  });

  final SyncStatus status;
  final String? message;
  final String? rev;
  final String? mergeSummary;

  static DropboxSyncResult upToDate(String? rev) => DropboxSyncResult(
    status: SyncStatus.upToDate,
    message: 'Vault is up to date.',
    rev: rev,
  );

  static DropboxSyncResult uploaded(String rev) => DropboxSyncResult(
    status: SyncStatus.uploaded,
    message: 'Vault uploaded successfully.',
    rev: rev,
  );

  static DropboxSyncResult downloaded(String rev) => DropboxSyncResult(
    status: SyncStatus.downloaded,
    message: 'Vault downloaded and updated locally.',
    rev: rev,
  );

  static DropboxSyncResult merged(String summary, String rev) =>
      DropboxSyncResult(
        status: SyncStatus.merged,
        message: summary,
        mergeSummary: summary,
        rev: rev,
      );

  static DropboxSyncResult paused(String message) => DropboxSyncResult(
    status: SyncStatus.paused,
    message: message,
  );

  static DropboxSyncResult offline(String message) => DropboxSyncResult(
    status: SyncStatus.offline,
    message: message,
  );

  static DropboxSyncResult conflict(String message) => DropboxSyncResult(
    status: SyncStatus.conflict,
    message: message,
  );

  static DropboxSyncResult error(String message) => DropboxSyncResult(
    status: SyncStatus.error,
    message: message,
  );

  @override
  String toString() => 'DropboxSyncResult($status: $message, rev=$rev)';
}

/// Orchestrates the full synchronization decision table, atomic file replacements,
/// local backup rotation, and conflict/merge flows.
class DropboxSyncEngine {
  DropboxSyncEngine({
    required this.client,
    required this.stateStore,
  });

  final DropboxClient client;
  final DropboxSyncStateStore stateStore;

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

  /// Ensures a vault filename always ends with .kdbx extension.
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

  /// Executes the synchronization cycle for a vault file according to the decision table.
  ///
  /// Parameters:
  /// - [vaultId]: Unique local identifier for this vault.
  /// - [vaultFilename]: Name on Dropbox (e.g. 'vault.kdbx').
  /// - [getLocalBytes]: Callback returning the current encrypted bytes on disk.
  /// - [saveLocalBytes]: Callback to atomically replace the local vault on disk.
  /// - [unlockedLocalFile]: Currently unlocked KdbxFile in memory (if available).
  /// - [credentials]: Credentials used to unlock this vault (if available).
  Future<DropboxSyncResult> syncVault({
    required String vaultId,
    required String vaultFilename,
    required Future<Uint8List> Function() getLocalBytes,
    required Future<void> Function(Uint8List bytes) saveLocalBytes,
    KdbxFile? unlockedLocalFile,
    Credentials? credentials,
  }) async {
    final effectiveFilename = ensureKdbxExtension(vaultFilename);
    final effectiveCreds = credentials ?? unlockedLocalFile?.credentials;
    try {
      // 1. Change check: get metadata from Dropbox
      DropboxFileMetadata? remoteMeta;
      try {
        remoteMeta = await client.getMetadata(effectiveFilename);
        if (remoteMeta == null) {
          // Check for legacy extensionless file on Dropbox and migrate it safely
          final bareName = effectiveFilename.substring(
            0,
            effectiveFilename.length - 5,
          );
          try {
            final legacyMeta = await client.getMetadata(bareName);
            if (legacyMeta != null) {
              _logger.info(
                'Found legacy extensionless Dropbox vault "$bareName". Renaming to "$effectiveFilename"...',
              );
              remoteMeta = await client.moveFile(
                fromFilename: bareName,
                toFilename: effectiveFilename,
              );
            }
          } catch (e) {
            _logger.fine('No legacy extensionless Dropbox file to migrate: $e');
          }
        }
      } on SocketException {
        return DropboxSyncResult.offline(
          'Offline: no network connection to Dropbox.',
        );
      } catch (e) {
        _logger.warning('Failed to query remote metadata: $e');
        return DropboxSyncResult.error('Error contacting Dropbox: $e');
      }

      final lastSyncedRev = await stateStore.getLastSyncedRev(vaultId);
      final localDirty = await stateStore.isLocalDirty(vaultId);
      final localBytes = await getLocalBytes();

      // Case 0: Remote file does not exist yet (Initial upload)
      if (remoteMeta == null) {
        _logger.info(
          'Remote vault does not exist. Performing initial upload...',
        );
        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: localBytes,
        );

        final newRev = await client.uploadVault(
          vaultFilename: effectiveFilename,
          bytes: localBytes,
          expectedRev: null, // mode: "add"
        );

        await stateStore.setLastSyncedRev(vaultId, newRev);
        await stateStore.setBaseCopy(vaultId, localBytes);
        await stateStore.setLocalDirty(vaultId, false);
        return DropboxSyncResult.uploaded(newRev);
      }

      final remoteRevChanged = (remoteMeta.rev != lastSyncedRev);

      final baseCopy = await stateStore.getBaseCopy(vaultId);
      final hasLocalBytesChangedFromBase =
          baseCopy != null && !listEquals(baseCopy, localBytes);
      final effectiveLocalDirty = localDirty || hasLocalBytesChangedFromBase;

      // Decision Branch 1: Neither changed -> Up to date
      if (!effectiveLocalDirty && !remoteRevChanged) {
        _logger.fine('Neither local nor remote changed. Vault is up to date.');
        return DropboxSyncResult.upToDate(remoteMeta.rev);
      }

      // Decision Branch 2: local_dirty + remote rev unchanged -> Upload against last_synced_rev
      if (effectiveLocalDirty && !remoteRevChanged) {
        _logger.info('Local vault dirty and remote unchanged. Uploading...');
        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: localBytes,
        );

        try {
          final newRev = await client.uploadVault(
            vaultFilename: effectiveFilename,
            bytes: localBytes,
            expectedRev: lastSyncedRev,
          );

          await stateStore.setLastSyncedRev(vaultId, newRev);
          await stateStore.setBaseCopy(vaultId, localBytes);
          await stateStore.setLocalDirty(vaultId, false);
          return DropboxSyncResult.uploaded(newRev);
        } on DropboxConflictException {
          // Fall through to 3-way merge on 409 conflict
          _logger.warning(
            'Upload encountered 409 conflict. Triggering 3-way merge...',
          );
        }
      }

      // Decision Branch 3: not local_dirty + remote rev changed -> Download, validate, back up, replace local
      if (!effectiveLocalDirty && remoteRevChanged) {
        _logger.info('Remote vault updated and local clean. Downloading...');
        final downloadResult = await client.downloadVault(effectiveFilename);

        // Verify KDBX signature & header
        if (!isValidKdbxBytes(downloadResult.bytes)) {
          return DropboxSyncResult.error(
            'Downloaded file failed KDBX integrity check. Aborting download.',
          );
        }

        // Back up local vault before replacing
        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: localBytes,
        );

        // Atomically replace local vault
        await saveLocalBytes(downloadResult.bytes);
        await stateStore.setLastSyncedRev(vaultId, downloadResult.rev);
        await stateStore.setBaseCopy(vaultId, downloadResult.bytes);
        await stateStore.setLocalDirty(vaultId, false);

        return DropboxSyncResult.downloaded(downloadResult.rev);
      }

      // Decision Branch 4: local_dirty + remote rev changed (or 409 conflict) -> 3-way Merge
      _logger.info(
        'Conflict detected: both local and remote changed. Starting merge procedure...',
      );
      return await _executeMergeProcedure(
        vaultId: vaultId,
        vaultFilename: effectiveFilename,
        localBytes: localBytes,
        saveLocalBytes: saveLocalBytes,
        unlockedLocalFile: unlockedLocalFile,
        credentials: effectiveCreds,
        initialRemoteRev: remoteMeta.rev,
      );
    } catch (e, st) {
      _logger.severe('Unhandled error during syncVault: $e\n$st');
      return DropboxSyncResult.error('Sync failed: $e');
    }
  }

  /// Executes the 3-way in-memory merge procedure with up to 3 conflict retry attempts.
  Future<DropboxSyncResult> _executeMergeProcedure({
    required String vaultId,
    required String vaultFilename,
    required Uint8List localBytes,
    required Future<void> Function(Uint8List bytes) saveLocalBytes,
    required KdbxFile? unlockedLocalFile,
    required Credentials? credentials,
    required String initialRemoteRev,
  }) async {
    final effectiveCreds = credentials ?? unlockedLocalFile?.credentials;
    // Check if vault is unlocked
    if (unlockedLocalFile == null || effectiveCreds == null) {
      return DropboxSyncResult.paused('Sync paused: unlock to merge');
    }

    int attempts = 0;
    const maxAttempts = 3;
    String currentRemoteRev = initialRemoteRev;

    while (attempts < maxAttempts) {
      attempts++;
      _logger.info('Merge attempt $attempts of $maxAttempts...');

      // 1. Download remote file to temp buffer
      final downloadResult = await client.downloadVault(vaultFilename);
      currentRemoteRev = downloadResult.rev;

      if (!isValidKdbxBytes(downloadResult.bytes)) {
        return DropboxSyncResult.error(
          'Remote vault corrupt or invalid KDBX format.',
        );
      }

      // 2. Open databases in memory with current credentials
      KdbxFile remoteKdbx;
      try {
        remoteKdbx = await KdbxFormat().read(downloadResult.bytes, effectiveCreds);
      } catch (e) {
        _logger.warning(
          'Failed to open remote database with current credentials: $e',
        );
        return DropboxSyncResult.error(
          'Master password mismatch: remote vault password was changed on another device. Please enter the new password to proceed.',
        );
      }

      // Read stored base copy
      final baseBytes = await stateStore.getBaseCopy(vaultId);
      KdbxFile? baseKdbx;
      if (baseBytes != null && isValidKdbxBytes(baseBytes)) {
        try {
          baseKdbx = await KdbxFormat().read(baseBytes, effectiveCreds);
        } catch (e) {
          _logger.warning(
            'Base copy failed to decrypt with current credentials: $e',
          );
        }
      }

      // 3. Execute 3-way in-memory merge
      DropboxMergeResult mergeResult;
      try {
        mergeResult = DropboxVaultMergeEngine.merge(
          localFile: unlockedLocalFile,
          remoteFile: remoteKdbx,
          baseFile: baseKdbx,
        );
      } on DropboxMergeCredentialMismatchException catch (e) {
        return DropboxSyncResult.error(e.message);
      } on DropboxMergeValidationException catch (e) {
        return DropboxSyncResult.error(
          'Validation failure during merge: ${e.message}',
        );
      }

      // 4. Save merged database to encrypted bytes
      final mergedBytes = await unlockedLocalFile.save();

      // Back up local vault before saving merged version
      await stateStore.createBackup(
        vaultId: vaultId,
        currentVaultBytes: localBytes,
      );

      // Save locally
      await saveLocalBytes(mergedBytes);

      // 5. Upload merged database against currentRemoteRev
      try {
        final finalRev = await client.uploadVault(
          vaultFilename: vaultFilename,
          bytes: mergedBytes,
          expectedRev: currentRemoteRev,
        );

        // Merge succeeded!
        await stateStore.setLastSyncedRev(vaultId, finalRev);
        await stateStore.setBaseCopy(vaultId, mergedBytes);
        await stateStore.setLocalDirty(vaultId, false);

        return DropboxSyncResult.merged(mergeResult.summary, finalRev);
      } on DropboxConflictException {
        _logger.warning(
          'Conflict encountered during merge upload attempt $attempts. Repeating merge...',
        );
        if (attempts >= maxAttempts) {
          return DropboxSyncResult.conflict(
            'Sync conflict: remote vault was modified concurrently multiple times. Please retry sync.',
          );
        }
      }
    }

    return DropboxSyncResult.conflict(
      'Automatic merge failed after 3 attempts.',
    );
  }
}
