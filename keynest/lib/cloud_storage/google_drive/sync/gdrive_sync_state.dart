// ignore_for_file: avoid_slow_async_io

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:keynest/utils/path_utils.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('gdrive_sync_state');

/// Information about a saved local timestamped vault backup for Google Drive.
class GoogleDriveBackupInfo {
  GoogleDriveBackupInfo({
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

/// Stores sync metadata for Google Drive:
/// - drive_file_id
/// - last_synced_md5
/// - last_synced_version
/// - encrypted base copy (common ancestor)
/// - local_dirty flag
/// - rotating last 5 local backups
class GoogleDriveSyncStateStore {
  GoogleDriveSyncStateStore({
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
    final syncDir = Directory(p.join(appDataDir.path, 'gdrive_sync'));
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
      _logger.warning('Failed to read Google Drive sync metadata: $e');
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

  // Drive File ID
  Future<String?> getDriveFileId(String vaultId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final vaultData =
        vaults[_sanitizeVaultId(vaultId)] as Map<String, dynamic>?;
    return vaultData?['drive_file_id'] as String?;
  }

  Future<void> setDriveFileId(String vaultId, String? fileId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final key = _sanitizeVaultId(vaultId);
    final vaultData = vaults[key] as Map<String, dynamic>? ?? {};
    if (fileId != null) {
      vaultData['drive_file_id'] = fileId;
    } else {
      vaultData.remove('drive_file_id');
    }
    vaults[key] = vaultData;
    data['vaults'] = vaults;
    await _writeMetadata(data);
  }

  String sanitizeVaultId(String vaultId) => _sanitizeVaultId(vaultId);

  /// Resolves the vault ID that currently owns [fileId] in metadata, or null if unclaimed.
  Future<String?> findVaultIdByDriveFileId(String fileId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    for (final entry in vaults.entries) {
      final vData = entry.value as Map<String, dynamic>?;
      if (vData?['drive_file_id'] == fileId) {
        return entry.key;
      }
    }
    return null;
  }

  // KeyNest Visible Folder ID
  Future<String?> getKeyNestFolderId() async {
    final data = await _readMetadata();
    return data['keynest_folder_id'] as String?;
  }

  Future<void> setKeyNestFolderId(String? folderId) async {
    final data = await _readMetadata();
    if (folderId != null) {
      data['keynest_folder_id'] = folderId;
    } else {
      data.remove('keynest_folder_id');
    }
    await _writeMetadata(data);
  }

  // Legacy Migration Tracking
  Future<bool> isVaultMigrated(String vaultId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final vaultData =
        vaults[_sanitizeVaultId(vaultId)] as Map<String, dynamic>?;
    return vaultData?['is_migrated_visible'] as bool? ?? false;
  }

  Future<void> setVaultMigrated(String vaultId, bool migrated) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final key = _sanitizeVaultId(vaultId);
    final vaultData = vaults[key] as Map<String, dynamic>? ?? {};
    vaultData['is_migrated_visible'] = migrated;
    vaults[key] = vaultData;
    data['vaults'] = vaults;
    await _writeMetadata(data);
  }

  Future<String?> getLegacyDriveFileId(String vaultId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final vaultData =
        vaults[_sanitizeVaultId(vaultId)] as Map<String, dynamic>?;
    return vaultData?['legacy_drive_file_id'] as String?;
  }

  Future<void> setLegacyDriveFileId(String vaultId, String? legacyId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final key = _sanitizeVaultId(vaultId);
    final vaultData = vaults[key] as Map<String, dynamic>? ?? {};
    if (legacyId != null) {
      vaultData['legacy_drive_file_id'] = legacyId;
    } else {
      vaultData.remove('legacy_drive_file_id');
    }
    vaults[key] = vaultData;
    data['vaults'] = vaults;
    await _writeMetadata(data);
  }

  Future<String?> getMigratedFileIdForLegacyId(String legacyId) async {
    final data = await _readMetadata();
    final map = data['legacy_migration_map'] as Map<String, dynamic>?;
    return map?[legacyId] as String?;
  }

  Future<void> recordLegacyMigration(String legacyId, String newId) async {
    final data = await _readMetadata();
    final map = data['legacy_migration_map'] as Map<String, dynamic>? ?? {};
    map[legacyId] = newId;
    data['legacy_migration_map'] = map;
    await _writeMetadata(data);
  }

  // MD5 & Version
  Future<String?> getLastSyncedMd5(String vaultId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final vaultData =
        vaults[_sanitizeVaultId(vaultId)] as Map<String, dynamic>?;
    return vaultData?['last_synced_md5'] as String?;
  }

  Future<int?> getLastSyncedVersion(String vaultId) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final vaultData =
        vaults[_sanitizeVaultId(vaultId)] as Map<String, dynamic>?;
    final val = vaultData?['last_synced_version'];
    if (val is int) {
      return val;
    }
    if (val is String) {
      return int.tryParse(val);
    }
    return null;
  }

  Future<void> setSyncCheckpoint({
    required String vaultId,
    required String? md5,
    required int? version,
    String? driveFileId,
  }) async {
    final data = await _readMetadata();
    final vaults = data['vaults'] as Map<String, dynamic>? ?? {};
    final key = _sanitizeVaultId(vaultId);
    final vaultData = vaults[key] as Map<String, dynamic>? ?? {};

    if (md5 != null) {
      vaultData['last_synced_md5'] = md5;
      vaultData['last_synced_time'] = DateTime.now().toIso8601String();
    } else {
      vaultData.remove('last_synced_md5');
    }

    if (version != null) {
      vaultData['last_synced_version'] = version;
    } else {
      vaultData.remove('last_synced_version');
    }

    if (driveFileId != null) {
      vaultData['drive_file_id'] = driveFileId;
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
  Future<void> markLocalClean(String vaultId) => setLocalDirty(vaultId, false);

  // Base Copy (Common Ancestor)
  File _getBaseFile(Directory dir, String vaultId) =>
      File(p.join(dir.path, 'base_${_sanitizeVaultId(vaultId)}.kdbx'));

  Future<Uint8List?> getBaseCopy(String vaultId) async {
    final dir = await _getSyncDir();
    final file = _getBaseFile(dir, vaultId);
    if (!await file.exists()) {
      return null;
    }
    return await file.readAsBytes();
  }

  Future<void> setBaseCopy(String vaultId, Uint8List bytes) async {
    final dir = await _getSyncDir();
    final file = _getBaseFile(dir, vaultId);
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsBytes(bytes, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  Future<bool> hasBaseCopy(String vaultId) async {
    final dir = await _getSyncDir();
    final file = _getBaseFile(dir, vaultId);
    return await file.exists();
  }

  // Local Rolling Backups
  Future<File> createBackup({
    required String vaultId,
    required Uint8List currentVaultBytes,
  }) async {
    final backupDir = await _getBackupDir();
    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
    final filename = 'backup_${timestamp}_${_sanitizeVaultId(vaultId)}.kdbx';
    final backupFile = File(p.join(backupDir.path, filename));

    await backupFile.writeAsBytes(currentVaultBytes, flush: true);
    await _pruneOldBackups(vaultId);
    return backupFile;
  }

  Future<List<GoogleDriveBackupInfo>> listBackups(String vaultId) async {
    final backupDir = await _getBackupDir();
    if (!await backupDir.exists()) {
      return [];
    }

    final prefix = 'backup_';
    final suffix = '_${_sanitizeVaultId(vaultId)}.kdbx';
    final entries = await backupDir.list().toList();
    final backups = <GoogleDriveBackupInfo>[];

    for (final entity in entries) {
      if (entity is! File) {
        continue;
      }
      final basename = p.basename(entity.path);
      if (basename.startsWith(prefix) && basename.endsWith(suffix)) {
        try {
          final timestampPart = basename.substring(
            prefix.length,
            basename.length - suffix.length,
          );
          final normIso = timestampPart.replaceFirst(
            RegExp(r'-(\d{2})-(\d{2}\.\d+)'),
            r':$1:$2',
          );
          final dt =
              DateTime.tryParse(normIso) ?? (await entity.lastModified());
          final length = await entity.length();
          backups.add(
            GoogleDriveBackupInfo(
              vaultId: vaultId,
              timestamp: dt.toLocal(),
              filePath: entity.path,
              fileSizeBytes: length,
            ),
          );
        } catch (_) {}
      }
    }

    backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return backups;
  }

  Future<void> _pruneOldBackups(String vaultId) async {
    final backups = await listBackups(vaultId);
    if (backups.length > 5) {
      final toRemove = backups.sublist(5);
      for (final b in toRemove) {
        try {
          final f = File(b.filePath);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (e) {
          _logger.warning('Failed to delete old backup: ${b.filePath}: $e');
        }
      }
    }
  }

  // Disconnect Cleanup
  /// Cleans up Google Drive sync state and base copies upon disconnect,
  /// while keeping local vault files completely untouched.
  Future<void> clearSyncState() async {
    final dir = await _getSyncDir();
    final metaFile = _getMetadataFile(dir);
    if (await metaFile.exists()) {
      await metaFile.delete();
    }

    final entities = await dir.list().toList();
    for (final entity in entities) {
      if (entity is File && p.basename(entity.path).startsWith('base_')) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
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

    final dir = await _getSyncDir();
    final baseFile = _getBaseFile(dir, vaultId);
    if (await baseFile.exists()) {
      try {
        await baseFile.delete();
      } catch (e) {
        _logger.warning(
          'Failed to delete Google Drive base copy for $vaultId: $e',
        );
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
      'Cleared Google Drive sync state, base copy, and backups for vault $vaultId.',
    );
  }
}
