import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_client.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_merge_engine.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_state.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

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

  final Map<String, Lock> _vaultLocks = {};

  Lock _getLockForVault(String vaultId) =>
      _vaultLocks.putIfAbsent(vaultId, Lock.new);

  static const String keyNestFolder = '/KeyNest';

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

  /// Resolves canonical `/KeyNest/<filename>.kdbx` path for bare filenames,
  /// while preserving explicit subfolder paths such as `/Custom/work.kdbx`.
  static String resolveCanonicalDropboxPath(String rawNameOrPath) {
    final normalizedSlashes = rawNameOrPath.trim().replaceAll(r'\', '/');
    final withoutLeadingSlash = normalizedSlashes.startsWith('/')
        ? normalizedSlashes.substring(1)
        : normalizedSlashes;
    if (withoutLeadingSlash.isEmpty) {
      return '$keyNestFolder/vault.kdbx';
    }
    if (withoutLeadingSlash.contains('/')) {
      final dir = p.posix.dirname('/$withoutLeadingSlash');
      final base = ensureKdbxExtension(
        p.posix.basename('/$withoutLeadingSlash'),
      );
      return p.posix.join(dir, base);
    }
    return p.posix.join(keyNestFolder, ensureKdbxExtension(withoutLeadingSlash));
  }

  static String _disambiguateDropboxPath(String canonicalPath, String vaultId) {
    final dir = p.posix.dirname(canonicalPath);
    final base = p.posix.basename(canonicalPath);
    final stem = base.toLowerCase().endsWith('.kdbx')
        ? base.substring(0, base.length - 5)
        : base;
    final cleanId = vaultId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final suffix = cleanId.length >= 6
        ? cleanId.substring(0, 6).toLowerCase()
        : (cleanId.isNotEmpty ? cleanId.toLowerCase() : '2');
    return p.posix.join(dir, '${stem}_$suffix.kdbx');
  }

  Future<bool> _isOwnedByAnotherVault(
    String vaultId,
    DropboxFileMetadata meta,
  ) async {
    final sanitizedSelf = stateStore.sanitizeVaultId(vaultId);
    if (meta.id.isNotEmpty) {
      final ownerById = await stateStore.findVaultIdByDropboxFileId(meta.id);
      if (ownerById != null && ownerById != sanitizedSelf) {
        return true;
      }
    }
    if (meta.pathLower.isNotEmpty) {
      final ownerByPath = await stateStore.findVaultIdByRemotePath(
        meta.pathLower,
      );
      if (ownerByPath != null && ownerByPath != sanitizedSelf) {
        return true;
      }
    }
    return false;
  }

  /// Executes the synchronization cycle for a vault file according to the decision table.
  Future<DropboxSyncResult> syncVault({
    required String vaultId,
    required String vaultFilename,
    required Future<Uint8List> Function() getLocalBytes,
    required Future<void> Function(Uint8List bytes) saveLocalBytes,
    KdbxFile? unlockedLocalFile,
    Credentials? credentials,
  }) {
    return _getLockForVault(vaultId).synchronized(
      () => _syncVaultInternal(
        vaultId: vaultId,
        vaultFilename: vaultFilename,
        getLocalBytes: getLocalBytes,
        saveLocalBytes: saveLocalBytes,
        unlockedLocalFile: unlockedLocalFile,
        credentials: credentials,
      ),
    );
  }

  Future<DropboxSyncResult> _syncVaultInternal({
    required String vaultId,
    required String vaultFilename,
    required Future<Uint8List> Function() getLocalBytes,
    required Future<void> Function(Uint8List bytes) saveLocalBytes,
    KdbxFile? unlockedLocalFile,
    Credentials? credentials,
  }) async {
    var targetRemotePath = resolveCanonicalDropboxPath(vaultFilename);
    final baseFilename = p.posix.basename(targetRemotePath);
    final bareStem = baseFilename.substring(0, baseFilename.length - 5);
    final effectiveCreds = credentials ?? unlockedLocalFile?.credentials;

    try {
      final lastSyncedRev = await stateStore.getLastSyncedRev(vaultId);
      final storedRemotePath = await stateStore.getRemotePath(vaultId);

      // 1. Change check & path resolution (`/KeyNest/<file>` with legacy `/` migration)
      DropboxFileMetadata? remoteMeta;
      try {
        if (storedRemotePath != null && storedRemotePath.isNotEmpty) {
          targetRemotePath = storedRemotePath;
          remoteMeta = await client.getMetadata(storedRemotePath);
          // Migrate legacy root `/<vault>.kdbx` into `/KeyNest/<vault>.kdbx` if unclaimed
          if (remoteMeta != null &&
              p.posix.dirname(remoteMeta.pathLower) == '/') {
            final migratedTarget = p.posix.join(keyNestFolder, baseFilename);
            final existingCanonical = await client.getMetadata(migratedTarget);
            if (existingCanonical == null) {
              try {
                remoteMeta = await client.moveFile(
                  fromFilename: remoteMeta.pathLower,
                  toFilename: migratedTarget,
                );
                targetRemotePath = remoteMeta.pathDisplay.isNotEmpty
                    ? remoteMeta.pathDisplay
                    : migratedTarget;
                await stateStore.setRemotePath(vaultId, targetRemotePath);
              } catch (e) {
                _logger.fine('Keeping legacy root Dropbox path for $vaultId: $e');
              }
            }
          }
        }

        if (remoteMeta == null) {
          targetRemotePath = resolveCanonicalDropboxPath(vaultFilename);
          final candidate = await client.getMetadata(targetRemotePath);
          if (candidate != null) {
            if (await _isOwnedByAnotherVault(vaultId, candidate)) {
              targetRemotePath = _disambiguateDropboxPath(
                targetRemotePath,
                vaultId,
              );
              remoteMeta = await client.getMetadata(targetRemotePath);
            } else {
              remoteMeta = candidate;
            }
          }
        }

        // Check legacy root `/<filename>.kdbx` or extensionless files if not found in `/KeyNest`
        if (remoteMeta == null &&
            p.posix.dirname(targetRemotePath).toLowerCase() ==
                keyNestFolder.toLowerCase()) {
          final legacyCandidates = <String>[
            '/$baseFilename',
            '$keyNestFolder/$bareStem',
            '/$bareStem',
          ];
          for (final legacyPath in legacyCandidates) {
            try {
              final legacyMeta = await client.getMetadata(legacyPath);
              if (legacyMeta != null &&
                  !(await _isOwnedByAnotherVault(vaultId, legacyMeta))) {
                try {
                  remoteMeta = await client.moveFile(
                    fromFilename: legacyPath,
                    toFilename: targetRemotePath,
                  );
                } catch (_) {
                  remoteMeta = legacyMeta;
                  targetRemotePath = legacyPath;
                }
                break;
              }
            } catch (_) {}
          }
        }

        // First-ever sync disambiguation: if an unclaimed remote file with the same
        // filename is actually a completely different KDBX database (different rootGroup UUID),
        // disambiguate instead of colliding or failing!
        if (remoteMeta != null &&
            lastSyncedRev == null &&
            unlockedLocalFile != null &&
            effectiveCreds != null) {
          final existingOwner = await stateStore.findVaultIdByRemotePath(
            remoteMeta.pathLower,
          );
          if (existingOwner == null) {
            try {
              final probe = await client.downloadVault(targetRemotePath);
              if (isValidKdbxBytes(probe.bytes)) {
                final probeKdbx = await KdbxFormat().read(
                  probe.bytes,
                  effectiveCreds,
                );
                if (probeKdbx.body.rootGroup.uuid !=
                    unlockedLocalFile.body.rootGroup.uuid) {
                  _logger.info(
                    'Remote Dropbox file "$targetRemotePath" has a different rootGroup UUID. Disambiguating path for vault $vaultId.',
                  );
                  targetRemotePath = _disambiguateDropboxPath(
                    targetRemotePath,
                    vaultId,
                  );
                  remoteMeta = await client.getMetadata(targetRemotePath);
                }
              }
            } catch (_) {
              // Different password or network transient: leave remoteMeta intact so normal
              // initial-sync / password-mismatch handling proceeds if it was the intended vault,
              // UNLESS another vault already exists locally.
            }
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

      final localDirty = await stateStore.isLocalDirty(vaultId);
      final localBytes = await getLocalBytes();

      // Case 0: Remote file does not exist yet (Initial upload)
      if (remoteMeta == null) {
        _logger.info(
          'Remote vault does not exist at $targetRemotePath. Performing initial upload...',
        );
        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: localBytes,
        );

        final newRev = await client.uploadVault(
          vaultFilename: targetRemotePath,
          bytes: localBytes,
          expectedRev: null, // mode: "add"
        );

        await stateStore.setRemotePath(vaultId, targetRemotePath);
        await stateStore.setLastSyncedRev(vaultId, newRev);
        await stateStore.setBaseCopy(vaultId, localBytes);
        await stateStore.setLocalDirty(vaultId, false);
        return DropboxSyncResult.uploaded(newRev);
      }

      await stateStore.setRemotePath(vaultId, targetRemotePath);
      if (remoteMeta.id.isNotEmpty) {
        await stateStore.setDropboxFileId(vaultId, remoteMeta.id);
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
            vaultFilename: targetRemotePath,
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
        final downloadResult = await client.downloadVault(targetRemotePath);

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
        if (downloadResult.metadata.id.isNotEmpty) {
          await stateStore.setDropboxFileId(
            vaultId,
            downloadResult.metadata.id,
          );
        }
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
        vaultFilename: targetRemotePath,
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
  /// Never mutates [unlockedLocalFile] or local disk until remote upload succeeds.
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
    if (unlockedLocalFile == null || effectiveCreds == null) {
      return DropboxSyncResult.paused('Sync paused: unlock to merge');
    }

    int attempts = 0;
    const maxAttempts = 3;
    String currentRemoteRev = initialRemoteRev;
    bool backupCreated = false;

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

      // 2. Open fresh working copy of local & remote databases in memory
      final kdbxFormat = KdbxFormat();
      KdbxFile workingLocalFile;
      try {
        workingLocalFile = await kdbxFormat.read(localBytes, effectiveCreds);
      } catch (_) {
        final fallbackBytes = await unlockedLocalFile.save();
        workingLocalFile = await kdbxFormat.read(fallbackBytes, effectiveCreds);
      }

      KdbxFile remoteKdbx;
      try {
        remoteKdbx = await kdbxFormat.read(
          downloadResult.bytes,
          effectiveCreds,
        );
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
          baseKdbx = await kdbxFormat.read(baseBytes, effectiveCreds);
        } catch (e) {
          _logger.warning(
            'Base copy failed to decrypt with current credentials: $e',
          );
        }
      }

      // 3. Execute 3-way merge on isolated [workingLocalFile]
      DropboxMergeResult mergeResult;
      try {
        mergeResult = DropboxVaultMergeEngine.merge(
          localFile: workingLocalFile,
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

      // 4. Serialize merged database to encrypted bytes
      final mergedBytes = await workingLocalFile.save();

      if (!backupCreated) {
        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: localBytes,
        );
        backupCreated = true;
      }

      // 5. Upload merged database against currentRemoteRev BEFORE mutating local state
      try {
        final finalRev = await client.uploadVault(
          vaultFilename: vaultFilename,
          bytes: mergedBytes,
          expectedRev: currentRemoteRev,
        );

        // Upload succeeded! Commit merge to unlockedLocalFile, disk, and checkpoints.
        DropboxVaultMergeEngine.merge(
          localFile: unlockedLocalFile,
          remoteFile: remoteKdbx,
          baseFile: baseKdbx,
        );
        await saveLocalBytes(mergedBytes);
        if (downloadResult.metadata.id.isNotEmpty) {
          await stateStore.setDropboxFileId(
            vaultId,
            downloadResult.metadata.id,
          );
        }
        await stateStore.setRemotePath(vaultId, vaultFilename);
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
