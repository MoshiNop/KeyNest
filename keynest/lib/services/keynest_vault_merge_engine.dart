// ignore_for_file: implementation_imports, always_put_control_body_on_new_line, invalid_use_of_visible_for_testing_member
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_deleted_object.dart';
import 'package:kdbx/src/kdbx_entry.dart';
import 'package:kdbx/src/kdbx_group.dart';
import 'package:kdbx/src/kdbx_object.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/utils/duplicate_detector.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:logging/logging.dart';

final _logger = Logger('keynest_vault_merge_engine');

/// Strategy for resolving conflicting or duplicate entries during vault merge.
enum VaultMergeDuplicateStrategy {
  /// If identical, skip. If modified, keep newer entry and archive older to history.
  smartMerge,

  /// Always create a new entry with '(Merged)' suffix if a duplicate exists.
  keepAllDuplicate,

  /// Skip any entry that matches an existing entry (exact or title+username).
  skipDuplicates,

  /// Always overwrite the target entry with the source entry, archiving target to history.
  overwriteTarget,
}

/// Detailed result of a vault merge operation.
class VaultMergeResult {
  const VaultMergeResult({
    required this.success,
    this.totalEntriesProcessed = 0,
    this.newEntriesAdded = 0,
    this.entriesUpdated = 0,
    this.duplicatesSkipped = 0,
    this.foldersCreated = 0,
    this.message = '',
    this.errorMessage,
  });

  final bool success;
  final int totalEntriesProcessed;
  final int newEntriesAdded;
  final int entriesUpdated;
  final int duplicatesSkipped;
  final int foldersCreated;
  final String message;
  final String? errorMessage;

  @override
  String toString() =>
      'VaultMergeResult(success: $success, added: $newEntriesAdded, '
      'updated: $entriesUpdated, skipped: $duplicatesSkipped, '
      'foldersCreated: $foldersCreated)';
}

/// Standard KDBX Vault Merge Engine.
///
/// Merges multiple source KDBX vaults into a destination KDBX vault while:
/// 1. Preserving native folder/group hierarchies.
/// 2. Preserving all entry fields, protected fields, icons, attachments, and metadata.
/// 3. Safely resolving conflicts according to [VaultMergeDuplicateStrategy].
/// 4. Leaving source vaults completely unmodified (unless explicitly opted out).
/// 5. Writing strictly to standard KDBX specifications for KeePass compatibility.
class KeyNestVaultMergeEngine {
  KeyNestVaultMergeEngine._();

  /// Merges [sourceVaults] into [destinationVault].
  static Future<VaultMergeResult> mergeVaults({
    required List<KdbxFile> sourceVaults,
    required KdbxFile destinationVault,
    required KdbxBloc kdbxBloc,
    VaultMergeDuplicateStrategy duplicateStrategy =
        VaultMergeDuplicateStrategy.smartMerge,
    bool closeSourceVaultsAfterMerge = false,
  }) async {
    try {
      int totalProcessed = 0;
      int totalAdded = 0;
      int totalUpdated = 0;
      int totalSkipped = 0;
      int totalFoldersCreated = 0;

      // Group cache mapping from source group UUID to destination KdbxGroup
      final groupCache = <KdbxUuid, KdbxGroup>{};

      for (final sourceFile in sourceVaults) {
        if (sourceFile == destinationVault) {
          continue; // Skip if source is destination
        }

        final sourceRoot = sourceFile.body.rootGroup;
        final sourceRecycleBin = sourceFile.recycleBin;

        // 1. Replicate folder hierarchy from source into destination
        final foldersCreatedForVault = _syncFolderHierarchy(
          sourceRoot: sourceRoot,
          destinationFile: destinationVault,
          groupCache: groupCache,
          sourceRecycleBin: sourceRecycleBin,
        );
        totalFoldersCreated += foldersCreatedForVault;

        // 1.5. Process tombstones & deletions
        final destTombstones = <KdbxUuid, DateTime>{};
        for (final d in destinationVault.body.deletedObjects) {
          destTombstones[d.uuid] =
              d.deletionTime.get() ?? DateTime.fromMillisecondsSinceEpoch(0);
        }

        // Process source tombstones against destination entries
        for (final srcDel in sourceFile.body.deletedObjects) {
          final delUuid = srcDel.uuid;
          final delTime =
              srcDel.deletionTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);

          KdbxEntry? destMatch;
          for (final e in destinationVault.body.rootGroup.getAllEntries()) {
            if (e.uuid == delUuid) {
              destMatch = e;
              break;
            }
          }

          if (destMatch != null) {
            final destModTime =
                destMatch.times.lastModificationTime.get() ??
                DateTime.fromMillisecondsSinceEpoch(0);
            if (destModTime.isAfter(delTime)) {
              // Destination modified entry AFTER deletion -> keep alive
            } else {
              // Deleted on source -> remove from destination
              destMatch.parent?.internalRemoveEntry(destMatch);
              if (!destTombstones.containsKey(delUuid)) {
                destinationVault.body.deletedObjects.add(
                  KdbxDeletedObject.create(
                    destinationVault.ctx,
                    delUuid,
                    delTime,
                  ),
                );
                destTombstones[delUuid] = delTime;
              }
            }
          } else {
            if (!destTombstones.containsKey(delUuid)) {
              destinationVault.body.deletedObjects.add(
                KdbxDeletedObject.create(
                  destinationVault.ctx,
                  delUuid,
                  delTime,
                ),
              );
              destTombstones[delUuid] = delTime;
            }
          }
        }

        // 2. Fetch all non-recycle bin entries from source
        final sourceEntries = sourceRoot.getAllEntries().where((entry) {
          if (sourceRecycleBin != null &&
              _isDescendantOf(entry, sourceRecycleBin)) {
            return false;
          }
          if (KeyNestItemTypeHelper.isEntryInTrash(entry)) {
            return false;
          }
          return true;
        }).toList();

        for (final srcEntry in sourceEntries) {
          totalProcessed++;

          // Check if srcEntry was deleted in destination
          final destDelTime = destTombstones[srcEntry.uuid];
          if (destDelTime != null) {
            final srcModTime =
                srcEntry.times.lastModificationTime.get() ??
                DateTime.fromMillisecondsSinceEpoch(0);
            if (srcModTime.isAfter(destDelTime)) {
              // Modified after deletion -> revive entry, purge tombstone
              destinationVault.body.deletedObjects.removeWhere(
                (d) => d.uuid == srcEntry.uuid,
              );
              destTombstones.remove(srcEntry.uuid);
            } else {
              // Stays deleted: do not resurrect
              totalSkipped++;
              continue;
            }
          }

          // Determine destination group
          KdbxGroup destGroup = destinationVault.body.rootGroup;
          if (srcEntry.parent != null &&
              groupCache.containsKey(srcEntry.parent!.uuid)) {
            destGroup = groupCache[srcEntry.parent!.uuid]!;
          }

          // Search for existing entry in destination vault
          final existingEntry = _findMatchingEntry(
            srcEntry: srcEntry,
            destVault: destinationVault,
          );

          if (existingEntry == null) {
            // No conflict: create new entry in destination group
            _cloneEntryIntoGroup(
              sourceEntry: srcEntry,
              targetFile: destinationVault,
              targetGroup: destGroup,
            );
            totalAdded++;
          } else {
            // Conflict / Duplicate found: handle by strategy
            switch (duplicateStrategy) {
              case VaultMergeDuplicateStrategy.smartMerge:
                if (KeyNestDuplicateDetector.areExactDuplicates(
                  existingEntry,
                  srcEntry,
                )) {
                  // Identical data: skip duplicate safely
                  totalSkipped++;
                } else {
                  final srcModTime =
                      srcEntry.times.lastModificationTime.get() ??
                      DateTime.fromMillisecondsSinceEpoch(0);
                  final existingModTime =
                      existingEntry.times.lastModificationTime.get() ??
                      DateTime.fromMillisecondsSinceEpoch(0);

                  if (srcModTime.isAfter(existingModTime)) {
                    // Source is newer: archive existing into history, then update
                    _archiveToHistory(existingEntry);
                    _copyEntryFields(
                      source: srcEntry,
                      destination: existingEntry,
                    );
                    existingEntry.times.lastModificationTime.set(srcModTime);
                    totalUpdated++;
                  } else {
                    // Existing is newer: archive source entry into existing's history
                    final histClone = srcEntry.cloneInto(
                      existingEntry.parent ?? destinationVault.body.rootGroup,
                      toHistoryEntry: true,
                    );
                    existingEntry.history.add(histClone);
                    // Preserve non-conflicting custom fields from source that destination lacks
                    for (final s in srcEntry.stringEntries) {
                      if (existingEntry.getString(s.key) == null) {
                        final isSensitive =
                            KeyNestItemTypeHelper.isSensitiveFieldKey(
                              s.key.key,
                            );
                        if (isSensitive && s.value is! ProtectedValue) {
                          existingEntry.setString(
                            s.key,
                            ProtectedValue.fromString(s.value?.getText() ?? ''),
                          );
                        } else {
                          existingEntry.setString(s.key, s.value);
                        }
                      }
                    }
                    KeyNestItemTypeHelper.upgradeEntrySensitiveFields(
                      existingEntry,
                    );
                    totalSkipped++;
                  }
                }
                break;

              case VaultMergeDuplicateStrategy.keepAllDuplicate:
                final cloned = _cloneEntryIntoGroup(
                  sourceEntry: srcEntry,
                  targetFile: destinationVault,
                  targetGroup: destGroup,
                  titleSuffix: ' (Merged)',
                );
                if (cloned != null) {
                  totalAdded++;
                }
                break;

              case VaultMergeDuplicateStrategy.skipDuplicates:
                totalSkipped++;
                break;

              case VaultMergeDuplicateStrategy.overwriteTarget:
                _archiveToHistory(existingEntry);
                _copyEntryFields(source: srcEntry, destination: existingEntry);
                final srcModTime = srcEntry.times.lastModificationTime.get();
                if (srcModTime != null) {
                  existingEntry.times.lastModificationTime.set(srcModTime);
                }
                totalUpdated++;
                break;
            }
          }
        }
      }

      // 3. Persist changes strictly to the destination vault
      await kdbxBloc.saveFile(destinationVault);

      // 4. Optionally close source vaults if requested by user
      if (closeSourceVaultsAfterMerge) {
        for (final sourceFile in sourceVaults) {
          if (sourceFile != destinationVault) {
            await kdbxBloc.close(sourceFile);
          }
        }
      }

      final message =
          'Merge completed: $totalAdded added, $totalUpdated updated, '
          '$totalSkipped skipped ($totalFoldersCreated folders organized).';
      _logger.info(message);

      return VaultMergeResult(
        success: true,
        totalEntriesProcessed: totalProcessed,
        newEntriesAdded: totalAdded,
        entriesUpdated: totalUpdated,
        duplicatesSkipped: totalSkipped,
        foldersCreated: totalFoldersCreated,
        message: message,
      );
    } catch (e, st) {
      _logger.severe('Failed to merge vaults', e, st);
      return VaultMergeResult(
        success: false,
        errorMessage: 'Vault merge failed: $e',
      );
    }
  }

  /// Maps and replicates group hierarchy recursively from [sourceRoot] into [destinationFile].
  static int _syncFolderHierarchy({
    required KdbxGroup sourceRoot,
    required KdbxFile destinationFile,
    required Map<KdbxUuid, KdbxGroup> groupCache,
    required KdbxGroup? sourceRecycleBin,
  }) {
    int foldersCreated = 0;
    groupCache[sourceRoot.uuid] = destinationFile.body.rootGroup;

    void traverse(KdbxGroup srcGroup, KdbxGroup destParent) {
      for (final child in srcGroup.groups) {
        // Skip recycle bin hierarchy
        if (sourceRecycleBin != null && child.uuid == sourceRecycleBin.uuid) {
          continue;
        }

        final childName = child.name.get() ?? 'Folder';

        // Check if matching child group already exists in destParent
        KdbxGroup? existingDestChild;
        for (final g in destParent.groups) {
          if (g.name.get() == childName) {
            existingDestChild = g;
            break;
          }
        }

        if (existingDestChild == null) {
          // Create native child group in destination
          existingDestChild = destinationFile.createGroup(
            parent: destParent,
            name: childName,
          );
          final icon = child.icon.get();
          if (icon != null) {
            existingDestChild.icon.set(icon);
          }
          foldersCreated++;
        }

        groupCache[child.uuid] = existingDestChild;
        traverse(child, existingDestChild);
      }
    }

    traverse(sourceRoot, destinationFile.body.rootGroup);
    return foldersCreated;
  }

  /// Searches for an existing matching entry in [destVault] using the following deterministic priority:
  /// 1. Unique ID: Valid entry UUID and identical item type.
  /// 2. Normalized identity: Identical item type and required identity fields
  ///    (Logins: Title + Username + Domain/URL; Cards: Title + Card number; Notes & Records: Title + Record type).
  /// 3. Complete duplicate: Fallback match where complete relevant contents are identical.
  ///
  /// Recycle Bin and trashed entries in [destVault] are strictly excluded from matching.
  static KdbxEntry? _findMatchingEntry({
    required KdbxEntry srcEntry,
    required KdbxFile destVault,
  }) {
    final destRecycleBin = destVault.recycleBin;

    // Filter destination candidates to only active, non-trashed entries
    final eligibleDestEntries = destVault.body.rootGroup.getAllEntries().where((
      entry,
    ) {
      if (destRecycleBin != null && _isDescendantOf(entry, destRecycleBin)) {
        return false;
      }
      if (KeyNestItemTypeHelper.isEntryInTrash(entry)) {
        return false;
      }
      return true;
    }).toList();

    if (eligibleDestEntries.isEmpty) {
      return null;
    }

    final srcType = KeyNestItemTypeHelper.getItemType(srcEntry);

    // Priority 1: Unique ID Matching
    if (_isValidEntryUuid(srcEntry.uuid)) {
      for (final dest in eligibleDestEntries) {
        if (_isValidEntryUuid(dest.uuid) && dest.uuid == srcEntry.uuid) {
          final destType = KeyNestItemTypeHelper.getItemType(dest);
          if (srcType == destType) {
            return dest;
          }
        }
      }
    }

    // Priority 2: Normalized Identity Matching
    final matchedCandidate = _matchByNormalizedIdentity(
      srcEntry: srcEntry,
      srcType: srcType,
      candidates: eligibleDestEntries,
    );
    if (matchedCandidate != null) {
      return matchedCandidate;
    }

    // Priority 3: Complete Duplicate Fallback
    for (final dest in eligibleDestEntries) {
      if (KeyNestDuplicateDetector.areCompleteDuplicates(dest, srcEntry)) {
        return dest;
      }
    }

    return null;
  }

  static bool _isValidEntryUuid(KdbxUuid? uuid) {
    if (uuid == null || uuid.isNil) return false;
    try {
      final bytes = uuid.toBytes();
      if (bytes.length != 16) return false;
      return bytes.any((b) => b != 0);
    } catch (_) {
      return false;
    }
  }

  static KdbxEntry? _matchByNormalizedIdentity({
    required KdbxEntry srcEntry,
    required KeyNestItemType srcType,
    required List<KdbxEntry> candidates,
  }) {
    final srcTitle = _normalizeString(
      srcEntry.getString(KdbxKeyCommon.TITLE)?.getText(),
    );
    if (srcTitle.isEmpty) {
      return null;
    }

    final matchingCandidates = <KdbxEntry>[];

    switch (srcType) {
      case KeyNestItemType.login:
        final srcUser = _normalizeString(
          srcEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
        );
        final srcRawUrl = srcEntry.getString(KdbxKeyCommon.URL)?.getText();
        final srcDomain = _normalizeDomain(srcRawUrl);
        final srcFullUrl = _normalizeUrl(srcRawUrl);

        // All identity fields must be present and non-empty
        if (srcUser.isEmpty || (srcDomain.isEmpty && srcFullUrl.isEmpty)) {
          return null;
        }

        for (final cand in candidates) {
          if (KeyNestItemTypeHelper.getItemType(cand) !=
              KeyNestItemType.login) {
            continue;
          }
          final candTitle = _normalizeString(
            cand.getString(KdbxKeyCommon.TITLE)?.getText(),
          );
          if (candTitle != srcTitle) {
            continue;
          }
          final candUser = _normalizeString(
            cand.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          );
          if (candUser != srcUser) {
            continue;
          }
          final candRawUrl = cand.getString(KdbxKeyCommon.URL)?.getText();
          final candDomain = _normalizeDomain(candRawUrl);
          final candFullUrl = _normalizeUrl(candRawUrl);
          final urlMatches =
              (srcDomain.isNotEmpty && srcDomain == candDomain) ||
              (srcFullUrl.isNotEmpty && srcFullUrl == candFullUrl);
          if (urlMatches) {
            matchingCandidates.add(cand);
          }
        }
        break;

      case KeyNestItemType.card:
        final srcCardNum = _normalizeCardNumber(
          srcEntry.getString(KdbxKey('CardNumber'))?.getText() ??
              srcEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
        );
        if (srcCardNum.isEmpty) {
          return null;
        }

        for (final cand in candidates) {
          if (KeyNestItemTypeHelper.getItemType(cand) != KeyNestItemType.card) {
            continue;
          }
          final candTitle = _normalizeString(
            cand.getString(KdbxKeyCommon.TITLE)?.getText(),
          );
          if (candTitle != srcTitle) {
            continue;
          }
          final candCardNum = _normalizeCardNumber(
            cand.getString(KdbxKey('CardNumber'))?.getText() ??
                cand.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          );
          if (candCardNum == srcCardNum) {
            matchingCandidates.add(cand);
          }
        }
        break;

      case KeyNestItemType.note:
        for (final cand in candidates) {
          if (KeyNestItemTypeHelper.getItemType(cand) != KeyNestItemType.note) {
            continue;
          }
          final candTitle = _normalizeString(
            cand.getString(KdbxKeyCommon.TITLE)?.getText(),
          );
          if (candTitle == srcTitle) {
            matchingCandidates.add(cand);
          }
        }
        break;

      case KeyNestItemType.record:
        final srcRecType = _normalizeString(
          KeyNestItemTypeHelper.getRecordType(srcEntry),
        );
        if (srcRecType.isEmpty) {
          return null;
        }

        for (final cand in candidates) {
          if (KeyNestItemTypeHelper.getItemType(cand) !=
              KeyNestItemType.record) {
            continue;
          }
          final candTitle = _normalizeString(
            cand.getString(KdbxKeyCommon.TITLE)?.getText(),
          );
          if (candTitle != srcTitle) {
            continue;
          }
          final candRecType = _normalizeString(
            KeyNestItemTypeHelper.getRecordType(cand),
          );
          if (candRecType == srcRecType) {
            matchingCandidates.add(cand);
          }
        }
        break;

      case KeyNestItemType.twoFactor:
        final srcUser = _normalizeString(
          srcEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
        );
        final srcSecret = KeyNestDuplicateDetector.extractTotpSecret(srcEntry);
        if (srcUser.isEmpty && srcSecret.isEmpty) {
          return null;
        }

        for (final cand in candidates) {
          if (KeyNestItemTypeHelper.getItemType(cand) !=
              KeyNestItemType.twoFactor) {
            continue;
          }
          final candTitle = _normalizeString(
            cand.getString(KdbxKeyCommon.TITLE)?.getText(),
          );
          if (candTitle != srcTitle) {
            continue;
          }
          final candUser = _normalizeString(
            cand.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          );
          final candSecret = KeyNestDuplicateDetector.extractTotpSecret(cand);
          final matches =
              (srcUser.isNotEmpty && candUser == srcUser) ||
              (srcSecret.isNotEmpty && candSecret == srcSecret);
          if (matches) {
            matchingCandidates.add(cand);
          }
        }
        break;
    }

    if (matchingCandidates.isEmpty) {
      return null;
    }
    if (matchingCandidates.length == 1) {
      return matchingCandidates.first;
    }

    // Deterministic candidate selection when multiple candidates share identity
    int scoreCandidate(KdbxEntry candidate) {
      int score = 0;
      if (KeyNestDuplicateDetector.areCompleteDuplicates(candidate, srcEntry)) {
        score += 1000;
      }
      final candPass = candidate.getString(KdbxKeyCommon.PASSWORD)?.getText();
      final srcPass = srcEntry.getString(KdbxKeyCommon.PASSWORD)?.getText();
      if (candPass != null && candPass.isNotEmpty && candPass == srcPass) {
        score += 100;
      }
      final candUrl = candidate.getString(KdbxKeyCommon.URL)?.getText();
      final srcUrl = srcEntry.getString(KdbxKeyCommon.URL)?.getText();
      if (candUrl != null && candUrl.isNotEmpty && candUrl == srcUrl) {
        score += 50;
      }
      if (candidate.parent?.name.get() != null &&
          candidate.parent?.name.get() == srcEntry.parent?.name.get()) {
        score += 20;
      }
      return score;
    }

    matchingCandidates.sort((a, b) {
      final scoreComp = scoreCandidate(b).compareTo(scoreCandidate(a));
      if (scoreComp != 0) return scoreComp;
      return a.uuid.toString().compareTo(b.uuid.toString());
    });

    return matchingCandidates.first;
  }

  static String _normalizeString(String? text) {
    if (text == null) return '';
    return text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _normalizeCardNumber(String? text) {
    if (text == null) return '';
    return text.replaceAll(RegExp(r'[\s\-]'), '').trim();
  }

  static String _normalizeDomain(String? raw) {
    if (raw == null) return '';
    var text = raw.trim().toLowerCase();
    if (text.isEmpty) return '';

    final hasScheme = text.contains('://');
    final uri = Uri.tryParse(hasScheme ? text : 'https://$text');
    if (uri != null && uri.host.isNotEmpty) {
      var host = uri.host.toLowerCase();
      if (host.startsWith('www.')) {
        host = host.substring(4);
      }
      if (uri.hasPort && uri.port != 80 && uri.port != 443) {
        return '$host:${uri.port}'.trim();
      }
      return host.trim();
    }

    if (text.startsWith('https://')) {
      text = text.substring(8);
    } else if (text.startsWith('http://')) {
      text = text.substring(7);
    }
    if (text.startsWith('www.')) {
      text = text.substring(4);
    }
    final slashIdx = text.indexOf('/');
    if (slashIdx != -1) {
      text = text.substring(0, slashIdx);
    }
    final qIdx = text.indexOf('?');
    if (qIdx != -1) {
      text = text.substring(0, qIdx);
    }
    return text.trim();
  }

  static String _normalizeUrl(String? raw) {
    if (raw == null) return '';
    var text = raw.trim().toLowerCase();
    if (text.isEmpty) return '';

    if (text.startsWith('https://')) {
      text = text.substring(8);
    } else if (text.startsWith('http://')) {
      text = text.substring(7);
    }
    if (text.startsWith('www.')) {
      text = text.substring(4);
    }
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return text.trim();
  }

  /// Clones a source entry into a target group within [targetFile], generating a fresh UUID.
  static KdbxEntry? _cloneEntryIntoGroup({
    required KdbxEntry sourceEntry,
    required KdbxFile targetFile,
    required KdbxGroup targetGroup,
    String? titleSuffix,
  }) {
    final newEntry = KdbxEntry.create(targetFile, targetGroup);
    targetGroup.addEntry(newEntry);
    if (titleSuffix == null &&
        targetFile.body.rootGroup.getAllEntries().every(
          (e) => e == newEntry || e.uuid != sourceEntry.uuid,
        )) {
      newEntry.forceSetUuid(sourceEntry.uuid);
    }

    // Copy string fields
    for (final str in sourceEntry.stringEntries) {
      if (str.key == KdbxKeyCommon.TITLE && titleSuffix != null) {
        final origTitle = str.value?.getText() ?? '';
        final hasSuffix = origTitle.trim().endsWith(titleSuffix.trim());
        final newTitle = hasSuffix ? origTitle : '$origTitle$titleSuffix';
        newEntry.setString(
          KdbxKeyCommon.TITLE,
          PlainValue(newTitle),
        );
      } else {
        newEntry.setString(str.key, str.value);
      }
    }

    // Copy icon
    if (sourceEntry.customIcon != null) {
      newEntry.customIcon = sourceEntry.customIcon;
    } else {
      newEntry.icon.set(sourceEntry.icon.get());
    }

    // Copy binaries / attachments
    for (final bin in sourceEntry.binaryEntries) {
      targetFile.ctx.addBinary(bin.value);
      newEntry.createBinary(
        isProtected: bin.value.isProtected,
        name: bin.key.key,
        bytes: bin.value.value,
      );
    }

    // Copy custom data
    for (final cd in sourceEntry.customData.entries) {
      newEntry.customData[cd.key] = cd.value;
    }

    // Copy timestamps
    final modTime = sourceEntry.times.lastModificationTime.get();
    if (modTime != null) {
      newEntry.times.lastModificationTime.set(modTime);
    }
    final expTime = sourceEntry.times.expiryTime.get();
    if (expTime != null) {
      newEntry.times.expiryTime.set(expTime);
      newEntry.times.expires.set(sourceEntry.times.expires.get() ?? false);
    }

    KeyNestItemTypeHelper.upgradeEntrySensitiveFields(newEntry);
    return newEntry;
  }

  /// Copies all fields and attachments from [source] into [destination].
  static void _copyEntryFields({
    required KdbxEntry source,
    required KdbxEntry destination,
  }) {
    for (final s in source.stringEntries) {
      final isSensitive =
          KeyNestItemTypeHelper.isSensitiveFieldKey(s.key.key) ||
          (destination.getString(s.key) is ProtectedValue);
      if (isSensitive && s.value is! ProtectedValue) {
        destination.setString(
          s.key,
          ProtectedValue.fromString(s.value?.getText() ?? ''),
        );
      } else {
        destination.setString(s.key, s.value);
      }
    }

    if (source.customIcon != null) {
      destination.customIcon = source.customIcon;
    } else {
      destination.icon.set(source.icon.get());
    }

    for (final bin in source.binaryEntries) {
      destination.file.ctx.addBinary(bin.value);
      destination.createBinary(
        isProtected: bin.value.isProtected,
        name: bin.key.key,
        bytes: bin.value.value,
      );
    }

    for (final cd in source.customData.entries) {
      destination.customData[cd.key] = cd.value;
    }

    KeyNestItemTypeHelper.upgradeEntrySensitiveFields(destination);
  }

  /// Archives [entry] into its own history list.
  static void _archiveToHistory(KdbxEntry entry) {
    try {
      final historyClone = entry.cloneInto(
        entry.parent ?? entry.file.body.rootGroup,
        toHistoryEntry: true,
      );
      entry.history.add(historyClone);
    } catch (e) {
      _logger.warning('Failed to archive entry to history: $e');
    }
  }

  static bool _isDescendantOf(KdbxEntry entry, KdbxGroup ancestor) {
    KdbxGroup? current = entry.parent;
    while (current != null) {
      if (current.uuid == ancestor.uuid) return true;
      current = current.parent;
    }
    return false;
  }
}
