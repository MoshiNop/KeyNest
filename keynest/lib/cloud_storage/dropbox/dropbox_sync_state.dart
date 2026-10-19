// ignore_for_file: avoid_slow_async_io

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:keynest/utils/path_utils.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('dropbox_sync_state');

/// Information about a saved local timestamped vault backup.
class DropboxBackupInfo {
  DropboxBackupInfo({
    required this.vaultId,
    required this.timestamp,
    required this.filePath,
    required this.fileSizeBytes,
  });

  final String vaultId;
  final DateTime timestamp;
  final String filePath;
  final int fileSizeBytes;

  String get displayName {
    final year = timestamp.year;
    final month = timestamp.month.toString().padLeft(2, '0');
    final day = timestamp.day.toString().padLeft(2, '0');
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final second = timestamp.second.toString().padLeft(2, '0');
    return 'Backup $year-$month-$day $hour:$minute:$second (${(fileSizeBytes / 1024).toStringAsFixed(1)} KB)';
  }
}

/// Stores sync metadata, the encrypted base copy (common ancestor),
/// dirty flags, and manages rotating local backups.
class DropboxSyncStateStore {
  DropboxSyncStateStore({
    PathUtils? pathUtils,
    Directory? overrideSyncDir,
  }) : _pathUtils = pathUtils ?? PathUtils(),
       _overrideSyncDir = overrideSyncDir;

  final PathUtils _pathUtils;
  final Directory? _overrideSyncDir;

  Future<Directory> _getSyncDir() async {
    final overrideDir = _overrideSyncDir;
    if (overrideDir != null) {
      if (!await overrideDir.exists()) {
        await overrideDir.create(recursive: true);
      }
      return overrideDir;
    }
    final appDataDir = await _pathUtils.getAppDataDirectory();
    final syncDir = Directory(p.join(appDataDir.path, 'dropbox_sync'));
    if (!await syncDir.exists()) {
      await syncDir.create(recursive: true);
    }
    return syncDir;
  }

  Future<Directory> _getBackupDir() async {
    final syncDir = await _getSyncDir();
    final backupDir = Directory(p.join(syncDir.path, 'backups'));
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    return backupDir;
  }

  File _getMetadataFile(Directory dir) =>
      File(p.join(dir.path, 'metadata.json'));

  Future<Map<String, dynamic>> _readMetadata() async {
    final dir = await _getSyncDir();
    final file = _getMetadataFile(dir);
    if (!await file.exists()) {
      return {};
    }
    try {
      final content = await file.readAsString();
      return json.decode(content) as Map<String, dynamic>;
    } catch (e) {
      _logger.warning('Failed to read sync metadata: $e');
      return {};
    }
  }

  Future<void> _writeMetadata(Map<String, dynamic> data) async {
    final dir = await _getSyncDir();
    final file = _getMetadataFile(dir);
    await file.writeAsString(json.encode(data), flush: true);
  }

  String _sanitizeVaultId(String vaultId) =>
      vaultId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

  // Revision Management
  Future<String?> getLastSyncedRev(String vaultId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final vaultData =
        vaults[_sanitizeVaultId(vaultId)] as Map<String, dynamic>?;
    return vaultData?['last_synced_rev'] as String?;
  }

  Future<void> setLastSyncedRev(String vaultId, String? rev) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final key = _sanitizeVaultId(vaultId);
    final vaultData = vaults[key] as Map<String, dynamic>? ?? {};
    if (rev != null) {
      vaultData['last_synced_rev'] = rev;
      vaultData['last_synced_time'] = DateTime.now().toIso8601String();
    } else {
      vaultData.remove('last_synced_rev');
    }
    vaults[key] = vaultData;
    data['vaults'] = vaults;
    await _writeMetadata(data);
  }

  Future<DateTime?> getLastSyncedTime(String vaultId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final vaultData =
        vaults[_sanitizeVaultId(vaultId)] as Map<String, dynamic>?;
    final timeStr = vaultData?['last_synced_time'] as String?;
    return timeStr != null ? DateTime.tryParse(timeStr) : null;
  }

  // Local Dirty Flag
  Future<bool> isLocalDirty(String vaultId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final vaultData =
        vaults[_sanitizeVaultId(vaultId)] as Map<String, dynamic>?;
    return vaultData?['local_dirty'] as bool? ?? false;
  }

  Future<void> setLocalDirty(String vaultId, bool dirty) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final key = _sanitizeVaultId(vaultId);
    final vaultData = vaults[key] as Map<String, dynamic>? ?? {};
    vaultData['local_dirty'] = dirty;
    vaults[key] = vaultData;
    data['vaults'] = vaults;
    await _writeMetadata(data);
  }

  Future<void> markLocalDirty(String vaultId) => setLocalDirty(vaultId, true);

  // Base Copy (Common ancestor for 3-way merge)
  Future<File> _getBaseCopyFile(String vaultId) async {
    final dir = await _getSyncDir();
    return File(p.join(dir.path, 'base_${_sanitizeVaultId(vaultId)}.kdbx'));
  }

  Future<Uint8List?> getBaseCopy(String vaultId) async {
    final file = await _getBaseCopyFile(vaultId);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<void> setBaseCopy(String vaultId, Uint8List encryptedBytes) async {
    final file = await _getBaseCopyFile(vaultId);
    // Write atomically via temp file
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsBytes(encryptedBytes, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  Future<void> deleteBaseCopy(String vaultId) async {
    final file = await _getBaseCopyFile(vaultId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  // Local Rolling Backups
  /// Creates a local timestamped backup of the current vault and keeps at most the last 5 backups.
  Future<DropboxBackupInfo> createBackup({
    required String vaultId,
    required Uint8List currentVaultBytes,
  }) async {
    final backupDir = await _getBackupDir();
    final sanitized = _sanitizeVaultId(vaultId);
    final now = DateTime.now();
    final timestampStr = now.millisecondsSinceEpoch.toString();
    final backupFilePath = p.join(
      backupDir.path,
      'vault_${sanitized}_$timestampStr.kdbx',
    );

    final backupFile = File(backupFilePath);
    await backupFile.writeAsBytes(currentVaultBytes, flush: true);

    // Enforce 5 backup limit
    await _rotateBackups(vaultId);

    return DropboxBackupInfo(
      vaultId: vaultId,
      timestamp: now,
      filePath: backupFilePath,
      fileSizeBytes: currentVaultBytes.length,
    );
  }

  Future<void> _rotateBackups(String vaultId) async {
    final backups = await listBackups(vaultId);
    if (backups.length > 5) {
      // Keep first 5, delete index 5 onwards
      for (var i = 5; i < backups.length; i++) {
        final file = File(backups[i].filePath);
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (e) {
            _logger.warning('Failed to delete old backup: $e');
          }
        }
      }
    }
  }

  /// Lists available local backups for this vault, newest first.
  Future<List<DropboxBackupInfo>> listBackups(String vaultId) async {
    final backupDir = await _getBackupDir();
    final sanitized = _sanitizeVaultId(vaultId);
    final prefix = 'vault_${sanitized}_';
    final entities = await backupDir.list().toList();

    final List<DropboxBackupInfo> backups = [];
    for (final entity in entities) {
      if (entity is File && p.basename(entity.path).startsWith(prefix)) {
        final filename = p.basenameWithoutExtension(entity.path);
        final parts = filename.split('_');
        final timestampEpoch = int.tryParse(parts.last);
        if (timestampEpoch != null) {
          final time = DateTime.fromMillisecondsSinceEpoch(timestampEpoch);
          final length = await entity.length();
          backups.add(
            DropboxBackupInfo(
              vaultId: vaultId,
              timestamp: time,
              filePath: entity.path,
              fileSizeBytes: length,
            ),
          );
        }
      }
    }

    backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return backups;
  }

  // Disconnect and Logout Cleanup
  /// Deletes all sync state (stored revs, base copies, dirty flags)
  /// while keeping the user's actual local vault and local backups intact.
  Future<void> clearAllSyncState() async {
    final dir = await _getSyncDir();
    final metadataFile = _getMetadataFile(dir);
    if (await metadataFile.exists()) {
      await metadataFile.delete();
    }

    final entities = await dir.list().toList();
    for (final entity in entities) {
      if (entity is File && p.basename(entity.path).startsWith('base_')) {
        try {
          await entity.delete();
        } catch (e) {
          _logger.warning('Failed to delete base copy file: $e');
        }
      }
    }
    _logger.info('Cleared Dropbox sync state (rev, base copies, flags).');
  }

  /// Clears sync state, base copies, and backups for a single vault when it is disconnected or deleted.
  Future<void> clearVaultSyncState(String vaultId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>?;
    final sanitized = _sanitizeVaultId(vaultId);
    if (vaults != null && vaults.containsKey(sanitized)) {
      vaults.remove(sanitized);
      data['vaults'] = vaults;
      await _writeMetadata(data);
    }

    final baseFile = await _getBaseCopyFile(vaultId);
    if (await baseFile.exists()) {
      try {
        await baseFile.delete();
      } catch (e) {
        _logger.warning('Failed to delete Dropbox base copy for $vaultId: $e');
      }
    }

    final backups = await listBackups(vaultId);
    for (final b in backups) {
      try {
        final f = File(b.filePath);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (e) {
        _logger.warning('Failed to delete backup ${b.filePath}: $e');
      }
    }
    _logger.info(
      'Cleared Dropbox sync state, base copy, and backups for vault $vaultId.',
    );
  }
}
