// ignore_for_file: implementation_imports, invalid_use_of_visible_for_testing_member, invalid_use_of_internal_member, always_put_control_body_on_new_line, prefer_final_locals

import 'package:flutter/foundation.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_deleted_object.dart';
import 'package:kdbx/src/kdbx_entry.dart';
import 'package:kdbx/src/kdbx_group.dart';
import 'package:kdbx/src/kdbx_object.dart';
import 'package:keynest/utils/item_type_helper.dart';

/// Thrown when databases cannot be decrypted with current credentials (master password changed on another device).
class DropboxMergeCredentialMismatchException implements Exception {
  DropboxMergeCredentialMismatchException(this.message);
  final String message;

  @override
  String toString() => 'DropboxMergeCredentialMismatchException: $message';
}

/// Thrown when merged database fails integrity validation checks.
class DropboxMergeValidationException implements Exception {
  DropboxMergeValidationException(this.message);
  final String message;

  @override
  String toString() => 'DropboxMergeValidationException: $message';
}

/// Result summary of an in-memory 3-way merge operation.
class DropboxMergeResult {
  DropboxMergeResult({
    required this.addedCount,
    required this.updatedCount,
    required this.deletedCount,
  });

  final int addedCount;
  final int updatedCount;
  final int deletedCount;

  int totalChanges() => addedCount + updatedCount + deletedCount;

  String get summary =>
      'Merged: $addedCount added, $updatedCount updated, $deletedCount deleted.';

  @override
  String toString() => summary;
}

/// In-memory 3-way KDBX merge engine implementing rules (a)–(j) and validation rule (3).
///
/// Runs strictly in memory using already unlocked databases.
/// Never persists credentials, derived keys, or decrypted data to disk.
class DropboxVaultMergeEngine {
  /// Executes a 3-way merge: LOCAL + REMOTE against BASE common ancestor.
  /// Modifies [localFile] in-memory to become the valid merged database.
  static DropboxMergeResult merge({
    required KdbxFile localFile,
    required KdbxFile remoteFile,
    KdbxFile? baseFile,
  }) {
    // 0. Identity check on root groups
    if (localFile.body.rootGroup.uuid != remoteFile.body.rootGroup.uuid) {
      throw DropboxMergeCredentialMismatchException(
        'Root group UUID mismatch between local and remote databases.',
      );
    }

    int addedCount = 0;
    int updatedCount = 0;
    int deletedCount = 0;

    // 1. Sync Binaries / Attachments (Rule g)
    _mergeBinaries(localFile, remoteFile);

    // 2. Sync Database Metadata (Rule i)
    _mergeMetadata(localFile, remoteFile);

    // 3. Process Deletions (Rule e)
    final survivingDeletions = _computeSurvivingDeletions(
      localFile: localFile,
      remoteFile: remoteFile,
      baseFile: baseFile,
    );

    // Initial active entry set for validation rule 3
    final initialLocalEntries = _collectAllEntries(localFile.body.rootGroup);
    final initialRemoteEntries = _collectAllEntries(remoteFile.body.rootGroup);
    final expectedActiveUuids = <KdbxUuid>{
      ...initialLocalEntries.keys,
      ...initialRemoteEntries.keys,
    }..removeWhere(survivingDeletions.containsKey);

    // 4. Merge Groups Hierarchy (Rule f)
    _mergeGroups(
      localFile: localFile,
      remoteFile: remoteFile,
      baseFile: baseFile,
      survivingDeletions: survivingDeletions,
    );

    // 5. Merge Entries (Rules a, b, c, d, e, j)
    final entryResult = _mergeEntries(
      localFile: localFile,
      remoteFile: remoteFile,
      baseFile: baseFile,
      survivingDeletions: survivingDeletions,
    );
    addedCount += entryResult.addedCount;
    updatedCount += entryResult.updatedCount;
    deletedCount += entryResult.deletedCount;

    // 6. Update DeletedObjects list with surviving deletions
    _updateDeletedObjects(localFile, survivingDeletions);

    // 7. Validate Merged Database (Rule 3)
    _validateMergedDatabase(
      localFile: localFile,
      expectedActiveUuids: expectedActiveUuids,
    );

    return DropboxMergeResult(
      addedCount: addedCount,
      updatedCount: updatedCount,
      deletedCount: deletedCount,
    );
  }

  // 1. Binaries (KeePass Rule g)
  static void _mergeBinaries(KdbxFile localFile, KdbxFile remoteFile) {
    for (final remoteBinary in remoteFile.ctx.binariesIterable) {
      if (localFile.ctx.findBinaryByValue(remoteBinary) == null) {
        localFile.ctx.addBinary(remoteBinary);
      }
    }
  }

  // 2. Metadata (KeePass Rule i)
  static void _mergeMetadata(KdbxFile localFile, KdbxFile remoteFile) {
    final localMeta = localFile.body.meta;
    final remoteMeta = remoteFile.body.meta;

    final remoteNameChanged = remoteMeta.databaseNameChanged.get();
    final localNameChanged = localMeta.databaseNameChanged.get();
    if (remoteNameChanged != null &&
        (localNameChanged == null ||
            remoteNameChanged.isAfter(localNameChanged))) {
      localMeta.databaseName.set(remoteMeta.databaseName.get());
      localMeta.databaseNameChanged.set(remoteNameChanged);
    }

    final remoteDescChanged = remoteMeta.databaseDescriptionChanged.get();
    final localDescChanged = localMeta.databaseDescriptionChanged.get();
    if (remoteDescChanged != null &&
        (localDescChanged == null ||
            remoteDescChanged.isAfter(localDescChanged))) {
      localMeta.databaseDescription.set(remoteMeta.databaseDescription.get());
      localMeta.databaseDescriptionChanged.set(remoteDescChanged);
    }

    final remoteUserChanged = remoteMeta.defaultUserNameChanged.get();
    final localUserChanged = localMeta.defaultUserNameChanged.get();
    if (remoteUserChanged != null &&
        (localUserChanged == null ||
            remoteUserChanged.isAfter(localUserChanged))) {
      localMeta.defaultUserName.set(remoteMeta.defaultUserName.get());
      localMeta.defaultUserNameChanged.set(remoteUserChanged);
    }

    // Merge Custom Icons on Database
    for (final icon in remoteMeta.customIcons.values) {
      if (!localMeta.customIcons.containsKey(icon.uuid)) {
        localMeta.addCustomIcon(
          KdbxCustomIcon(uuid: icon.uuid, data: icon.data),
        );
      }
    }

    // Merge Custom Data on Database (Rule h)
    _mergeCustomData(localMeta.customData, remoteMeta.customData);
  }

  // 3. Deletions (KeePass Rule e)
  static Map<KdbxUuid, DateTime> _computeSurvivingDeletions({
    required KdbxFile localFile,
    required KdbxFile remoteFile,
    KdbxFile? baseFile,
  }) {
    final allDeletions = <KdbxUuid, DateTime>{};

    for (final del in localFile.body.deletedObjects) {
      final time =
          del.deletionTime.get() ?? DateTime.fromMillisecondsSinceEpoch(0);
      allDeletions[del.uuid] = time;
    }
    for (final del in remoteFile.body.deletedObjects) {
      final time =
          del.deletionTime.get() ?? DateTime.fromMillisecondsSinceEpoch(0);
      final existing = allDeletions[del.uuid];
      if (existing == null || time.isAfter(existing)) {
        allDeletions[del.uuid] = time;
      }
    }

    final localObjects = _collectAllObjects(localFile.body.rootGroup);
    final remoteObjects = _collectAllObjects(remoteFile.body.rootGroup);

    final surviving = <KdbxUuid, DateTime>{};

    for (final entry in allDeletions.entries) {
      final uuid = entry.key;
      final deletionTime = entry.value;

      final localObj = localObjects[uuid];
      final remoteObj = remoteObjects[uuid];

      final localModTime = localObj?.times.lastModificationTime.get();
      final remoteModTime = remoteObj?.times.lastModificationTime.get();

      // Rule e: A deletion wins ONLY if deletionTime is newer than other side's LastModificationTime
      bool overriddenByLocal =
          localModTime != null && localModTime.isAfter(deletionTime);
      bool overriddenByRemote =
          remoteModTime != null && remoteModTime.isAfter(deletionTime);

      if (!overriddenByLocal && !overriddenByRemote) {
        surviving[uuid] = deletionTime;
      }
    }

    return surviving;
  }

  // 4. Groups (KeePass Rule f)
  static void _mergeGroups({
    required KdbxFile localFile,
    required KdbxFile remoteFile,
    KdbxFile? baseFile,
    required Map<KdbxUuid, DateTime> survivingDeletions,
  }) {
    final localGroups = _collectAllGroups(localFile.body.rootGroup);
    final remoteGroups = _collectAllGroups(remoteFile.body.rootGroup);

    // 1. Add missing remote groups if not legitimately deleted
    for (final remoteGroup in remoteGroups.values) {
      if (remoteGroup.uuid == remoteFile.body.rootGroup.uuid) continue;
      if (localGroups.containsKey(remoteGroup.uuid)) continue;

      if (survivingDeletions.containsKey(remoteGroup.uuid)) {
        continue; // Legitimately deleted
      }

      final parentUuid = remoteGroup.parent?.uuid;
      KdbxGroup? targetParent = parentUuid != null
          ? localGroups[parentUuid]
          : null;
      targetParent ??= localFile.body.rootGroup;

      final newGroup =
          KdbxGroup.create(
              ctx: localFile.ctx,
              parent: targetParent,
              name: remoteGroup.name.get(),
            )
            ..forceSetUuid(remoteGroup.uuid)
            ..icon.set(remoteGroup.icon.get() ?? KdbxIcon.Folder);
      _applyGroupCustomIcon(localFile, newGroup, remoteGroup.customIcon);
      targetParent.addGroup(newGroup);
      localGroups[remoteGroup.uuid] = newGroup;
    }

    // 2. Remove locally deleted groups (reparenting any children to root group per Rule f)
    for (final localGroup in localGroups.values.toList()) {
      if (localGroup.uuid == localFile.body.rootGroup.uuid) continue;
      if (survivingDeletions.containsKey(localGroup.uuid)) {
        for (final subGroup in localGroup.groups.toList()) {
          localGroup.internalRemoveGroup(subGroup);
          subGroup.internalChangeParent(localFile.body.rootGroup);
          localFile.body.rootGroup.addGroup(subGroup);
        }
        for (final entry in localGroup.entries.toList()) {
          localGroup.internalRemoveEntry(entry);
          entry.internalChangeParent(localFile.body.rootGroup);
          localFile.body.rootGroup.addEntry(entry);
        }
        localGroup.parent?.internalRemoveGroup(localGroup);
        localGroups.remove(localGroup.uuid);
      }
    }

    // 3. Merge group properties and moves (Rule f)
    for (final remoteGroup in remoteGroups.values) {
      if (remoteGroup.uuid == remoteFile.body.rootGroup.uuid) continue;
      final localGroup = localGroups[remoteGroup.uuid];
      if (localGroup == null) continue;

      final localModTime =
          localGroup.times.lastModificationTime.get() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final remoteModTime =
          remoteGroup.times.lastModificationTime.get() ??
          DateTime.fromMillisecondsSinceEpoch(0);

      if (remoteModTime.isAfter(localModTime)) {
        localGroup.name.set(remoteGroup.name.get());
        localGroup.icon.set(remoteGroup.icon.get() ?? KdbxIcon.Folder);
        _applyGroupCustomIcon(localFile, localGroup, remoteGroup.customIcon);
        localGroup.notes.set(remoteGroup.notes.get());
      }

      // Location / Moves: compare LocationChanged
      final localLocTime =
          localGroup.times.locationChanged.get() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final remoteLocTime =
          remoteGroup.times.locationChanged.get() ??
          DateTime.fromMillisecondsSinceEpoch(0);

      if (remoteLocTime.isAfter(localLocTime)) {
        final targetParentUuid = remoteGroup.parent?.uuid;
        KdbxGroup? targetParent = targetParentUuid != null
            ? localGroups[targetParentUuid]
            : null;
        targetParent ??= localFile.body.rootGroup;

        if (localGroup.parent != targetParent) {
          localGroup.parent?.internalRemoveGroup(localGroup);
          localGroup.internalChangeParent(targetParent);
          targetParent.addGroup(localGroup);
          localGroup.times.locationChanged.set(remoteLocTime);
        }
      }
    }

    // 4. Reparent orphaned groups whose parent was deleted back to root (Rule f)
    for (final group in _collectAllGroups(localFile.body.rootGroup).values) {
      if (group.uuid == localFile.body.rootGroup.uuid) continue;
      if (group.parent == null ||
          !localGroups.containsKey(group.parent?.uuid)) {
        group.parent?.internalRemoveGroup(group);
        group.internalChangeParent(localFile.body.rootGroup);
        localFile.body.rootGroup.addGroup(group);
      }
    }
  }

  // 5. Entries (KeePass Rules a, b, c, d, e, j)
  static DropboxMergeResult _mergeEntries({
    required KdbxFile localFile,
    required KdbxFile remoteFile,
    KdbxFile? baseFile,
    required Map<KdbxUuid, DateTime> survivingDeletions,
  }) {
    int added = 0;
    int updated = 0;
    int deleted = 0;

    final localEntries = _collectAllEntries(localFile.body.rootGroup);
    final remoteEntries = _collectAllEntries(remoteFile.body.rootGroup);
    final baseEntries = baseFile != null
        ? _collectAllEntries(baseFile.body.rootGroup)
        : <KdbxUuid, KdbxEntry>{};
    final localGroups = _collectAllGroups(localFile.body.rootGroup);

    // Rule b & e: Process deletions for entries in LOCAL
    for (final localEntry in localEntries.values.toList()) {
      if (survivingDeletions.containsKey(localEntry.uuid)) {
        localEntry.parent?.internalRemoveEntry(localEntry);
        localEntries.remove(localEntry.uuid);
        deleted++;
      }
    }

    // Rule b: Entry only in REMOTE
    for (final remoteEntry in remoteEntries.values) {
      if (localEntries.containsKey(remoteEntry.uuid)) continue;

      if (survivingDeletions.containsKey(remoteEntry.uuid)) {
        continue; // Legitimately deleted
      }

      // Add to localFile
      final parentUuid = remoteEntry.parent?.uuid;
      KdbxGroup? targetParent = parentUuid != null
          ? localGroups[parentUuid]
          : null;
      targetParent ??= localFile.body.rootGroup;

      final cloned = remoteEntry.cloneInto(targetParent);
      _applyEntryCustomIcon(localFile, cloned, remoteEntry.customIcon);
      localEntries[remoteEntry.uuid] = cloned;
      added++;
    }

    // Rule c, d, j: Entries in BOTH LOCAL and REMOTE
    for (final remoteEntry in remoteEntries.values) {
      final localEntry = localEntries[remoteEntry.uuid];
      if (localEntry == null) continue;

      final baseEntry = baseEntries[remoteEntry.uuid];

      // Check if entry contents differ
      if (!_areEntriesIdentical(localEntry, remoteEntry)) {
        _mergeSingleEntryContent(
          localFile: localFile,
          localEntry: localEntry,
          remoteEntry: remoteEntry,
          baseEntry: baseEntry,
        );
        updated++;
      }

      // Merge Entry History (Rules c & d)
      _mergeEntryHistory(localEntry, remoteEntry);

      // Custom data union (Rule h)
      _mergeCustomData(localEntry.customData, remoteEntry.customData);

      // Moves: LocationChanged (Rule f)
      final localLocTime =
          localEntry.times.locationChanged.get() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final remoteLocTime =
          remoteEntry.times.locationChanged.get() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      if (remoteLocTime.isAfter(localLocTime)) {
        final targetParentUuid = remoteEntry.parent?.uuid;
        KdbxGroup? targetParent = targetParentUuid != null
            ? localGroups[targetParentUuid]
            : null;
        targetParent ??= localFile.body.rootGroup;
        if (localEntry.parent != targetParent) {
          localEntry.parent?.internalRemoveEntry(localEntry);
          localEntry.internalChangeParent(targetParent);
          targetParent.addEntry(localEntry);
          localEntry.times.locationChanged.set(remoteLocTime);
        }
      }
    }

    return DropboxMergeResult(
      addedCount: added,
      updatedCount: updated,
      deletedCount: deleted,
    );
  }

  static void _mergeSingleEntryContent({
    required KdbxFile localFile,
    required KdbxEntry localEntry,
    required KdbxEntry remoteEntry,
    KdbxEntry? baseEntry,
  }) {
    final localModTime =
        localEntry.times.lastModificationTime.get() ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final remoteModTime =
        remoteEntry.times.lastModificationTime.get() ??
        DateTime.fromMillisecondsSinceEpoch(0);

    // Rule j: Field-by-field merge when BASE is available
    if (baseEntry != null) {
      final preMergeLocalSnapshot = localEntry.parent != null
          ? localEntry.cloneInto(localEntry.parent!, toHistoryEntry: true)
          : null;
      bool recordedConflictHistory = false;

      void recordConflict({required bool remoteWins}) {
        if (recordedConflictHistory || localEntry.parent == null) return;
        if (remoteWins) {
          if (preMergeLocalSnapshot != null) {
            localEntry.history.add(preMergeLocalSnapshot);
          }
        } else {
          localEntry.history.add(
            remoteEntry.cloneInto(localEntry.parent!, toHistoryEntry: true),
          );
        }
        recordedConflictHistory = true;
      }

      // 1. String fields (including custom field additions & deletions)
      final localKeys = localEntry.stringEntries.map((e) => e.key).toSet();
      final remoteKeys = remoteEntry.stringEntries.map((e) => e.key).toSet();
      final baseKeys = baseEntry.stringEntries.map((e) => e.key).toSet();
      final allKeys = <KdbxKey>{...localKeys, ...remoteKeys, ...baseKeys};

      for (final key in allKeys) {
        final hasBase = baseKeys.contains(key);
        final hasLocal = localKeys.contains(key);
        final hasRemote = remoteKeys.contains(key);
        final baseVal = baseEntry.getString(key)?.getText();
        final localVal = localEntry.getString(key)?.getText();
        final remoteVal = remoteEntry.getString(key)?.getText();

        final localChanged = (hasLocal != hasBase) || (localVal != baseVal);
        final remoteChanged = (hasRemote != hasBase) || (remoteVal != baseVal);

        if (!localChanged && remoteChanged) {
          if (hasRemote) {
            localEntry.setString(key, remoteEntry.getString(key));
          } else {
            localEntry.removeString(key);
          }
        } else if (localChanged && remoteChanged) {
          final sameOutcome = hasLocal == hasRemote && localVal == remoteVal;
          if (sameOutcome) {
            if (hasLocal &&
                hasRemote &&
                localEntry.getString(key) is! ProtectedValue &&
                remoteEntry.getString(key) is ProtectedValue) {
              localEntry.setString(key, remoteEntry.getString(key));
            }
          } else if (remoteModTime.isAfter(localModTime)) {
            recordConflict(remoteWins: true);
            if (hasRemote) {
              localEntry.setString(key, remoteEntry.getString(key));
            } else {
              localEntry.removeString(key);
            }
          } else {
            recordConflict(remoteWins: false);
          }
        } else if (!localChanged && !remoteChanged && hasLocal && hasRemote) {
          final localIsProtected = localEntry.getString(key) is ProtectedValue;
          final remoteIsProtected =
              remoteEntry.getString(key) is ProtectedValue;
          if (!localIsProtected && remoteIsProtected) {
            localEntry.setString(key, remoteEntry.getString(key));
          }
        }
      }

      // 2. Binary attachments (including attachment additions, updates, & deletions)
      final allBinKeys = <KdbxKey>{
        ...localEntry.binaryEntries.map((e) => e.key),
        ...remoteEntry.binaryEntries.map((e) => e.key),
        ...baseEntry.binaryEntries.map((e) => e.key),
      };
      for (final binKey in allBinKeys) {
        final baseBin = baseEntry.getBinary(binKey);
        final localBin = localEntry.getBinary(binKey);
        final remoteBin = remoteEntry.getBinary(binKey);

        final localBinChanged = !_binariesEqual(localBin, baseBin);
        final remoteBinChanged = !_binariesEqual(remoteBin, baseBin);

        if (!localBinChanged && remoteBinChanged) {
          _setOrRemoveBinary(localEntry, binKey, remoteBin);
        } else if (localBinChanged &&
            remoteBinChanged &&
            !_binariesEqual(localBin, remoteBin)) {
          if (remoteModTime.isAfter(localModTime)) {
            recordConflict(remoteWins: true);
            _setOrRemoveBinary(localEntry, binKey, remoteBin);
          } else {
            recordConflict(remoteWins: false);
          }
        }
      }

      // 3. Standard & custom icons
      final baseIcon = baseEntry.icon.get();
      final localIcon = localEntry.icon.get();
      final remoteIcon = remoteEntry.icon.get();
      final baseCustomUuid = baseEntry.customIcon?.uuid;
      final localCustomUuid = localEntry.customIcon?.uuid;
      final remoteCustomUuid = remoteEntry.customIcon?.uuid;

      final localIconChanged =
          localIcon != baseIcon || localCustomUuid != baseCustomUuid;
      final remoteIconChanged =
          remoteIcon != baseIcon || remoteCustomUuid != baseCustomUuid;

      if (!localIconChanged && remoteIconChanged) {
        localEntry.icon.set(remoteIcon ?? KdbxIcon.Key);
        _applyEntryCustomIcon(localFile, localEntry, remoteEntry.customIcon);
      } else if (localIconChanged &&
          remoteIconChanged &&
          (localIcon != remoteIcon || localCustomUuid != remoteCustomUuid)) {
        if (remoteModTime.isAfter(localModTime)) {
          recordConflict(remoteWins: true);
          localEntry.icon.set(remoteIcon ?? KdbxIcon.Key);
          _applyEntryCustomIcon(localFile, localEntry, remoteEntry.customIcon);
        } else {
          recordConflict(remoteWins: false);
        }
      }

      // 4. Tags
      final baseTags = baseEntry.tags.get() ?? '';
      final localTags = localEntry.tags.get() ?? '';
      final remoteTags = remoteEntry.tags.get() ?? '';
      final localTagsChanged = localTags != baseTags;
      final remoteTagsChanged = remoteTags != baseTags;
      if (!localTagsChanged && remoteTagsChanged) {
        _applyTags(localEntry, remoteEntry.tags.get());
      } else if (localTagsChanged &&
          remoteTagsChanged &&
          localTags != remoteTags) {
        if (remoteModTime.isAfter(localModTime)) {
          recordConflict(remoteWins: true);
          _applyTags(localEntry, remoteEntry.tags.get());
        } else {
          recordConflict(remoteWins: false);
        }
      }

      // 5. Expiry metadata
      final baseExpires = baseEntry.times.expires.get() ?? false;
      final localExpires = localEntry.times.expires.get() ?? false;
      final remoteExpires = remoteEntry.times.expires.get() ?? false;
      final baseExpMs =
          baseEntry.times.expiryTime.get()?.millisecondsSinceEpoch;
      final localExpMs =
          localEntry.times.expiryTime.get()?.millisecondsSinceEpoch;
      final remoteExpMs =
          remoteEntry.times.expiryTime.get()?.millisecondsSinceEpoch;

      final localExpChanged =
          localExpires != baseExpires || localExpMs != baseExpMs;
      final remoteExpChanged =
          remoteExpires != baseExpires || remoteExpMs != baseExpMs;
      if (!localExpChanged && remoteExpChanged) {
        _applyExpiry(localEntry, remoteEntry);
      } else if (localExpChanged &&
          remoteExpChanged &&
          (localExpires != remoteExpires || localExpMs != remoteExpMs)) {
        if (remoteModTime.isAfter(localModTime)) {
          recordConflict(remoteWins: true);
          _applyExpiry(localEntry, remoteEntry);
        } else {
          recordConflict(remoteWins: false);
        }
      }

      // Update timestamps
      if (remoteModTime.isAfter(localModTime)) {
        localEntry.times.lastModificationTime.set(remoteModTime);
      }
      KeyNestItemTypeHelper.upgradeEntrySensitiveFields(localEntry);
      return;
    }

    // Without BASE: Rules c & d
    if (remoteModTime.isAfter(localModTime)) {
      // REMOTE is newer: add LOCAL into History, replace LOCAL state with REMOTE
      if (localEntry.parent != null) {
        localEntry.history.add(
          localEntry.cloneInto(localEntry.parent!, toHistoryEntry: true),
        );
      }
      final remoteStringKeys =
          remoteEntry.stringEntries.map((e) => e.key).toSet();
      for (final existing in localEntry.stringEntries.toList()) {
        if (!remoteStringKeys.contains(existing.key)) {
          localEntry.removeString(existing.key);
        }
      }
      for (final s in remoteEntry.stringEntries) {
        localEntry.setString(s.key, s.value);
      }

      final remoteBinKeys =
          remoteEntry.binaryEntries.map((e) => e.key).toSet();
      for (final existingBin in localEntry.binaryEntries.toList()) {
        if (!remoteBinKeys.contains(existingBin.key)) {
          localEntry.removeBinary(existingBin.key);
        }
      }
      for (final bin in remoteEntry.binaryEntries) {
        _setOrRemoveBinary(localEntry, bin.key, bin.value);
      }

      localEntry.icon.set(remoteEntry.icon.get() ?? KdbxIcon.Key);
      _applyEntryCustomIcon(localFile, localEntry, remoteEntry.customIcon);
      _applyTags(localEntry, remoteEntry.tags.get());
      _applyExpiry(localEntry, remoteEntry);
      localEntry.times.lastModificationTime.set(remoteModTime);
    } else {
      // LOCAL is newer or identical timestamp: push REMOTE into History, keep LOCAL
      if (localEntry.parent != null) {
        localEntry.history.add(
          remoteEntry.cloneInto(localEntry.parent!, toHistoryEntry: true),
        );
      }
    }
    KeyNestItemTypeHelper.upgradeEntrySensitiveFields(localEntry);
  }

  static void _mergeEntryHistory(KdbxEntry localEntry, KdbxEntry remoteEntry) {
    final seenTimes = <DateTime>{};
    for (final h in localEntry.history) {
      final t = h.times.lastModificationTime.get();
      if (t != null) seenTimes.add(t);
    }

    for (final remoteH in remoteEntry.history) {
      final t = remoteH.times.lastModificationTime.get();
      if (t != null && !seenTimes.contains(t)) {
        seenTimes.add(t);
        localEntry.history.add(
          remoteH.cloneInto(localEntry.parent!, toHistoryEntry: true),
        );
      }
    }

    // Sort history by LastModificationTime ascending
    localEntry.history.sort((a, b) {
      final ta =
          a.times.lastModificationTime.get() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final tb =
          b.times.lastModificationTime.get() ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return ta.compareTo(tb);
    });

    // Cap history by vault limit (max 10 entries)
    const maxHistoryEntries = 10;
    while (localEntry.history.length > maxHistoryEntries) {
      localEntry.history.removeAt(0);
    }
  }

  static void _mergeCustomData(
    KdbxCustomData localData,
    KdbxCustomData remoteData,
  ) {
    for (final entry in remoteData.entries) {
      if (!localData.containsKey(entry.key)) {
        localData[entry.key] = entry.value;
      }
    }
  }

  static void _updateDeletedObjects(
    KdbxFile localFile,
    Map<KdbxUuid, DateTime> survivingDeletions,
  ) {
    localFile.body.deletedObjects.clear();
    for (final entry in survivingDeletions.entries) {
      localFile.body.deletedObjects.add(
        KdbxDeletedObject.create(localFile.ctx, entry.key, entry.value),
      );
    }
  }

  // 6. Validation (KeePass Rule 3)
  static void _validateMergedDatabase({
    required KdbxFile localFile,
    required Set<KdbxUuid> expectedActiveUuids,
  }) {
    final seenUuids = <KdbxUuid>{};
    final allGroups = _collectAllGroups(localFile.body.rootGroup);
    final allEntries = _collectAllEntries(localFile.body.rootGroup);

    // 1. Every entry and group UUID is unique
    for (final g in allGroups.values) {
      if (!seenUuids.add(g.uuid)) {
        throw DropboxMergeValidationException(
          'Duplicate group UUID: ${g.uuid}',
        );
      }
    }
    for (final e in allEntries.values) {
      if (!seenUuids.add(e.uuid)) {
        throw DropboxMergeValidationException(
          'Duplicate entry UUID: ${e.uuid}',
        );
      }
    }

    // 2. No entry or group is orphaned
    for (final g in allGroups.values) {
      if (g.uuid == localFile.body.rootGroup.uuid) continue;
      if (g.parent == null || !allGroups.containsKey(g.parent?.uuid)) {
        throw DropboxMergeValidationException(
          'Orphaned group found: ${g.uuid}',
        );
      }
    }
    for (final e in allEntries.values) {
      if (e.parent == null || !allGroups.containsKey(e.parent?.uuid)) {
        throw DropboxMergeValidationException(
          'Orphaned entry found: ${e.uuid}',
        );
      }
    }

    // 3. Every active (non-deleted) entry from LOCAL and REMOTE must survive
    for (final expectedUuid in expectedActiveUuids) {
      if (!allEntries.containsKey(expectedUuid)) {
        throw DropboxMergeValidationException(
          'Active entry lost during merge: $expectedUuid',
        );
      }
    }
    if (allEntries.length < expectedActiveUuids.length) {
      throw DropboxMergeValidationException(
        'Entry count dropped below threshold: found ${allEntries.length}, expected at least ${expectedActiveUuids.length}',
      );
    }
  }

  static void _applyGroupCustomIcon(
    KdbxFile localFile,
    KdbxGroup targetGroup,
    KdbxCustomIcon? customIcon,
  ) {
    if (customIcon != null) {
      if (!localFile.body.meta.customIcons.containsKey(customIcon.uuid)) {
        localFile.body.meta.addCustomIcon(
          KdbxCustomIcon(uuid: customIcon.uuid, data: customIcon.data),
        );
      }
      targetGroup.customIcon =
          localFile.body.meta.customIcons[customIcon.uuid] ?? customIcon;
    } else {
      targetGroup.customIcon = null;
    }
  }

  static void _applyEntryCustomIcon(
    KdbxFile localFile,
    KdbxEntry targetEntry,
    KdbxCustomIcon? customIcon,
  ) {
    if (customIcon != null) {
      if (!localFile.body.meta.customIcons.containsKey(customIcon.uuid)) {
        localFile.body.meta.addCustomIcon(
          KdbxCustomIcon(uuid: customIcon.uuid, data: customIcon.data),
        );
      }
      targetEntry.customIcon =
          localFile.body.meta.customIcons[customIcon.uuid] ?? customIcon;
    } else {
      targetEntry.customIcon = null;
    }
  }

  static void _applyTags(KdbxEntry targetEntry, String? tags) {
    if (tags != null && tags.isNotEmpty) {
      targetEntry.tags.set(tags);
    } else {
      targetEntry.tags.remove();
    }
  }

  static void _applyExpiry(KdbxEntry targetEntry, KdbxEntry sourceEntry) {
    final expires = sourceEntry.times.expires.get();
    if (expires != null) {
      targetEntry.times.expires.set(expires);
    }
    final expiryTime = sourceEntry.times.expiryTime.get();
    if (expiryTime != null) {
      targetEntry.times.expiryTime.set(expiryTime);
    }
  }

  static bool _binariesEqual(KdbxBinary? a, KdbxBinary? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.isProtected == b.isProtected && listEquals(a.value, b.value);
  }

  static void _setOrRemoveBinary(
    KdbxEntry target,
    KdbxKey key,
    KdbxBinary? bin,
  ) {
    if (target.getBinary(key) != null) {
      target.removeBinary(key);
    }
    if (bin != null) {
      target.file.ctx.addBinary(bin);
      target.createBinary(
        isProtected: bin.isProtected,
        name: key.key,
        bytes: bin.value,
      );
    }
  }

  // Helper utilities
  static Map<KdbxUuid, KdbxGroup> _collectAllGroups(KdbxGroup root) {
    final map = <KdbxUuid, KdbxGroup>{root.uuid: root};
    for (final g in root.getAllGroups()) {
      map[g.uuid] = g;
    }
    return map;
  }

  static Map<KdbxUuid, KdbxEntry> _collectAllEntries(KdbxGroup root) {
    final map = <KdbxUuid, KdbxEntry>{};
    for (final e in root.getAllEntries()) {
      map[e.uuid] = e;
    }
    return map;
  }

  static Map<KdbxUuid, KdbxObject> _collectAllObjects(KdbxGroup root) {
    final map = <KdbxUuid, KdbxObject>{};
    map.addAll(_collectAllGroups(root));
    map.addAll(_collectAllEntries(root));
    return map;
  }

  static bool _areEntriesIdentical(KdbxEntry a, KdbxEntry b) {
    final aStrings = a.stringEntries.toList();
    final bStrings = b.stringEntries.toList();
    if (aStrings.length != bStrings.length) return false;

    final bStringMap = <KdbxKey, StringValue?>{
      for (final s in bStrings) s.key: s.value,
    };
    for (final s in aStrings) {
      if (!bStringMap.containsKey(s.key)) return false;
      final bVal = bStringMap[s.key];
      if ((s.value?.getText() ?? '') != (bVal?.getText() ?? '')) return false;
      if ((s.value is ProtectedValue) != (bVal is ProtectedValue)) return false;
    }

    final aBins = a.binaryEntries.toList();
    final bBins = b.binaryEntries.toList();
    if (aBins.length != bBins.length) return false;
    for (final bin in aBins) {
      final bBin = b.getBinary(bin.key);
      if (!_binariesEqual(bin.value, bBin)) return false;
    }

    if (a.icon.get() != b.icon.get()) return false;
    if (a.customIcon?.uuid != b.customIcon?.uuid) return false;
    if ((a.tags.get() ?? '') != (b.tags.get() ?? '')) return false;
    if ((a.times.expires.get() ?? false) != (b.times.expires.get() ?? false)) {
      return false;
    }
    if (a.times.expiryTime.get()?.millisecondsSinceEpoch !=
        b.times.expiryTime.get()?.millisecondsSinceEpoch) {
      return false;
    }

    return true;
  }
}
