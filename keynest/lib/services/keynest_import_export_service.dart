// ignore_for_file: always_put_control_body_on_new_line, implementation_imports
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_entry.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_merge_engine.dart';
import 'package:keynest/models/keynest_csv_mapping.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/utils/duplicate_detector.dart';
import 'package:keynest/utils/file_export_helper.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/key_file_handler.dart';
import 'package:logging/logging.dart';

final _logger = Logger('KeyNestImportExportService');

enum KeyNestImportDuplicateStrategy {
  skip,
  update,
  keepBoth,
}

/// Scope of items to be exported from a vault.
enum KeyNestExportScope {
  entireVault,
  folder,
  selectedEntries,
}

/// Selection configuration for exporting vault contents.
class KeyNestExportSelection {
  const KeyNestExportSelection.entireVault()
    : scope = KeyNestExportScope.entireVault,
      selectedFolder = null,
      selectedEntries = null;

  const KeyNestExportSelection.folder(KdbxGroup folder)
    : scope = KeyNestExportScope.folder,
      selectedFolder = folder,
      selectedEntries = null;

  const KeyNestExportSelection.entries(List<KdbxEntry> entries)
    : scope = KeyNestExportScope.selectedEntries,
      selectedFolder = null,
      selectedEntries = entries;

  final KeyNestExportScope scope;
  final KdbxGroup? selectedFolder;
  final List<KdbxEntry>? selectedEntries;
}

class KeyNestImportExportResult {
  const KeyNestImportExportResult({
    required this.success,
    this.count = 0,
    this.addedCount = 0,
    this.updatedCount = 0,
    this.skippedCount = 0,
    this.message,
    this.filePath,
    this.isCancelled = false,
  });

  final bool success;
  final int count;
  final int addedCount;
  final int updatedCount;
  final int skippedCount;
  final String? message;
  final String? filePath;
  final bool isCancelled;
}

class KeyNestImportExportService {
  /// Returns all eligible, non-deleted entries from [file], excluding any
  /// Recycle Bin groups, nested trash sub-folders, and marked trashed entries.
  static List<KdbxEntry> getExportableEntries(KdbxFile file) {
    return file.body.rootGroup
        .getAllEntries()
        .where((entry) => !KeyNestItemTypeHelper.isEntryInTrash(entry))
        .toList();
  }

  /// Resolves the list of eligible entries to export according to [selection].
  /// Always excludes Recycle Bin, nested trash, and marked deleted entries.
  static List<KdbxEntry> resolveExportEntries({
    required KdbxFile file,
    KeyNestExportSelection selection =
        const KeyNestExportSelection.entireVault(),
  }) {
    switch (selection.scope) {
      case KeyNestExportScope.entireVault:
        return getExportableEntries(file);
      case KeyNestExportScope.folder:
        final folder = selection.selectedFolder;
        if (folder == null) return [];
        return folder
            .getAllEntries()
            .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
            .toList();
      case KeyNestExportScope.selectedEntries:
        final entries = selection.selectedEntries;
        if (entries == null) return [];
        return entries
            .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
            .toList();
    }
  }

  static List<String> _getPathSegments(KdbxEntry entry, KdbxGroup rootGroup) {
    final segments = <String>[];
    var parent = entry.parent;
    while (parent != null && parent != rootGroup) {
      final name = parent.name.get();
      if (name != null && name.isNotEmpty) {
        segments.insert(0, name);
      }
      parent = parent.parent;
    }
    return segments;
  }

  static KdbxGroup _findOrCreateGroupPath(
    KdbxFile targetFile,
    KdbxGroup rootGroup,
    List<String> pathSegments,
  ) {
    var current = rootGroup;
    for (final segment in pathSegments) {
      var found = current.groups.firstWhereOrNull(
        (g) =>
            g.name.get() == segment &&
            !KeyNestItemTypeHelper.isTrashOrRecycleBin(g),
      );
      found ??= targetFile.createGroup(parent: current, name: segment);
      current = found;
    }
    return current;
  }

  static void _replicateHierarchy({
    required KdbxGroup sourceGroup,
    required KdbxGroup targetGroup,
    required KdbxFile targetFile,
    required Set<KdbxUuid> allowedEntryUuids,
  }) {
    for (final entry in sourceGroup.entries) {
      if (allowedEntryUuids.contains(entry.uuid) &&
          !KeyNestItemTypeHelper.isEntryInTrash(entry)) {
        final cloned = entry.cloneInto(targetGroup);
        for (final binEntry in entry.binaryEntries) {
          if (cloned.getBinary(binEntry.key) == null) {
            targetFile.ctx.addBinary(binEntry.value);
            cloned.createBinary(
              isProtected: binEntry.value.isProtected,
              name: binEntry.key.key,
              bytes: binEntry.value.value,
            );
          }
        }
      }
    }

    for (final subGroup in sourceGroup.groups) {
      if (KeyNestItemTypeHelper.isTrashOrRecycleBin(subGroup)) {
        continue;
      }
      final newSubGroup = targetFile.createGroup(
        parent: targetGroup,
        name: subGroup.name.get() ?? 'Folder',
      );
      _replicateHierarchy(
        sourceGroup: subGroup,
        targetGroup: newSubGroup,
        targetFile: targetFile,
        allowedEntryUuids: allowedEntryUuids,
      );
    }
  }

  /// Exports selected credentials into a brand new, independent encrypted KDBX database.
  ///
  /// The new database is initialized with its own fresh UUID and encryption header (V4),
  /// encrypted using [newMasterPassword]. The source vault [file] is never modified.
  static Future<KeyNestImportExportResult> exportKdbx({
    required KdbxBloc kdbxBloc,
    required KdbxFile file,
    String? newMasterPassword,
    Uint8List? newKeyFileBytes,
    KeyNestExportSelection selection =
        const KeyNestExportSelection.entireVault(),
    String? customFilename,
  }) async {
    try {
      final hasPassword =
          newMasterPassword != null && newMasterPassword.trim().isNotEmpty;
      final hasKeyFile = newKeyFileBytes != null && newKeyFileBytes.isNotEmpty;
      if (!hasPassword && !hasKeyFile) {
        return const KeyNestImportExportResult(
          success: false,
          message:
              'A master password or key file for the exported KDBX database is required.',
        );
      }

      final entries = resolveExportEntries(file: file, selection: selection);
      if (entries.isEmpty) {
        return const KeyNestImportExportResult(
          success: false,
          message: 'No eligible entries selected for export.',
        );
      }

      final sourceVaults = entries.map((e) => e.file).toSet();
      final isMultiVault = sourceVaults.length > 1;

      final String dbName;
      if (isMultiVault) {
        dbName = 'KeyNest_Export';
      } else {
        final name = KeyNestVaultScope.cleanVaultName(
          kdbxBloc,
          entries.first.file,
        );
        dbName = (name.isNotEmpty && name != 'Vault') ? name : 'keynest_vault';
      }
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final filename = customFilename ?? '${dbName}_export_$timestamp.kdbx';

      // 1. Create a brand new, independent KDBX database with its own credentials & header
      final Credentials newCreds;
      if (hasKeyFile) {
        newCreds = KeyNestKeyFile.createCompositeCredentials(
          password: hasPassword ? newMasterPassword : null,
          keyFileBytes: newKeyFileBytes,
        );
      } else {
        newCreds = Credentials.composite(
          ProtectedValue.fromString(newMasterPassword!),
          null,
        );
      }
      final format = kdbxBloc.kdbxFormat;
      final exportDbName = (dbName.isNotEmpty && dbName != 'Vault')
          ? dbName
          : 'Exported Vault';
      final exportFile = format.create(
        newCreds,
        exportDbName,
      );

      final allowedEntryUuids = entries.map((e) => e.uuid).toSet();

      // 2. Preserve original folder and subfolder structure
      switch (selection.scope) {
        case KeyNestExportScope.entireVault:
          _replicateHierarchy(
            sourceGroup: file.body.rootGroup,
            targetGroup: exportFile.body.rootGroup,
            targetFile: exportFile,
            allowedEntryUuids: allowedEntryUuids,
          );
          break;
        case KeyNestExportScope.folder:
          final folder = selection.selectedFolder!;
          final targetFolder = exportFile.createGroup(
            parent: exportFile.body.rootGroup,
            name: folder.name.get() ?? 'Folder',
          );
          _replicateHierarchy(
            sourceGroup: folder,
            targetGroup: targetFolder,
            targetFile: exportFile,
            allowedEntryUuids: allowedEntryUuids,
          );
          break;
        case KeyNestExportScope.selectedEntries:
          for (final entry in entries) {
            final KdbxGroup baseGroup;
            if (isMultiVault) {
              final vaultName = KeyNestVaultScope.cleanVaultName(
                kdbxBloc,
                entry.file,
              );
              baseGroup = _findOrCreateGroupPath(
                exportFile,
                exportFile.body.rootGroup,
                [vaultName],
              );
            } else {
              baseGroup = exportFile.body.rootGroup;
            }

            final segments = _getPathSegments(entry, entry.file.body.rootGroup);
            final targetGroup = _findOrCreateGroupPath(
              exportFile,
              baseGroup,
              segments,
            );
            final cloned = entry.cloneInto(targetGroup);
            for (final binEntry in entry.binaryEntries) {
              if (cloned.getBinary(binEntry.key) == null) {
                exportFile.ctx.addBinary(binEntry.value);
                cloned.createBinary(
                  isProtected: binEntry.value.isProtected,
                  name: binEntry.key.key,
                  bytes: binEntry.value.value,
                );
              }
            }
          }
          break;
      }

      // 3. Serialize and encrypt the new file using its own master password
      final bytes = await exportFile.save();

      // 4. Save file via FileExportHelper
      final path = await FileExportHelper.exportFile(
        bytes: bytes,
        filename: filename,
        mimeType: 'application/octet-stream',
      );

      if (path == null) {
        return const KeyNestImportExportResult(
          success: false,
          isCancelled: true,
          message: 'Export cancelled.',
        );
      }

      return KeyNestImportExportResult(
        success: true,
        count: entries.length,
        message:
            'Successfully exported ${entries.length} credentials to encrypted KDBX.',
        filePath: path,
      );
    } catch (e, st) {
      _logger.severe('Failed to export KDBX', e, st);
      return KeyNestImportExportResult(
        success: false,
        message: 'Failed to export KDBX: $e',
      );
    }
  }

  /// Exports entries from [file] as an unencrypted CSV document.
  static Future<KeyNestImportExportResult> exportCsv({
    required KdbxFile file,
    KdbxBloc? kdbxBloc,
    KeyNestExportSelection selection =
        const KeyNestExportSelection.entireVault(),
    String? customFilename,
  }) async {
    try {
      final entries = resolveExportEntries(file: file, selection: selection);
      if (entries.isEmpty) {
        return const KeyNestImportExportResult(
          success: false,
          message: 'No eligible entries selected for export.',
        );
      }

      final sourceVaults = entries.map((e) => e.file).toSet();
      final isMultiVault = sourceVaults.length > 1;

      final String dbName;
      if (isMultiVault) {
        dbName = 'keynest_multi_vault';
      } else {
        final name = kdbxBloc != null
            ? KeyNestVaultScope.cleanVaultName(kdbxBloc, entries.first.file)
            : FileSource.cleanDisplayName(
                file.body.meta.databaseName.get() ?? 'keynest_vault',
              );
        dbName = (name.isNotEmpty && name != 'Vault') ? name : 'keynest_vault';
      }
      final filename = customFilename ?? '${dbName}_passwords.csv';

      final buffer = StringBuffer();
      // Write UTF-8 BOM so spreadsheet viewers render Unicode properly
      buffer.write('\uFEFF');
      buffer.writeln(
        'Title,Type,Username,Password,URL,Notes,Category,Folder,TOTP,Cardholder,Expiry,CVV,PIN,Network,RecordType,CustomFields',
      );

      for (final entry in entries) {
        final rawStrings = <String, String>{};
        for (final s in entry.stringEntries) {
          rawStrings[s.key.key] = s.value?.getText() ?? '';
        }

        final title = rawStrings[KdbxKeyCommon.TITLE.key] ?? '';
        final type =
            rawStrings['KeyNest_ItemType'] ??
            rawStrings['ItemCategory'] ??
            rawStrings['RecordType'] ??
            'login';
        final username = rawStrings[KdbxKeyCommon.USER_NAME.key] ?? '';
        final password = rawStrings[KdbxKeyCommon.PASSWORD.key] ?? '';
        final url = rawStrings[KdbxKeyCommon.URL.key] ?? '';
        final notes = rawStrings[KdbxKey('Notes').key] ?? '';
        final category =
            rawStrings['KeyNest_Category'] ?? rawStrings['ItemCategory'] ?? '';
        final rawFolderPath = _getPathSegments(
          entry,
          entry.file.body.rootGroup,
        ).join('/');
        final String folderPath;
        if (isMultiVault) {
          final vaultName = kdbxBloc != null
              ? KeyNestVaultScope.cleanVaultName(kdbxBloc, entry.file)
              : 'Vault';
          folderPath = rawFolderPath.isNotEmpty
              ? '[$vaultName] / $rawFolderPath'
              : '[$vaultName]';
        } else {
          folderPath = rawFolderPath;
        }
        final totp = rawStrings['OTPAuth'] ?? rawStrings['TOTP'] ?? '';
        final cardholder = rawStrings['Cardholder'] ?? '';
        final expiry = rawStrings['Expiry'] ?? '';
        final cvv = rawStrings['CVV'] ?? '';
        final pin = rawStrings['PIN'] ?? '';
        final network = rawStrings['Network'] ?? '';
        final recordType = rawStrings['RecordType'] ?? '';

        final standardKeys = {
          KdbxKeyCommon.TITLE.key,
          KdbxKeyCommon.USER_NAME.key,
          KdbxKeyCommon.PASSWORD.key,
          KdbxKeyCommon.URL.key,
          'Notes',
          'ItemCategory',
          'KeyNest_Category',
          'KeyNest_ItemType',
          'OTPAuth',
          'TOTP',
          'Cardholder',
          'Expiry',
          'CVV',
          'PIN',
          'Network',
          'RecordType',
        };

        final extraFields = <String, String>{};
        for (final e in rawStrings.entries) {
          if (!standardKeys.contains(e.key) && e.value.isNotEmpty) {
            extraFields[e.key] = e.value;
          }
        }

        buffer.writeln(
          [
            _escapeCsv(title),
            _escapeCsv(type),
            _escapeCsv(username),
            _escapeCsv(password),
            _escapeCsv(url),
            _escapeCsv(notes),
            _escapeCsv(category),
            _escapeCsv(folderPath),
            _escapeCsv(totp),
            _escapeCsv(cardholder),
            _escapeCsv(expiry),
            _escapeCsv(cvv),
            _escapeCsv(pin),
            _escapeCsv(network),
            _escapeCsv(recordType),
            _escapeCsv(extraFields.isNotEmpty ? jsonEncode(extraFields) : ''),
          ].join(','),
        );
      }

      final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
      final path = await FileExportHelper.exportFile(
        bytes: bytes,
        filename: filename,
        mimeType: 'text/csv',
      );

      if (path == null) {
        return const KeyNestImportExportResult(
          success: false,
          isCancelled: true,
          message: 'Export cancelled.',
        );
      }

      return KeyNestImportExportResult(
        success: true,
        count: entries.length,
        message: 'Exported ${entries.length} credentials to CSV.',
        filePath: path,
      );
    } catch (e, st) {
      _logger.severe('Failed to export CSV', e, st);
      return KeyNestImportExportResult(
        success: false,
        message: 'Failed to export CSV: $e',
      );
    }
  }

  /// Exports entries from [file] as an unencrypted JSON document.
  static Future<KeyNestImportExportResult> exportJson({
    required KdbxFile file,
    KdbxBloc? kdbxBloc,
    KeyNestExportSelection selection =
        const KeyNestExportSelection.entireVault(),
    String? customFilename,
  }) async {
    try {
      final entries = resolveExportEntries(file: file, selection: selection);
      if (entries.isEmpty) {
        return const KeyNestImportExportResult(
          success: false,
          message: 'No eligible entries selected for export.',
        );
      }

      final sourceVaults = entries.map((e) => e.file).toSet();
      final isMultiVault = sourceVaults.length > 1;

      final String dbName;
      if (isMultiVault) {
        dbName = 'keynest_multi_vault';
      } else {
        final name = kdbxBloc != null
            ? KeyNestVaultScope.cleanVaultName(kdbxBloc, entries.first.file)
            : FileSource.cleanDisplayName(
                file.body.meta.databaseName.get() ?? 'keynest_vault',
              );
        dbName = (name.isNotEmpty && name != 'Vault') ? name : 'keynest_vault';
      }
      final filename = customFilename ?? '${dbName}_passwords.json';

      final list = entries.map((entry) {
        final rawStrings = <String, String>{};
        for (final s in entry.stringEntries) {
          rawStrings[s.key.key] = s.value?.getText() ?? '';
        }

        final type =
            rawStrings['KeyNest_ItemType'] ??
            rawStrings['ItemCategory'] ??
            rawStrings['RecordType'] ??
            'login';

        final rawFolderPath = _getPathSegments(
          entry,
          entry.file.body.rootGroup,
        ).join('/');
        final vaultName = kdbxBloc != null
            ? KeyNestVaultScope.cleanVaultName(kdbxBloc, entry.file)
            : 'Vault';
        final folderPath = isMultiVault && rawFolderPath.isNotEmpty
            ? '[$vaultName] / $rawFolderPath'
            : (isMultiVault ? '[$vaultName]' : rawFolderPath);

        final map = <String, dynamic>{
          'uuid': entry.uuid.uuid,
          'title': rawStrings[KdbxKeyCommon.TITLE.key] ?? '',
          'type': type,
          if (isMultiVault) 'vault': vaultName,
          'folder': folderPath,
          'username': rawStrings[KdbxKeyCommon.USER_NAME.key] ?? '',
          'password': rawStrings[KdbxKeyCommon.PASSWORD.key] ?? '',
          'url': rawStrings[KdbxKeyCommon.URL.key] ?? '',
          'notes': rawStrings[KdbxKey('Notes').key] ?? '',
          'category':
              rawStrings['KeyNest_Category'] ??
              rawStrings['ItemCategory'] ??
              '',
          'totp': rawStrings['OTPAuth'] ?? rawStrings['TOTP'] ?? '',
          'cardholder': rawStrings['Cardholder'] ?? '',
          'expiry': rawStrings['Expiry'] ?? '',
          'cvv': rawStrings['CVV'] ?? '',
          'pin': rawStrings['PIN'] ?? '',
          'network': rawStrings['Network'] ?? '',
          'recordType': rawStrings['RecordType'] ?? '',
          'fields': rawStrings,
        };
        return map;
      }).toList();

      final jsonString = const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'database': dbName,
        'exportedAt': DateTime.now().toIso8601String(),
        'items': list,
      });

      final bytes = Uint8List.fromList(utf8.encode(jsonString));
      final path = await FileExportHelper.exportFile(
        bytes: bytes,
        filename: filename,
        mimeType: 'application/json',
      );

      if (path == null) {
        return const KeyNestImportExportResult(
          success: false,
          isCancelled: true,
          message: 'Export cancelled.',
        );
      }

      return KeyNestImportExportResult(
        success: true,
        count: entries.length,
        message: 'Exported ${entries.length} credentials to JSON.',
        filePath: path,
      );
    } catch (e, st) {
      _logger.severe('Failed to export JSON', e, st);
      return KeyNestImportExportResult(
        success: false,
        message: 'Failed to export JSON: $e',
      );
    }
  }

  /// Imports and merges an external KDBX file into [targetFile].
  static Future<KeyNestImportExportResult> importKdbxBytes({
    required KdbxBloc kdbxBloc,
    required KdbxFile targetFile,
    KdbxGroup? targetGroup,
    required Uint8List bytes,
    required String password,
    Uint8List? keyFileBytes,
  }) async {
    try {
      final Credentials credentials;
      if (keyFileBytes != null && keyFileBytes.isNotEmpty) {
        credentials = KeyNestKeyFile.createCompositeCredentials(
          password: password.isNotEmpty ? password : null,
          keyFileBytes: keyFileBytes,
        );
      } else {
        credentials = Credentials(ProtectedValue.fromString(password));
      }
      final sourceFile = await kdbxBloc.kdbxFormat.read(bytes, credentials);

      // Case 1: Same vault database (replica / sync / backup restore)
      if (sourceFile.body.rootGroup.uuid == targetFile.body.rootGroup.uuid) {
        final mergeResult = DropboxVaultMergeEngine.merge(
          localFile: targetFile,
          remoteFile: sourceFile,
        );
        await kdbxBloc.saveFile(targetFile);
        return KeyNestImportExportResult(
          success: true,
          count: mergeResult.addedCount + mergeResult.updatedCount,
          message:
              'Merged replica vault: ${mergeResult.addedCount} added, ${mergeResult.updatedCount} updated, ${mergeResult.deletedCount} deleted.',
        );
      }

      // Case 2: External KDBX database import (e.g. from KeePassDX, KeePassXC, 1Password)
      // 1. Copy all binary attachments from source into target context
      for (final remoteBinary in sourceFile.ctx.binariesIterable) {
        if (targetFile.ctx.findBinaryByValue(remoteBinary) == null) {
          targetFile.ctx.addBinary(remoteBinary);
        }
      }

      // 2. Index target entries for UUID matching and duplicate reconciliation
      final targetEntriesByUuid = <KdbxUuid, KdbxEntry>{};
      final targetEntriesByFingerprint = <String, KdbxEntry>{};
      for (final entry in targetFile.body.rootGroup.getAllEntries()) {
        targetEntriesByUuid[entry.uuid] = entry;
        final fp = _entryFingerprint(entry);
        if (fp.isNotEmpty) {
          targetEntriesByFingerprint[fp] = entry;
        }
      }

      final groupCache = <KdbxUuid, KdbxGroup>{};
      final sourceRecycleBin = sourceFile.recycleBin;

      int addedCount = 0;
      int updatedCount = 0;

      final sourceEntries = sourceFile.body.rootGroup.getAllEntries().toList();
      for (final src in sourceEntries) {
        // Skip trash entries from the source database
        if (sourceRecycleBin != null &&
            _isDescendantOf(src, sourceRecycleBin)) {
          continue;
        }

        // Check if an entry with this UUID already exists in target
        KdbxEntry? existing = targetEntriesByUuid[src.uuid];

        // If not found by UUID, check by fingerprint (Title + Username + URL)
        if (existing == null) {
          final fp = _entryFingerprint(src);
          if (fp.isNotEmpty) {
            existing = targetEntriesByFingerprint[fp];
          }
        }

        if (existing != null) {
          // Reconcile and merge into existing entry
          if (_areEntriesIdentical(existing, src)) {
            continue;
          }

          final srcModTime =
              src.times.lastModificationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final existingModTime =
              existing.times.lastModificationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);

          if (srcModTime.isAfter(existingModTime)) {
            // Source is newer: archive existing into history, then update
            existing.history.add(
              existing.cloneInto(
                existing.parent ?? targetFile.body.rootGroup,
                toHistoryEntry: true,
              ),
            );
            for (final s in src.stringEntries) {
              existing.setString(s.key, s.value);
            }
            existing.icon.set(src.icon.get() ?? KdbxIcon.Key);
            existing.times.lastModificationTime.set(srcModTime);
          } else {
            // Existing is newer: push source to history so data is preserved
            existing.history.add(
              src.cloneInto(
                existing.parent ?? targetFile.body.rootGroup,
                toHistoryEntry: true,
              ),
            );
          }

          // Sync binary attachments
          for (final binEntry in src.binaryEntries) {
            if (existing.getBinary(binEntry.key) == null) {
              existing.file.ctx.addBinary(binEntry.value);
              existing.createBinary(
                isProtected: binEntry.value.isProtected,
                name: binEntry.key.key,
                bytes: binEntry.value.value,
              );
            }
          }

          // Merge custom data
          for (final cd in src.customData.entries) {
            if (!existing.customData.containsKey(cd.key)) {
              existing.customData[cd.key] = cd.value;
            }
          }

          // Merge history revisions
          final existingHistoryTimes = <DateTime>{};
          for (final h in existing.history) {
            final t = h.times.lastModificationTime.get();
            if (t != null) existingHistoryTimes.add(t);
          }
          for (final srcH in src.history) {
            final t = srcH.times.lastModificationTime.get();
            if (t != null && !existingHistoryTimes.contains(t)) {
              existingHistoryTimes.add(t);
              existing.history.add(
                srcH.cloneInto(
                  existing.parent ?? targetFile.body.rootGroup,
                  toHistoryEntry: true,
                ),
              );
            }
          }

          updatedCount++;
        } else {
          // New entry: map folder hierarchy and clone intact
          final resolvedBaseGroup = targetGroup ?? targetFile.body.rootGroup;
          final targetFolder = _findOrCreateTargetGroup(
            src.parent,
            sourceFile,
            targetFile,
            groupCache,
            baseGroup: resolvedBaseGroup,
          );

          final cloned = src.cloneInto(targetFolder);
          targetEntriesByUuid[cloned.uuid] = cloned;
          final fp = _entryFingerprint(cloned);
          if (fp.isNotEmpty) {
            targetEntriesByFingerprint[fp] = cloned;
          }

          // Ensure binaries are linked
          for (final binEntry in src.binaryEntries) {
            if (cloned.getBinary(binEntry.key) == null) {
              cloned.file.ctx.addBinary(binEntry.value);
              cloned.createBinary(
                isProtected: binEntry.value.isProtected,
                name: binEntry.key.key,
                bytes: binEntry.value.value,
              );
            }
          }

          addedCount++;
        }
      }

      await kdbxBloc.saveFile(targetFile);

      return KeyNestImportExportResult(
        success: true,
        count: addedCount + updatedCount,
        message:
            'Successfully merged KDBX: $addedCount new entries added, $updatedCount entries updated.',
      );
    } catch (e, st) {
      _logger.severe('Failed to import KDBX bytes', e, st);
      return KeyNestImportExportResult(
        success: false,
        message: 'Import failed: Incorrect password or invalid KDBX file ($e)',
      );
    }
  }

  static bool _areEntriesIdentical(KdbxEntry a, KdbxEntry b) {
    final keysA = a.stringEntries.map((e) => e.key).toSet();
    final keysB = b.stringEntries.map((e) => e.key).toSet();
    if (keysA.length != keysB.length || !keysA.containsAll(keysB)) return false;

    for (final key in keysA) {
      final valA = a.getString(key)?.getText();
      final valB = b.getString(key)?.getText();
      if (valA != valB) return false;
    }
    return true;
  }

  static String _entryFingerprint(KdbxEntry e) {
    final t =
        e.getString(KdbxKeyCommon.TITLE)?.getText()?.trim().toLowerCase() ?? '';
    final u =
        e.getString(KdbxKeyCommon.USER_NAME)?.getText()?.trim().toLowerCase() ??
        '';
    final url =
        e.getString(KdbxKeyCommon.URL)?.getText()?.trim().toLowerCase() ?? '';
    final type =
        e
            .getString(KdbxKey('KeyNest_ItemType'))
            ?.getText()
            ?.trim()
            .toLowerCase() ??
        e.getString(KdbxKey('ItemCategory'))?.getText()?.trim().toLowerCase() ??
        '';

    // Prevent silent collisions on low-entropy titles (e.g. "Card", "Note", "Untitled")
    // If username and URL are both empty, only match if high-entropy distinct fields exist
    if (t.isNotEmpty && (u.isNotEmpty || url.isNotEmpty)) {
      return '$type\x00$t\x00$u\x00$url';
    } else if (u.isNotEmpty && url.isNotEmpty) {
      return '$type\x00\x00$u\x00$url';
    }

    // For payment cards, match if title and last 4 digits of card number match
    final cardNum =
        e
            .getString(KdbxKeyCommon.PASSWORD)
            ?.getText()
            ?.replaceAll(RegExp(r'\s+'), '') ??
        '';
    if ((type == 'card' || type == 'credit card') &&
        t.isNotEmpty &&
        cardNum.length >= 4) {
      final last4 = cardNum.substring(cardNum.length - 4);
      return 'card\x00$t\x00$last4';
    }

    // Never match purely by Title if credentials or identifiers are missing
    return '';
  }

  static bool _isDescendantOf(KdbxEntry entry, KdbxGroup ancestor) {
    KdbxGroup? current = entry.parent;
    while (current != null) {
      if (current.uuid == ancestor.uuid) return true;
      current = current.parent;
    }
    return false;
  }

  static List<String> _groupPath(KdbxGroup? group, KdbxGroup root) {
    final path = <String>[];
    KdbxGroup? current = group;
    while (current != null && current.uuid != root.uuid) {
      final name = current.name.get();
      if (name != null && name.isNotEmpty) {
        path.insert(0, name);
      }
      current = current.parent;
    }
    return path;
  }

  static KdbxGroup _findOrCreateTargetGroup(
    KdbxGroup? srcGroup,
    KdbxFile sourceFile,
    KdbxFile targetFile,
    Map<KdbxUuid, KdbxGroup> cache, {
    KdbxGroup? baseGroup,
  }) {
    final root = baseGroup ?? targetFile.body.rootGroup;
    if (srcGroup == null || srcGroup.uuid == sourceFile.body.rootGroup.uuid) {
      return root;
    }
    if (cache.containsKey(srcGroup.uuid)) {
      return cache[srcGroup.uuid]!;
    }
    final path = _groupPath(srcGroup, sourceFile.body.rootGroup);
    KdbxGroup current = root;
    for (final segment in path) {
      KdbxGroup? child;
      for (final g in current.groups) {
        if (g.name.get() == segment) {
          child = g;
          break;
        }
      }
      if (child == null) {
        child = targetFile.createGroup(parent: current, name: segment);
        if (current.uuid == srcGroup.parent?.uuid) {
          child.icon.set(srcGroup.icon.get() ?? KdbxIcon.Folder);
        }
      }
      current = child;
    }
    cache[srcGroup.uuid] = current;
    return current;
  }

  /// Parses CSV text and returns raw row data with properly parsed quotes, commas, and newlines.
  static List<List<String>> parseCsv(String text) => _parseCsv(text);

  /// Parses CSV text asynchronously in a background isolate for larger files (>= 8192 chars)
  /// to ensure the main UI isolate does not drop frames.
  static Future<List<List<String>>> parseCsvAsync(String text) async {
    if (text.length < 8192) {
      return _parseCsv(text);
    }
    return await Isolate.run(() => _parseCsv(text));
  }

  /// Imports CSV rows using the specified column mappings.
  /// Mappings are strictly enforced: manual user mapping takes absolute precedence.
  static Future<KeyNestImportExportResult> importMappedCsv({
    required KdbxBloc kdbxBloc,
    required KdbxFile targetFile,
    KdbxGroup? targetGroup,
    required List<List<String>> rows,
    required List<KeyNestColumnMapping> mappings,
    KeyNestImportDuplicateStrategy duplicateStrategy =
        KeyNestImportDuplicateStrategy.skip,
  }) async {
    final newlyCreatedEntries = <KdbxEntry>[];
    try {
      if (rows.length < 2) {
        return const KeyNestImportExportResult(
          success: false,
          message: 'CSV file is empty or does not have headers.',
        );
      }

      final dataRows = rows.sublist(1);

      // Pre-resolve column indices for mapped standard fields
      final colTitle = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.title))
          ?.sourceColumnIndex;
      final colUser = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.username))
          ?.sourceColumnIndex;
      final colEmail = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.email))
          ?.sourceColumnIndex;
      final colPass = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.password))
          ?.sourceColumnIndex;
      final colUrl = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.website))
          ?.sourceColumnIndex;
      final colNotes = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.notes))
          ?.sourceColumnIndex;
      final colTotp = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.totp))
          ?.sourceColumnIndex;
      final colCategory = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.category))
          ?.sourceColumnIndex;
      final colCardholder = mappings
          .firstWhereOrNull(
            (m) => m.isStandard(KeyNestStandardField.cardholder),
          )
          ?.sourceColumnIndex;
      final colCardNumber = mappings
          .firstWhereOrNull(
            (m) => m.isStandard(KeyNestStandardField.cardNumber),
          )
          ?.sourceColumnIndex;
      final colExpiry = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.expiry))
          ?.sourceColumnIndex;
      final colCvv = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.cvv))
          ?.sourceColumnIndex;
      final colPin = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.pin))
          ?.sourceColumnIndex;
      final colTags = mappings
          .firstWhereOrNull((m) => m.isStandard(KeyNestStandardField.tags))
          ?.sourceColumnIndex;

      // Extract custom field mappings
      final customMappings = mappings
          .where(
            (m) =>
                m.destinationType ==
                    KeyNestMappingDestinationType.customField &&
                m.customFieldName != null &&
                m.customFieldName!.trim().isNotEmpty,
          )
          .toList();

      // Pre-index existing entries for fast O(1) duplicate checks
      final existingEntries = targetFile.body.rootGroup
          .getAllEntries()
          .where((e) => !e.isInRecycleBin())
          .toList();
      final titleUserIndex = <String, KdbxEntry>{};
      final urlIndex = <String, List<KdbxEntry>>{};

      for (final existing in existingEntries) {
        final t = KeyNestDuplicateDetector.normalize(
          existing.getString(KdbxKeyCommon.TITLE)?.getText(),
        );
        final u = KeyNestDuplicateDetector.normalize(
          existing.getString(KdbxKeyCommon.USER_NAME)?.getText(),
        );
        final em = KeyNestDuplicateDetector.normalize(
          existing.getString(KdbxKey('Email'))?.getText(),
        );
        final chosenUser = u.isNotEmpty ? u : em;
        if (t.isNotEmpty) {
          titleUserIndex['$t|$chosenUser'] = existing;
        }
        final urlStr = KeyNestDuplicateDetector.normalizeUrl(
          existing.getString(KdbxKeyCommon.URL)?.getText(),
        );
        if (urlStr.isNotEmpty) {
          (urlIndex[urlStr] ??= []).add(existing);
        }
      }

      int addedCount = 0;
      int updatedCount = 0;
      int skippedCount = 0;

      for (int r = 0; r < dataRows.length; r++) {
        final row = dataRows[r];
        if (row.isEmpty) continue;

        if (r > 0 && r % 100 == 0) {
          await Future<void>.delayed(Duration.zero);
        }

        String getField(int? idx) =>
            (idx != null && idx >= 0 && idx < row.length)
            ? row[idx].trim()
            : '';

        final title = getField(colTitle);
        final user = getField(colUser);
        final email = getField(colEmail);
        final pass = getField(colPass);
        final url = getField(colUrl);
        final notes = getField(colNotes);
        final totp = getField(colTotp);
        final category = getField(colCategory);
        final cardholder = getField(colCardholder);
        final cardNumber = getField(colCardNumber);
        final expiry = getField(colExpiry);
        final cvv = getField(colCvv);
        final pin = getField(colPin);
        final tags = getField(colTags);

        // Check if row has any non-empty data across standard and custom fields
        final hasCustomData = customMappings.any(
          (cm) => getField(cm.sourceColumnIndex).isNotEmpty,
        );
        if (title.isEmpty &&
            user.isEmpty &&
            email.isEmpty &&
            pass.isEmpty &&
            url.isEmpty &&
            cardholder.isEmpty &&
            notes.isEmpty &&
            !hasCustomData) {
          skippedCount++;
          continue;
        }

        final itemTitle = title.isNotEmpty
            ? title
            : (url.isNotEmpty ? url : 'Imported Item');

        // Check for duplicates
        if (duplicateStrategy != KeyNestImportDuplicateStrategy.keepBoth) {
          final normT = KeyNestDuplicateDetector.normalize(itemTitle);
          final normU = KeyNestDuplicateDetector.normalize(
            user.isNotEmpty ? user : email,
          );
          final normUrl = KeyNestDuplicateDetector.normalizeUrl(url);

          KdbxEntry? existing = titleUserIndex['$normT|$normU'];
          if (existing == null &&
              normUrl.isNotEmpty &&
              urlIndex.containsKey(normUrl)) {
            for (final cand in urlIndex[normUrl]!) {
              final candT = KeyNestDuplicateDetector.normalize(
                cand.getString(KdbxKeyCommon.TITLE)?.getText(),
              );
              if (candT == normT) {
                existing = cand;
                break;
              }
            }
          }

          if (existing != null) {
            if (duplicateStrategy == KeyNestImportDuplicateStrategy.skip) {
              skippedCount++;
              continue;
            } else if (duplicateStrategy ==
                KeyNestImportDuplicateStrategy.update) {
              existing.history.add(
                existing.cloneInto(
                  existing.parent ?? targetFile.body.rootGroup,
                  toHistoryEntry: true,
                ),
              );
              if (itemTitle.isNotEmpty) {
                existing.setString(KdbxKeyCommon.TITLE, PlainValue(itemTitle));
              }
              if (user.isNotEmpty) {
                existing.setString(KdbxKeyCommon.USER_NAME, PlainValue(user));
              }
              if (email.isNotEmpty) {
                existing.setString(KdbxKey('Email'), PlainValue(email));
              }
              if (pass.isNotEmpty) {
                existing.setString(
                  KdbxKeyCommon.PASSWORD,
                  ProtectedValue.fromString(pass),
                );
              }
              if (url.isNotEmpty) {
                existing.setString(KdbxKeyCommon.URL, PlainValue(url));
              }
              if (notes.isNotEmpty) {
                existing.setString(KdbxKey('Notes'), PlainValue(notes));
              }
              if (category.isNotEmpty) {
                existing.setString(
                  KdbxKey('ItemCategory'),
                  PlainValue(category),
                );
              }
              if (totp.isNotEmpty) {
                existing.setString(
                  KdbxKey('OTPAuth'),
                  ProtectedValue.fromString(totp),
                );
              }
              if (cardholder.isNotEmpty) {
                existing.setString(
                  KdbxKey('Cardholder'),
                  PlainValue(cardholder),
                );
              }
              if (cardNumber.isNotEmpty) {
                existing.setString(
                  KdbxKey('CardNumber'),
                  PlainValue(cardNumber),
                );
              }
              if (expiry.isNotEmpty) {
                existing.setString(KdbxKey('Expiry'), PlainValue(expiry));
              }
              if (cvv.isNotEmpty) {
                existing.setString(
                  KdbxKey('CVV'),
                  ProtectedValue.fromString(cvv),
                );
              }
              if (pin.isNotEmpty) {
                existing.setString(
                  KdbxKey('PIN'),
                  ProtectedValue.fromString(pin),
                );
              }
              if (tags.isNotEmpty) {
                existing.setString(KdbxKey('Tags'), PlainValue(tags));
              }
              for (final cm in customMappings) {
                final val = getField(cm.sourceColumnIndex);
                if (val.isNotEmpty) {
                  existing.setString(
                    KdbxKey(cm.customFieldName!.trim()),
                    PlainValue(val),
                  );
                }
              }
              existing.times.lastModificationTime.set(DateTime.now().toUtc());
              updatedCount++;
              continue;
            }
          }
        }

        final destinationFolder = targetGroup ?? targetFile.body.rootGroup;
        final newEntry = kdbxBloc.createEntry(
          file: targetFile,
          group: destinationFolder,
        );
        newlyCreatedEntries.add(newEntry);
        newEntry.setString(KdbxKeyCommon.TITLE, PlainValue(itemTitle));
        if (user.isNotEmpty) {
          newEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue(user));
        }
        if (email.isNotEmpty) {
          newEntry.setString(KdbxKey('Email'), PlainValue(email));
        }
        if (pass.isNotEmpty) {
          newEntry.setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString(pass),
          );
        }
        if (url.isNotEmpty) {
          newEntry.setString(KdbxKeyCommon.URL, PlainValue(url));
        }
        if (notes.isNotEmpty) {
          newEntry.setString(KdbxKey('Notes'), PlainValue(notes));
        }
        if (category.isNotEmpty) {
          newEntry.setString(KdbxKey('ItemCategory'), PlainValue(category));
        }
        if (totp.isNotEmpty) {
          newEntry.setString(
            KdbxKey('OTPAuth'),
            ProtectedValue.fromString(totp),
          );
        }
        if (cardholder.isNotEmpty) {
          newEntry.setString(KdbxKey('Cardholder'), PlainValue(cardholder));
        }
        if (cardNumber.isNotEmpty) {
          newEntry.setString(KdbxKey('CardNumber'), PlainValue(cardNumber));
        }
        if (expiry.isNotEmpty) {
          newEntry.setString(KdbxKey('Expiry'), PlainValue(expiry));
        }
        if (cvv.isNotEmpty) {
          newEntry.setString(KdbxKey('CVV'), ProtectedValue.fromString(cvv));
        }
        if (pin.isNotEmpty) {
          newEntry.setString(KdbxKey('PIN'), ProtectedValue.fromString(pin));
        }
        if (tags.isNotEmpty) {
          newEntry.setString(KdbxKey('Tags'), PlainValue(tags));
        }

        for (final cm in customMappings) {
          final val = getField(cm.sourceColumnIndex);
          if (val.isNotEmpty) {
            newEntry.setString(
              KdbxKey(cm.customFieldName!.trim()),
              PlainValue(val),
            );
          }
        }

        final normT = KeyNestDuplicateDetector.normalize(itemTitle);
        final normU = KeyNestDuplicateDetector.normalize(
          user.isNotEmpty ? user : email,
        );
        if (normT.isNotEmpty) {
          titleUserIndex['$normT|$normU'] = newEntry;
        }

        addedCount++;
      }

      await kdbxBloc.saveFile(targetFile);

      final totalProcessed = addedCount + updatedCount;
      final msgParts = <String>[];
      if (addedCount > 0) msgParts.add('$addedCount added');
      if (updatedCount > 0) msgParts.add('$updatedCount updated');
      if (skippedCount > 0) msgParts.add('$skippedCount duplicates skipped');

      return KeyNestImportExportResult(
        success: true,
        count: totalProcessed,
        addedCount: addedCount,
        updatedCount: updatedCount,
        skippedCount: skippedCount,
        message: 'CSV Import complete: ${msgParts.join(', ')}.',
      );
    } catch (e, st) {
      _logger.severe('Failed to parse or save CSV', e, st);
      for (final created in newlyCreatedEntries) {
        try {
          targetFile.deletePermanently(created);
        } catch (_) {}
      }
      return KeyNestImportExportResult(
        success: false,
        message: 'Failed to import CSV: $e',
      );
    }
  }

  /// Parses and imports CSV data from Bitwarden, LastPass, 1Password, or standard CSV format.
  /// Uses automatic column detection to map recognized headers.
  static Future<KeyNestImportExportResult> importCsvText({
    required KdbxBloc kdbxBloc,
    required KdbxFile targetFile,
    KdbxGroup? targetGroup,
    required String csvText,
    KeyNestImportDuplicateStrategy duplicateStrategy =
        KeyNestImportDuplicateStrategy.skip,
  }) async {
    final rows = _parseCsv(csvText);
    if (rows.length < 2) {
      return const KeyNestImportExportResult(
        success: false,
        message: 'CSV file is empty or does not have headers.',
      );
    }
    final mappings = KeyNestCsvMappingHelper.autoDetectMappings(rows.first);
    return importMappedCsv(
      kdbxBloc: kdbxBloc,
      targetFile: targetFile,
      targetGroup: targetGroup,
      rows: rows,
      mappings: mappings,
      duplicateStrategy: duplicateStrategy,
    );
  }

  /// Parses and imports JSON data exported from KeyNest or Bitwarden.
  static Future<KeyNestImportExportResult> importJsonText({
    required KdbxBloc kdbxBloc,
    required KdbxFile targetFile,
    KdbxGroup? targetGroup,
    required String jsonText,
    KeyNestImportDuplicateStrategy duplicateStrategy =
        KeyNestImportDuplicateStrategy.skip,
  }) async {
    final newlyCreatedEntries = <KdbxEntry>[];
    try {
      final decoded = json.decode(jsonText);
      List<dynamic> itemsList = [];
      if (decoded is List) {
        itemsList = decoded;
      } else if (decoded is Map<String, dynamic>) {
        if (decoded['items'] is List) {
          itemsList = decoded['items'] as List;
        } else if (decoded['encrypted'] == true) {
          return const KeyNestImportExportResult(
            success: false,
            message:
                'Encrypted JSON exports cannot be imported directly without their encryption key.',
          );
        }
      }

      if (itemsList.isEmpty) {
        return const KeyNestImportExportResult(
          success: false,
          message: 'No valid credential items found in JSON.',
        );
      }

      int addedCount = 0;
      int updatedCount = 0;
      int skippedCount = 0;

      for (final raw in itemsList) {
        if (raw is! Map<String, dynamic>) continue;

        String title = '';
        String user = '';
        String pass = '';
        String url = '';
        String notes = '';
        String category = '';
        String totp = '';

        if (raw.containsKey('title') || raw.containsKey('username')) {
          title = raw['title']?.toString().trim() ?? '';
          user = raw['username']?.toString().trim() ?? '';
          pass = raw['password']?.toString().trim() ?? '';
          url = raw['url']?.toString().trim() ?? '';
          notes = raw['notes']?.toString().trim() ?? '';
          category = raw['category']?.toString().trim() ?? '';
          totp = raw['totp']?.toString().trim() ?? '';
        } else {
          // Bitwarden JSON structure
          title = raw['name']?.toString().trim() ?? '';
          notes = raw['notes']?.toString().trim() ?? '';
          if (raw['login'] is Map) {
            final login = raw['login'] as Map;
            user = login['username']?.toString().trim() ?? '';
            pass = login['password']?.toString().trim() ?? '';
            totp = login['totp']?.toString().trim() ?? '';
            if (login['uris'] is List && (login['uris'] as List).isNotEmpty) {
              final firstUri = (login['uris'] as List).first;
              if (firstUri is Map) {
                url = firstUri['uri']?.toString().trim() ?? '';
              } else if (firstUri is String) {
                url = firstUri.trim();
              }
            }
          }
        }

        if (title.isEmpty && user.isEmpty && pass.isEmpty) continue;

        final itemTitle = title.isNotEmpty
            ? title
            : (url.isNotEmpty ? url : 'Imported Item');

        if (duplicateStrategy != KeyNestImportDuplicateStrategy.keepBoth) {
          final matches = KeyNestDuplicateDetector.findMatchesForCredential(
            file: targetFile,
            title: itemTitle,
            username: user,
            url: url,
            password: pass,
          );

          if (matches.isNotEmpty) {
            if (duplicateStrategy == KeyNestImportDuplicateStrategy.skip) {
              skippedCount++;
              continue;
            } else if (duplicateStrategy ==
                KeyNestImportDuplicateStrategy.update) {
              final existing = matches.first.existingEntry;
              existing.history.add(
                existing.cloneInto(
                  existing.parent ?? targetFile.body.rootGroup,
                  toHistoryEntry: true,
                ),
              );
              if (itemTitle.isNotEmpty) {
                existing.setString(KdbxKeyCommon.TITLE, PlainValue(itemTitle));
              }
              if (user.isNotEmpty) {
                existing.setString(KdbxKeyCommon.USER_NAME, PlainValue(user));
              }
              if (pass.isNotEmpty) {
                existing.setString(
                  KdbxKeyCommon.PASSWORD,
                  ProtectedValue.fromString(pass),
                );
              }
              if (url.isNotEmpty) {
                existing.setString(KdbxKeyCommon.URL, PlainValue(url));
              }
              if (notes.isNotEmpty) {
                existing.setString(KdbxKey('Notes'), PlainValue(notes));
              }
              if (category.isNotEmpty) {
                existing.setString(
                  KdbxKey('ItemCategory'),
                  PlainValue(category),
                );
              }
              if (totp.isNotEmpty) {
                existing.setString(
                  KdbxKey('OTPAuth'),
                  ProtectedValue.fromString(totp),
                );
              }
              existing.times.lastModificationTime.set(DateTime.now().toUtc());
              updatedCount++;
              continue;
            }
          }
        }

        final destinationFolder = targetGroup ?? targetFile.body.rootGroup;
        final newEntry = kdbxBloc.createEntry(
          file: targetFile,
          group: destinationFolder,
        );
        newlyCreatedEntries.add(newEntry);
        newEntry.setString(KdbxKeyCommon.TITLE, PlainValue(itemTitle));
        if (user.isNotEmpty) {
          newEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue(user));
        }
        if (pass.isNotEmpty) {
          newEntry.setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString(pass),
          );
        }
        if (url.isNotEmpty) {
          newEntry.setString(KdbxKeyCommon.URL, PlainValue(url));
        }
        if (notes.isNotEmpty) {
          newEntry.setString(KdbxKey('Notes'), PlainValue(notes));
        }
        if (category.isNotEmpty) {
          newEntry.setString(KdbxKey('ItemCategory'), PlainValue(category));
        }
        if (totp.isNotEmpty) {
          newEntry.setString(
            KdbxKey('OTPAuth'),
            ProtectedValue.fromString(totp),
          );
        }

        // Preserve all extra supported fields from JSON
        final cardholder = raw['cardholder']?.toString().trim() ?? '';
        if (cardholder.isNotEmpty) {
          newEntry.setString(KdbxKey('Cardholder'), PlainValue(cardholder));
        }
        final expiry = raw['expiry']?.toString().trim() ?? '';
        if (expiry.isNotEmpty) {
          newEntry.setString(KdbxKey('Expiry'), PlainValue(expiry));
        }
        final cvv = raw['cvv']?.toString().trim() ?? '';
        if (cvv.isNotEmpty) {
          newEntry.setString(KdbxKey('CVV'), ProtectedValue.fromString(cvv));
        }
        final pin = raw['pin']?.toString().trim() ?? '';
        if (pin.isNotEmpty) {
          newEntry.setString(KdbxKey('PIN'), ProtectedValue.fromString(pin));
        }
        final network = raw['network']?.toString().trim() ?? '';
        if (network.isNotEmpty) {
          newEntry.setString(KdbxKey('Network'), PlainValue(network));
        }
        final recordType = raw['recordType']?.toString().trim() ?? '';
        if (recordType.isNotEmpty) {
          newEntry.setString(KdbxKey('RecordType'), PlainValue(recordType));
        }
        final itemType =
            raw['type']?.toString().trim() ??
            raw['itemType']?.toString().trim() ??
            '';
        if (itemType.isNotEmpty) {
          newEntry.setString(KdbxKey('KeyNest_ItemType'), PlainValue(itemType));
        }

        if (raw['fields'] is Map) {
          final fields = raw['fields'] as Map;
          final standardJsonKeys = {
            'Title',
            'UserName',
            'Password',
            'URL',
            'Notes',
            'ItemCategory',
            'OTPAuth',
            'Cardholder',
            'Expiry',
            'CVV',
            'PIN',
            'Network',
            'RecordType',
            'KeyNest_ItemType',
            'KeyNest_Category',
          };
          for (final f in fields.entries) {
            final k = f.key.toString();
            final v = f.value?.toString() ?? '';
            if (!standardJsonKeys.contains(k) && v.isNotEmpty) {
              newEntry.setString(KdbxKey(k), PlainValue(v));
            }
          }
        }

        addedCount++;
      }

      await kdbxBloc.saveFile(targetFile);

      final totalProcessed = addedCount + updatedCount;
      final msgParts = <String>[];
      if (addedCount > 0) msgParts.add('$addedCount added');
      if (updatedCount > 0) msgParts.add('$updatedCount updated');
      if (skippedCount > 0) msgParts.add('$skippedCount duplicates skipped');

      return KeyNestImportExportResult(
        success: true,
        count: totalProcessed,
        addedCount: addedCount,
        updatedCount: updatedCount,
        skippedCount: skippedCount,
        message: 'JSON Import complete: ${msgParts.join(', ')}.',
      );
    } catch (e, st) {
      _logger.severe('Failed to parse or save JSON', e, st);
      for (final created in newlyCreatedEntries) {
        try {
          targetFile.deletePermanently(created);
        } catch (_) {}
      }
      return KeyNestImportExportResult(
        success: false,
        message: 'Failed to import JSON: $e',
      );
    }
  }

  static String _escapeCsv(String val) {
    if (val.contains(',') ||
        val.contains('"') ||
        val.contains('\n') ||
        val.contains('\r')) {
      return '"${val.replaceAll('"', '""')}"';
    }
    return val;
  }

  static List<List<String>> _parseCsv(String text) {
    final rows = <List<String>>[];
    final currentRow = <String>[];
    final currentField = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < text.length; i++) {
      final c = text[i];
      if (c == '"') {
        if (inQuotes && i + 1 < text.length && text[i + 1] == '"') {
          currentField.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (c == ',' && !inQuotes) {
        currentRow.add(currentField.toString());
        currentField.clear();
      } else if ((c == '\n' || c == '\r') && !inQuotes) {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
          i++;
        }
        currentRow.add(currentField.toString());
        currentField.clear();
        if (currentRow.any((s) => s.trim().isNotEmpty)) {
          rows.add(List.from(currentRow));
        }
        currentRow.clear();
      } else {
        currentField.write(c);
      }
    }
    if (currentField.isNotEmpty || currentRow.isNotEmpty) {
      currentRow.add(currentField.toString());
      if (currentRow.any((s) => s.trim().isNotEmpty)) {
        rows.add(currentRow);
      }
    }
    return rows;
  }
}
