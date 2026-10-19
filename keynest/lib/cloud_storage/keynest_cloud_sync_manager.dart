import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_engine.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_state.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_engine.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

final _logger = Logger('KeyNestCloudSyncManager');

enum KeyNestSyncStatus {
  idle,
  syncing,
  success,
  conflict,
  error,
  disabled,
}

class VaultSyncInfo {
  VaultSyncInfo({
    this.status = KeyNestSyncStatus.idle,
    this.lastSyncTime,
    this.lastSuccessfulSyncTime,
    this.lastAttemptedSyncTime,
    this.message,
  });

  final KeyNestSyncStatus status;
  final DateTime? lastSyncTime;
  final DateTime? lastSuccessfulSyncTime;
  final DateTime? lastAttemptedSyncTime;
  final String? message;

  DateTime? get displaySyncTime => lastSuccessfulSyncTime ?? lastSyncTime;

  VaultSyncInfo copyWith({
    KeyNestSyncStatus? status,
    DateTime? lastSyncTime,
    DateTime? lastSuccessfulSyncTime,
    DateTime? lastAttemptedSyncTime,
    String? message,
  }) {
    return VaultSyncInfo(
      status: status ?? this.status,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      lastSuccessfulSyncTime:
          lastSuccessfulSyncTime ?? this.lastSuccessfulSyncTime,
      lastAttemptedSyncTime:
          lastAttemptedSyncTime ?? this.lastAttemptedSyncTime,
      message: message ?? this.message,
    );
  }
}

class VaultSyncResult {
  VaultSyncResult({
    required this.vaultId,
    required this.vaultName,
    required this.status,
    this.message,
    this.timestamp,
  });

  final String vaultId;
  final String vaultName;
  final KeyNestSyncStatus status;
  final String? message;
  final DateTime? timestamp;

  bool get isSuccess =>
      status == KeyNestSyncStatus.success || status == KeyNestSyncStatus.idle;
}

/// Central manager for per-provider, per-vault synchronization controls and persistence.
class KeyNestCloudSyncManager extends ChangeNotifier {
  KeyNestCloudSyncManager._();

  static final KeyNestCloudSyncManager instance = KeyNestCloudSyncManager._();

  static const String _fileName = 'keynest_cloud_sync_preferences.json';

  io.File? _fileOverride;
  void setFileOverrideForTesting(io.File? file) {
    _fileOverride = file;
  }

  // in-memory map: providerId -> (vaultId -> bool)
  final Map<String, Map<String, bool>> _selections = {};

  // in-memory map: providerId -> (vaultId -> VaultSyncInfo)
  final Map<String, Map<String, VaultSyncInfo>> _syncInfo = {};

  // Per-vault locks to serialize sync execution and avoid concurrent jobs
  final Map<String, Lock> _vaultLocks = {};

  Lock _getLock(String vaultId) =>
      _vaultLocks.putIfAbsent(vaultId, () => Lock());

  bool _loaded = false;

  // Per-vault debounce timers
  final Map<String, Timer> _vaultDebounceTimers = {};
  final Set<String> _pendingPostSaveVaults = {};

  // Per-vault generation tracking to avoid stale uploads and handle concurrent saves
  final Map<String, int> _localGenerations = {};
  final Map<String, int> _syncedGenerations = {};
  final Map<String, bool> _vaultSyncing = {};

  @visibleForTesting
  void resetForTesting() {
    for (final timer in _vaultDebounceTimers.values) {
      timer.cancel();
    }
    _vaultDebounceTimers.clear();
    _pendingPostSaveVaults.clear();
    _localGenerations.clear();
    _syncedGenerations.clear();
    _vaultSyncing.clear();
    _selections.clear();
    _syncInfo.clear();
    _loaded = false;
    _fileOverride = null;
  }

  Future<io.File> _getPrefsFile() async {
    if (_fileOverride != null) {
      return _fileOverride!;
    }
    final appDataDir = await PathUtils().getAppDataDirectory();
    return io.File(p.join(appDataDir.path, _fileName));
  }

  Future<void> load({io.File? fileOverride}) async {
    if (fileOverride != null) {
      _fileOverride = fileOverride;
    }
    if (_loaded && _fileOverride == null) {
      return;
    }
    try {
      final file = await _getPrefsFile();
      if (file.existsSync()) {
        final content = file.readAsStringSync();
        if (content.trim().isNotEmpty) {
          final decoded = json.decode(content) as Map<String, dynamic>;
          final rawSelections =
              decoded['selections'] as Map<String, dynamic>? ?? {};
          _selections.clear();
          for (final pEntry in rawSelections.entries) {
            final providerMap = pEntry.value as Map<String, dynamic>? ?? {};
            _selections[pEntry.key] = providerMap.map(
              (k, v) => MapEntry(k, v == true),
            );
          }

          final rawSync = decoded['lastSync'] as Map<String, dynamic>? ?? {};
          _syncInfo.clear();
          for (final pEntry in rawSync.entries) {
            final vaultMap = pEntry.value as Map<String, dynamic>? ?? {};
            _syncInfo[pEntry.key] = vaultMap.map((k, v) {
              final infoMap = v as Map<String, dynamic>? ?? {};
              final timeStr = infoMap['time'] as String?;
              final time = timeStr != null ? DateTime.tryParse(timeStr) : null;
              final successTimeStr = infoMap['successTime'] as String?;
              final successTime = successTimeStr != null
                  ? DateTime.tryParse(successTimeStr)
                  : null;
              final attemptTimeStr = infoMap['attemptTime'] as String?;
              final attemptTime = attemptTimeStr != null
                  ? DateTime.tryParse(attemptTimeStr)
                  : time;

              final statusStr = infoMap['status'] as String? ?? 'idle';
              KeyNestSyncStatus status;
              switch (statusStr) {
                case 'success':
                  status = KeyNestSyncStatus.success;
                  break;
                case 'conflict':
                  status = KeyNestSyncStatus.conflict;
                  break;
                case 'error':
                  status = KeyNestSyncStatus.error;
                  break;
                case 'syncing':
                  status = KeyNestSyncStatus.syncing;
                  break;
                case 'disabled':
                  status = KeyNestSyncStatus.disabled;
                  break;
                default:
                  status = KeyNestSyncStatus.idle;
              }
              return MapEntry(
                k,
                VaultSyncInfo(
                  status: status,
                  lastSyncTime: time,
                  lastSuccessfulSyncTime:
                      successTime ?? (status == KeyNestSyncStatus.success ? time : null),
                  lastAttemptedSyncTime: attemptTime,
                  message: infoMap['message'] as String?,
                ),
              );
            });
          }
        }
      }
      _loaded = true;
    } catch (e, stack) {
      _logger.warning('Failed to load cloud sync preferences: $e', stack);
    }
  }

  Future<void> _save() async {
    try {
      final file = await _getPrefsFile();
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      final outSelections = <String, Map<String, bool>>{};
      for (final e in _selections.entries) {
        outSelections[e.key] = Map<String, bool>.from(e.value);
      }

      final outSync = <String, Map<String, dynamic>>{};
      for (final pEntry in _syncInfo.entries) {
        final vMap = <String, dynamic>{};
        for (final vEntry in pEntry.value.entries) {
          final info = vEntry.value;
          vMap[vEntry.key] = {
            'status': info.status.name,
            if (info.lastSyncTime != null)
              'time': info.lastSyncTime!.toIso8601String(),
            if (info.lastSuccessfulSyncTime != null)
              'successTime': info.lastSuccessfulSyncTime!.toIso8601String(),
            if (info.lastAttemptedSyncTime != null)
              'attemptTime': info.lastAttemptedSyncTime!.toIso8601String(),
            if (info.message != null) 'message': info.message,
          };
        }
        outSync[pEntry.key] = vMap;
      }

      final data = {
        'selections': outSelections,
        'lastSync': outSync,
      };

      file.writeAsStringSync(json.encode(data), flush: true);
    } catch (e, stack) {
      _logger.severe('Failed to save cloud sync preferences: $e', stack);
    }
  }

  /// Returns whether synchronization is enabled for [vaultId] on [providerId].
  /// All eligible vaults default to true unless the user explicitly opted out.
  bool isVaultSyncEnabled(
    String providerId,
    String vaultId, {
    bool isNativeCloudVault = false,
  }) {
    final providerMap = _selections[providerId];
    if (providerMap != null && providerMap.containsKey(vaultId)) {
      return providerMap[vaultId] == true;
    }
    // Default to true for eligible local vaults and native cloud vaults
    return true;
  }

  /// Sets whether synchronization is enabled for [vaultId] on [providerId] and persists it.
  Future<void> setVaultSyncEnabled(
    String providerId,
    String vaultId,
    bool enabled,
  ) async {
    await load();
    final providerMap = _selections.putIfAbsent(providerId, () => {});
    providerMap[vaultId] = enabled;
    await _save();
    notifyListeners();
  }

  /// Returns sync status info for [vaultId] on [providerId].
  VaultSyncInfo getVaultSyncInfo(String providerId, String vaultId) {
    return _syncInfo[providerId]?[vaultId] ?? VaultSyncInfo();
  }

  /// Marks a vault dirty across all supported sync state stores to guarantee
  /// upload on next sync even if the app terminates early.
  Future<void> markVaultDirty(String vaultId) async {
    try {
      final gdriveState = GoogleDriveSyncStateStore(pathUtils: PathUtils());
      await gdriveState.markLocalDirty(vaultId);
    } catch (_) {}
    try {
      final dropboxState = DropboxSyncStateStore(pathUtils: PathUtils());
      await dropboxState.markLocalDirty(vaultId);
    } catch (_) {}
  }

  /// Ensures a vault filename retains the .kdbx extension.
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

  /// Resolves the canonical remote vault filename with .kdbx extension for [source].
  static String resolveRemoteVaultFilename(FileSource source) {
    if (source is FileSourceLocal) {
      final pickerName = source.filePickerInfo?.fileName;
      if (pickerName != null && pickerName.trim().isNotEmpty) {
        return ensureKdbxExtension(pickerName);
      }
    }

    final dispName = source.displayName;
    if (dispName.isNotEmpty &&
        dispName != 'Vault' &&
        dispName.toLowerCase() != 'vault') {
      return ensureKdbxExtension(dispName);
    }

    final path = source.displayPath;
    String decoded = path;
    try {
      decoded = Uri.decodeComponent(path);
    } catch (_) {}

    final segments = decoded.split(RegExp(r'[\\/:]'));
    String name = segments.isNotEmpty ? segments.last.trim() : '';
    if (name.isEmpty || name.toLowerCase() == 'kdbx') {
      name = source.displayName;
    }
    return ensureKdbxExtension(name);
  }

  /// Schedules debounced synchronization after a vault is saved.
  /// Coalesces rapid successive changes per-vault while guaranteeing that
  /// modifications made while a sync is in progress are re-synchronized.
  void schedulePostSaveSync({
    required KdbxFile kdbxFile,
    required KdbxBloc kdbxBloc,
    Duration debounce = const Duration(milliseconds: 800),
  }) {
    try {
      final opened = kdbxBloc.fileForKdbxFile(kdbxFile);
      final vaultId = opened.fileSource.uuid;
      _localGenerations[vaultId] = (_localGenerations[vaultId] ?? 0) + 1;
      _pendingPostSaveVaults.add(vaultId);
      unawaited(markVaultDirty(vaultId));

      _vaultDebounceTimers[vaultId]?.cancel();
      _vaultDebounceTimers[vaultId] = Timer(debounce, () {
        _vaultDebounceTimers.remove(vaultId);
        unawaited(_processPendingSyncForVault(vaultId, kdbxBloc));
      });
    } catch (e) {
      _logger.fine('Could not schedule post-save sync: $e');
    }
  }

  /// Flushes any pending debounced sync operations immediately (e.g. before app backgrounding or exit).
  Future<void> flushPendingSync(KdbxBloc kdbxBloc) async {
    for (final timer in _vaultDebounceTimers.values) {
      timer.cancel();
    }
    _vaultDebounceTimers.clear();

    final pendingVaults = Set<String>.from(_pendingPostSaveVaults);
    for (final vaultId in pendingVaults) {
      await _processPendingSyncForVault(vaultId, kdbxBloc);
    }
  }

  /// Recovers pending dirty vault synchronization on app startup/resume.
  Future<void> recoverPendingSync(KdbxBloc kdbxBloc) async {
    final cloudBloc = kdbxBloc.cloudStorageBloc;
    final authedProviders = cloudBloc.availableCloudStorage
        .where((p) => p.isAuthenticated)
        .toList();
    if (authedProviders.isEmpty) {
      return;
    }

    final openedFiles = kdbxBloc.openedFiles.entries.toList();
    for (final entry in openedFiles) {
      final vaultId = entry.key.uuid;
      bool isDirty = false;
      try {
        final gState = GoogleDriveSyncStateStore(pathUtils: PathUtils());
        if (await gState.isLocalDirty(vaultId)) {
          isDirty = true;
        }
      } catch (_) {}
      try {
        final dState = DropboxSyncStateStore(pathUtils: PathUtils());
        if (await dState.isLocalDirty(vaultId)) {
          isDirty = true;
        }
      } catch (_) {}

      if (isDirty) {
        _localGenerations[vaultId] = (_localGenerations[vaultId] ?? 0) + 1;
        _pendingPostSaveVaults.add(vaultId);
        unawaited(_processPendingSyncForVault(vaultId, kdbxBloc));
      }
    }
  }

  Future<void> _processPendingSyncForVault(
    String vaultId,
    KdbxBloc kdbxBloc,
  ) async {
    if (_vaultSyncing[vaultId] == true) {
      return;
    }

    _vaultSyncing[vaultId] = true;
    try {
      while (true) {
        final targetGen = _localGenerations[vaultId] ?? 0;
        final syncedGen = _syncedGenerations[vaultId] ?? 0;
        if (syncedGen >= targetGen && !_pendingPostSaveVaults.contains(vaultId)) {
          break;
        }

        final cloudBloc = kdbxBloc.cloudStorageBloc;
        final authedProviders = cloudBloc.availableCloudStorage
            .where((p) => p.isAuthenticated)
            .toList();

        if (authedProviders.isEmpty) {
          break;
        }

        final openedEntry = kdbxBloc.openedFiles.entries
            .firstWhereOrNull((e) => e.key.uuid == vaultId);
        if (openedEntry == null) {
          _pendingPostSaveVaults.remove(vaultId);
          break;
        }

        for (final provider in authedProviders) {
          if (!isVaultSyncEnabled(provider.id, vaultId)) {
            continue;
          }
          try {
            await syncVault(
              provider: provider,
              source: openedEntry.key,
              openedFile: openedEntry.value,
              kdbxBloc: kdbxBloc,
            );
          } catch (e, stack) {
            _logger.warning(
              'Pending sync failed for $vaultId on ${provider.id}: $e',
              stack,
            );
          }
        }

        _pendingPostSaveVaults.remove(vaultId);
        _syncedGenerations[vaultId] = targetGen;
      }
    } finally {
      _vaultSyncing[vaultId] = false;
    }
  }

  /// Synchronizes a single vault if selected or triggered.
  Future<VaultSyncResult> syncVault({
    required CloudStorageProvider provider,
    required FileSource source,
    required KdbxOpenedFile openedFile,
    required KdbxBloc kdbxBloc,
  }) async {
    final vaultId = source.uuid;
    final remoteFilename = resolveRemoteVaultFilename(source);
    final vaultDisplayName = source.displayName;
    final lock = _getLock(vaultId);

    return await lock.synchronized(() async {
      // Rule: Wait for any pending local vault saves to complete first!
      await kdbxBloc.waitForPendingSaves();

      _updateSyncInfo(
        provider.id,
        vaultId,
        KeyNestSyncStatus.syncing,
        'Synchronizing...',
      );

      try {
        if (source is FileSourceCloudStorage &&
            source.provider.id == provider.id) {
          // Vault is already native cloud-backed for this provider:
          // Flush pending local saves and upload working copy to provider asynchronously
          await kdbxBloc.waitForPendingSaves();
          await source.uploadWorkingCopy();
          final res = VaultSyncResult(
            vaultId: vaultId,
            vaultName: remoteFilename,
            status: KeyNestSyncStatus.success,
            message: 'Vault synchronized with ${provider.displayName}.',
            timestamp: DateTime.now(),
          );
          _updateSyncInfo(
            provider.id,
            vaultId,
            KeyNestSyncStatus.success,
            res.message,
          );
          return res;
        }

        // Resolves the latest flushed bytes from source asynchronously without UI blocking
        Future<Uint8List> getLatestBytes() async {
          await kdbxBloc.waitForPendingSaves();
          if (source.lastContent?.content != null &&
              source.lastContent!.content.isNotEmpty) {
            return source.lastContent!.content;
          }
          if (source is FileSourceLocal && source.filePickerIdentifier == null) {
            final f = source.file;
            if (f.existsSync()) {
              return await f.readAsBytes();
            }
          }
          final loaded = await source.content().last;
          if (loaded.content.isNotEmpty) {
            return loaded.content;
          }
          return compute((_) => openedFile.kdbxFile.save(), null);
        }

        // Vault is local or from another source: sync to this provider's KeyNest folder
        if (provider is GoogleDriveProvider) {
          final syncRes = await provider.syncEngine.syncVault(
            vaultId: vaultId,
            vaultFilename: remoteFilename,
            getLocalBytes: getLatestBytes,
            saveLocalBytes: (bytes) async {
              await source.contentWrite(bytes, metadata: null);
              unawaited(kdbxBloc.reload(openedFile).last);
            },
            unlockedLocalFile: openedFile.kdbxFile,
            credentials: openedFile.kdbxFile.credentials,
          );

          KeyNestSyncStatus status;
          if (syncRes.status == GoogleDriveSyncStatus.conflict) {
            status = KeyNestSyncStatus.conflict;
          } else if (syncRes.status == GoogleDriveSyncStatus.offline ||
              syncRes.status == GoogleDriveSyncStatus.error) {
            status = KeyNestSyncStatus.error;
          } else {
            status = KeyNestSyncStatus.success;
          }

          final res = VaultSyncResult(
            vaultId: vaultId,
            vaultName: remoteFilename,
            status: status,
            message: syncRes.message ?? 'Synchronized with Google Drive.',
            timestamp: DateTime.now(),
          );
          _updateSyncInfo(
            provider.id,
            vaultId,
            status,
            res.message,
          );
          return res;
        } else if (provider is DropboxProvider) {
          final syncRes = await provider.syncEngine.syncVault(
            vaultId: vaultId,
            vaultFilename: remoteFilename,
            getLocalBytes: getLatestBytes,
            saveLocalBytes: (bytes) async {
              await source.contentWrite(bytes, metadata: null);
              unawaited(kdbxBloc.reload(openedFile).last);
            },
            unlockedLocalFile: openedFile.kdbxFile,
            credentials: openedFile.kdbxFile.credentials,
          );

          KeyNestSyncStatus status;
          if (syncRes.status == SyncStatus.conflict) {
            status = KeyNestSyncStatus.conflict;
          } else if (syncRes.status == SyncStatus.offline ||
              syncRes.status == SyncStatus.error) {
            status = KeyNestSyncStatus.error;
          } else {
            status = KeyNestSyncStatus.success;
          }

          final res = VaultSyncResult(
            vaultId: vaultId,
            vaultName: remoteFilename,
            status: status,
            message: syncRes.message ?? 'Synchronized with Dropbox.',
            timestamp: DateTime.now(),
          );
          _updateSyncInfo(
            provider.id,
            vaultId,
            status,
            res.message,
          );
          return res;
        }

        final res = VaultSyncResult(
          vaultId: vaultId,
          vaultName: remoteFilename,
          status: KeyNestSyncStatus.error,
          message: 'Unsupported provider: ${provider.displayName}',
          timestamp: DateTime.now(),
        );
        _updateSyncInfo(
          provider.id,
          vaultId,
          KeyNestSyncStatus.error,
          res.message,
        );
        return res;
      } catch (e, stack) {
        _logger.warning('Error syncing vault $vaultDisplayName: $e', stack);
        final res = VaultSyncResult(
          vaultId: vaultId,
          vaultName: remoteFilename,
          status: KeyNestSyncStatus.error,
          message: 'Sync error: $e',
          timestamp: DateTime.now(),
        );
        _updateSyncInfo(
          provider.id,
          vaultId,
          KeyNestSyncStatus.error,
          res.message,
        );
        return res;
      }
    });
  }

  /// Synchronizes ALL vaults currently selected (checked) for [provider].
  /// Explicitly skips any vaults that are unchecked.
  Future<List<VaultSyncResult>> syncSelectedVaults({
    required CloudStorageProvider provider,
    required List<MapEntry<FileSource, KdbxOpenedFile>> openedFiles,
    required KdbxBloc kdbxBloc,
  }) async {
    await load();
    final results = <VaultSyncResult>[];

    for (final entry in openedFiles) {
      final source = entry.key;
      final isNative =
          source is FileSourceCloudStorage && source.provider.id == provider.id;
      final isEnabled = isVaultSyncEnabled(
        provider.id,
        source.uuid,
        isNativeCloudVault: isNative,
      );

      // Rule: Do not synchronize unchecked vaults
      if (!isEnabled) {
        continue;
      }

      final res = await syncVault(
        provider: provider,
        source: source,
        openedFile: entry.value,
        kdbxBloc: kdbxBloc,
      );
      results.add(res);
    }

    return results;
  }

  void _updateSyncInfo(
    String providerId,
    String vaultId,
    KeyNestSyncStatus status,
    String? message,
  ) {
    final pMap = _syncInfo.putIfAbsent(providerId, () => {});
    final existing = pMap[vaultId];
    final now = DateTime.now();

    pMap[vaultId] = VaultSyncInfo(
      status: status,
      lastSyncTime: status != KeyNestSyncStatus.syncing
          ? now
          : existing?.lastSyncTime,
      lastSuccessfulSyncTime: status == KeyNestSyncStatus.success
          ? now
          : existing?.lastSuccessfulSyncTime,
      lastAttemptedSyncTime: now,
      message: message,
    );
    _save();
    notifyListeners();
  }

  @visibleForTesting
  void updateSyncInfoForTesting(
    String providerId,
    String vaultId,
    KeyNestSyncStatus status,
    String? message,
  ) {
    _updateSyncInfo(providerId, vaultId, status, message);
  }
}
