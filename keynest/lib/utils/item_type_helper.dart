import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/ui/widgets/keynest_custom_field_sheet.dart';

/// Archetypes supported by KeyNest.
enum KeyNestItemType {
  login,
  card,
  note,
  record,
  twoFactor,
}

/// Helper for managing the separation between item archetypes (ItemType)
/// and user-defined organizational categories (ItemCategory).
class KeyNestItemTypeHelper {
  static const String itemTypeKey = 'ItemType';
  static const String itemCategoryKey = 'ItemCategory';
  static const String recordTypeKey = 'RecordType';

  /// Returns whether a field key or custom field represents sensitive information
  /// that must be stored as a [ProtectedValue].
  static bool isSensitiveFieldKey(String key, {CustomFieldKind? kind}) {
    if (kind == CustomFieldKind.hidden ||
        kind == CustomFieldKind.pin ||
        kind == CustomFieldKind.authenticator) {
      return true;
    }
    final lower = key.trim().toLowerCase();
    if (lower == 'cvv' ||
        lower == 'pin' ||
        lower == 'password' ||
        lower == 'otpauth' ||
        lower == 'otp' ||
        lower == 'totp' ||
        lower == 'card number' ||
        lower == 'cardnumber' ||
        lower == 'totp seed' ||
        lower == 'hmacseed' ||
        lower.contains('secret') ||
        lower.contains('seed phrase') ||
        lower.contains('recovery phrase') ||
        lower.contains('private key') ||
        lower.contains('api secret') ||
        lower.contains('security answer') ||
        lower.contains('security code')) {
      return true;
    }
    return false;
  }

  /// Upgrades any sensitive plain values on [entry] to [ProtectedValue].
  /// Non-sensitive fields are left unchanged. Safe for legacy and imported entries.
  static void upgradeEntrySensitiveFields(KdbxEntry entry) {
    for (final s in entry.stringEntries.toList()) {
      final key = s.key.key;
      final kindStr = entry.customData['FieldType_$key'];
      CustomFieldKind? kind;
      if (kindStr != null) {
        for (final k in CustomFieldKind.values) {
          if (k.name.toLowerCase() == kindStr.toLowerCase()) {
            kind = k;
            break;
          }
        }
      }
      if (isSensitiveFieldKey(key, kind: kind)) {
        if (s.value is! ProtectedValue) {
          final text = s.value?.getText() ?? '';
          entry.setString(s.key, ProtectedValue.fromString(text));
        }
      }
    }
  }

  static final Expando<_CachedItemClassification> _classificationCache =
      Expando<_CachedItemClassification>('itemTypeClassificationCache');
  static final Expando<bool> _trashCache = Expando<bool>('itemTypeTrashCache');

  /// Invalidates the cached classification for [entry] (or all entries if null).
  static void invalidateCache([KdbxEntry? entry]) {
    if (entry != null) {
      _classificationCache[entry] = null;
      _trashCache[entry] = null;
    }
  }

  /// Detects or returns the record type defined on the entry, either explicitly
  /// via 'RecordType' or inferred from specific template fields.
  static String? getRecordType(KdbxEntry entry) {
    final modTime = entry.times.lastModificationTime.get();
    final stringCount = entry.stringEntries.length;
    final cached = _classificationCache[entry];
    if (cached != null &&
        cached.modTime == modTime &&
        cached.stringCount == stringCount &&
        cached.recordType != null) {
      return cached.recordType;
    }
    final computed = _computeRecordType(entry);
    _classificationCache[entry] = _CachedItemClassification(
      itemType: cached?.itemType,
      recordType: computed,
      modTime: modTime,
      stringCount: stringCount,
    );
    return computed;
  }

  static String? _computeRecordType(KdbxEntry entry) {
    final explicit = entry.getString(KdbxKey('RecordType'))?.getText()?.trim();
    if (explicit != null && explicit.isNotEmpty && explicit != 'Record') {
      return explicit;
    }
    // Inspect specific template field keys
    final keys = entry.stringEntries.map((e) => e.key.key).toSet();
    if (keys.contains('Network SSID') ||
        keys.contains('Router IP / Admin URL')) {
      return 'Wi-Fi Password';
    }
    if (keys.contains('Private Key') ||
        keys.contains('Public Key') ||
        keys.contains('Host Server')) {
      return 'SSH Key';
    }
    if (keys.contains('Passport Number') || keys.contains('Issuing Country')) {
      return 'Passport';
    }
    if (keys.contains('Licence Number') ||
        keys.contains('Classes / Endorsements')) {
      return "Driver's Licence";
    }
    if (keys.contains('ID Number') || keys.contains('Issuing Authority')) {
      return 'ID Card';
    }
    if (keys.contains('SSN Number') ||
        keys.contains('Social Security Number')) {
      return 'Social Security Number';
    }
    if (keys.contains('NI Number') || keys.contains('National Insurance No')) {
      return 'National Insurance No';
    }
    if (keys.contains('Tax ID / TIN') ||
        keys.contains('Tax ID') ||
        keys.contains('Tax Authority')) {
      return 'Tax Number';
    }
    if (keys.contains('License Key') ||
        keys.contains('Licensed Email') ||
        keys.contains('Software License')) {
      return 'Software License';
    }
    if (keys.contains('API Key') ||
        keys.contains('API Secret') ||
        keys.contains('Endpoint URL')) {
      return 'API Credential';
    }
    if (keys.contains('Combination Code')) {
      return 'Combination Lock';
    }
    if (keys.contains('Database Name') || keys.contains('DB Host')) {
      return 'Database';
    }
    if (keys.contains('Server IP') ||
        keys.contains('Admin Console URL') ||
        keys.contains('Hosting Provider')) {
      return 'Server';
    }
    if (keys.contains('IMAP Server') || keys.contains('SMTP Server')) {
      return 'Email Account';
    }
    if (keys.contains('FTP Host') || keys.contains('SFTP Host')) {
      return 'FTP / SFTP';
    }
    if (keys.contains('IBAN') ||
        keys.contains('Routing Number') ||
        keys.contains('Account Number') ||
        keys.contains('SWIFT / BIC')) {
      return 'Bank Account';
    }
    if (keys.contains('Wallet Address') ||
        keys.contains('Seed Phrase') ||
        keys.contains('Recovery Phrase')) {
      return 'Crypto Wallet';
    }
    if (keys.contains('Policy Number') || keys.contains('Insurance Company')) {
      return 'Insurance Policy';
    }
    if (keys.contains('Health Number') || keys.contains('Medical ID')) {
      return 'Health Card';
    }
    if (keys.contains('Rx Number') || keys.contains('Prescription Number')) {
      return 'Prescription';
    }
    if (keys.contains('Member ID') || keys.contains('Membership Number')) {
      return 'Membership';
    }
    if (keys.contains('Loyalty Number') || keys.contains('Program Name')) {
      return 'Reward / Loyalty';
    }
    if (keys.contains('Birth Certificate') ||
        (keys.contains('Registration Number') &&
            keys.contains('Place of Birth'))) {
      return 'Birth Certificate';
    }
    if (keys.contains('Marriage Certificate') ||
        (keys.contains('Spouse 1') && keys.contains('Spouse 2'))) {
      return 'Marriage Certificate';
    }
    if (keys.contains('CardNumber') ||
        keys.contains('Cardholder') ||
        keys.contains('CVV') ||
        keys.contains('CardNetwork')) {
      return 'Payment Card';
    }
    return explicit?.isNotEmpty == true ? explicit : null;
  }

  /// Returns the archetype of the given [entry].
  /// Cached per entry version using non-sensitive enum only.
  static KeyNestItemType getItemType(KdbxEntry entry) {
    final modTime = entry.times.lastModificationTime.get();
    final stringCount = entry.stringEntries.length;
    final cached = _classificationCache[entry];
    if (cached != null &&
        cached.modTime == modTime &&
        cached.stringCount == stringCount &&
        cached.itemType != null) {
      return cached.itemType!;
    }
    final computed = _computeItemType(entry);
    _classificationCache[entry] = _CachedItemClassification(
      itemType: computed,
      recordType: cached?.recordType,
      modTime: modTime,
      stringCount: stringCount,
    );
    return computed;
  }

  static KeyNestItemType _computeItemType(KdbxEntry entry) {
    final typeStr = entry
        .getString(KdbxKey(itemTypeKey))
        ?.getText()
        ?.trim()
        .toLowerCase();
    if (typeStr != null && typeStr.isNotEmpty) {
      switch (typeStr) {
        case 'card':
        case 'payment_card':
        case 'credit_card':
          return KeyNestItemType.card;
        case 'note':
        case 'secure_note':
          return KeyNestItemType.note;
        case 'record':
          return KeyNestItemType.record;
        case '2fa':
        case 'two_factor':
        case 'authenticator':
          return KeyNestItemType.twoFactor;
        case 'login':
          return KeyNestItemType.login;
      }
    }

    // Legacy fallback based on ItemCategory
    final cat = entry.getString(KdbxKey(itemCategoryKey))?.getText()?.trim();
    if (cat == 'Card' || cat == 'Payment Cards' || cat == 'Payment Card') {
      return KeyNestItemType.card;
    }
    if (cat == 'Note' || cat == 'Secure Notes' || cat == 'Secure Note') {
      return KeyNestItemType.note;
    }
    if (cat == '2FA' || cat == '2FA Authenticator') {
      return KeyNestItemType.twoFactor;
    }
    if (cat == 'Record') {
      return KeyNestItemType.record;
    }

    // Inferred RecordType from fields
    final recordType = getRecordType(entry);
    if (recordType != null && recordType.isNotEmpty) {
      if (recordType == 'Payment Card') {
        return KeyNestItemType.card;
      }
      return KeyNestItemType.record;
    }

    // Check for Payment Card specific fields
    if (entry.getString(KdbxKey('CardNumber')) != null ||
        entry.getString(KdbxKey('Cardholder')) != null) {
      return KeyNestItemType.card;
    }

    // Check for Note (has Notes but no password and no username)
    final hasPass =
        entry.getString(KdbxKeyCommon.PASSWORD)?.getText()?.isNotEmpty == true;
    final hasUser =
        entry.getString(KdbxKeyCommon.USER_NAME)?.getText()?.isNotEmpty == true;
    final hasNotes =
        entry.getString(KdbxKey('Notes'))?.getText()?.isNotEmpty == true;
    if (hasNotes && !hasPass && !hasUser) {
      return KeyNestItemType.note;
    }

    return KeyNestItemType.login;
  }

  /// Explicitly marks the archetype of the [entry].
  static void setItemType(KdbxEntry entry, KeyNestItemType type) {
    entry.setString(KdbxKey(itemTypeKey), PlainValue(type.name));
    invalidateCache(entry);
  }

  /// Returns the category or archetype name for display and organization.
  /// Accurately maps record types, archetypes, and custom user categories.
  static String getCategory(KdbxEntry entry) {
    // 1. If an explicit or inferred RecordType is present, it directly defines the record type
    final recordType = getRecordType(entry);
    if (recordType != null && recordType.isNotEmpty) {
      return recordType;
    }

    // 2. Check user-assigned category
    final cat = entry.getString(KdbxKey(itemCategoryKey))?.getText()?.trim();
    if (cat != null &&
        cat.isNotEmpty &&
        cat != 'General' &&
        cat != 'Trash' &&
        cat != 'Record') {
      if (cat == 'Card' || cat == 'Payment Cards') {
        return 'Payment Card';
      }
      if (cat == 'Note' || cat == 'Secure Notes') {
        return 'Secure Note';
      }
      if (cat == '2FA') {
        return '2FA Authenticator';
      }
      return cat;
    }

    // 3. Fallback based on item archetype
    final itemType = getItemType(entry);
    switch (itemType) {
      case KeyNestItemType.card:
        return 'Payment Card';
      case KeyNestItemType.note:
        return 'Secure Note';
      case KeyNestItemType.twoFactor:
        return '2FA Authenticator';
      case KeyNestItemType.record:
        return recordType ?? 'Record';
      case KeyNestItemType.login:
        return (cat != null && cat.isNotEmpty && cat != 'Trash')
            ? cat
            : 'General';
    }
  }

  /// Sets the user-defined organizational category on [entry].
  /// Automatically ensures the entry's archetype is preserved in 'ItemType'.
  static void setCategory(KdbxEntry entry, String category) {
    if (entry.getString(KdbxKey(itemTypeKey)) == null) {
      setItemType(entry, getItemType(entry));
    }
    entry.setString(KdbxKey(itemCategoryKey), PlainValue(category));
    invalidateCache(entry);
  }

  /// Returns whether [group] is the trash / recycle bin or inside it.
  static bool isTrashOrRecycleBin(KdbxGroup? group) {
    if (group == null) {
      return false;
    }
    KdbxGroup? cur = group;
    while (cur != null) {
      if (cur == cur.file.recycleBin) {
        return true;
      }
      if (cur.isInRecycleBin()) {
        return true;
      }
      final name = cur.name.get()?.trim().toLowerCase();
      if (name == 'trash' || name == 'recycle bin') {
        return true;
      }
      cur = cur.parent;
    }
    return false;
  }

  /// Returns a new list of [groups] sorted for display with trash/recycle bin groups
  /// always appearing at the bottom of the list, regardless of creation date or order of other folders.
  /// Non-trash folders are sorted alphabetically by display name.
  /// Affects display ordering only and does NOT alter actual KDBX folder storage or serialization order.
  static List<KdbxGroup> sortGroupsWithTrashLast(Iterable<KdbxGroup> groups) {
    final list = List<KdbxGroup>.from(groups);
    list.sort((a, b) {
      final aTrash = isTrashOrRecycleBin(a);
      final bTrash = isTrashOrRecycleBin(b);
      if (aTrash != bTrash) {
        return aTrash ? 1 : -1;
      }
      final aName = (a.name.get() ?? '').toLowerCase();
      final bName = (b.name.get() ?? '').toLowerCase();
      return aName.compareTo(bName);
    });
    return list;
  }

  /// Returns whether [entry] has been deleted or moved to trash.
  static bool isEntryInTrash(KdbxEntry entry) {
    return _computeIsEntryInTrash(entry);
  }

  static bool _computeIsEntryInTrash(KdbxEntry entry) {
    if (entry.parent == null) {
      return true;
    }
    if (entry.isInRecycleBin()) {
      return true;
    }
    if (isTrashOrRecycleBin(entry.parent)) {
      return true;
    }
    final cat = entry.getString(KdbxKey(itemCategoryKey))?.getText();
    if (cat == 'Trash') {
      return true;
    }
    final isDeleted = entry.getString(KdbxKey('IsDeleted'))?.getText();
    if (isDeleted == 'true') {
      return true;
    }
    return false;
  }

  /// Copies an entry into [targetGroup] (which can belong to any opened KDBX vault).
  /// Generates a fresh UUID in the target vault, copies all fields, icons, attachments,
  /// custom data, and saves the target vault independently.
  static Future<KdbxEntry> copyEntryToGroup({
    required KdbxEntry sourceEntry,
    required KdbxGroup targetGroup,
    KdbxBloc? kdbxBloc,
    bool saveImmediately = true,
  }) async {
    final targetFile = targetGroup.file;
    final newEntry = KdbxEntry.create(targetFile, targetGroup);
    targetGroup.addEntry(newEntry);

    // Copy all string entries
    for (final s in sourceEntry.stringEntries) {
      newEntry.setString(s.key, s.value);
    }

    // Copy icon, registering custom icon in target vault if needed
    if (sourceEntry.customIcon != null) {
      final custom = sourceEntry.customIcon!;
      if (!targetFile.body.meta.customIcons.containsKey(custom.uuid)) {
        targetFile.body.meta.addCustomIcon(
          KdbxCustomIcon(uuid: custom.uuid, data: custom.data),
        );
      }
      newEntry.customIcon = custom;
    } else {
      newEntry.icon.set(sourceEntry.icon.get());
    }

    // Copy attachments / binaries
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

    // Copy timestamps & expiration
    final modTime = sourceEntry.times.lastModificationTime.get();
    if (modTime != null) {
      newEntry.times.lastModificationTime.set(modTime);
    }
    final createTime = sourceEntry.times.creationTime.get();
    if (createTime != null) {
      newEntry.times.creationTime.set(createTime);
    }
    final expTime = sourceEntry.times.expiryTime.get();
    if (expTime != null) {
      newEntry.times.expiryTime.set(expTime);
      newEntry.times.expires.set(sourceEntry.times.expires.get() ?? false);
    }

    if (saveImmediately) {
      if (kdbxBloc != null) {
        await kdbxBloc.saveFile(targetFile);
      } else {
        await targetFile.save();
      }
    }
    return newEntry;
  }

  /// Moves an entry into [targetGroup] (which can belong to the same or another opened KDBX vault).
  /// If in the same vault, performs native KDBX move.
  /// If across vaults, copies to target vault, saves target, deletes from source vault, and saves source.
  static Future<KdbxEntry> moveEntryToGroup({
    required KdbxEntry sourceEntry,
    required KdbxGroup targetGroup,
    KdbxBloc? kdbxBloc,
  }) async {
    final sourceFile = sourceEntry.file;
    final targetFile = targetGroup.file;

    if (sourceFile == targetFile) {
      sourceFile.move(sourceEntry, targetGroup);
      if (kdbxBloc != null) {
        await kdbxBloc.saveFile(sourceFile);
      } else {
        await sourceFile.save();
      }
      return sourceEntry;
    } else {
      final copied = await copyEntryToGroup(
        sourceEntry: sourceEntry,
        targetGroup: targetGroup,
        kdbxBloc: kdbxBloc,
      );

      try {
        // Permanently remove original entry from source vault without sending to Trash
        sourceFile.deletePermanently(sourceEntry);
        if (kdbxBloc != null) {
          await kdbxBloc.saveFile(sourceFile);
        } else {
          await sourceFile.save();
        }
      } catch (e) {
        // Safe rollback: remove copied entry from target vault if source save fails
        try {
          targetFile.deletePermanently(copied);
          if (kdbxBloc != null) {
            await kdbxBloc.saveFile(targetFile);
          } else {
            await targetFile.save();
          }
        } catch (_) {}
        rethrow;
      }
      return copied;
    }
  }

  /// Safely copies multiple [entries] into [targetGroup] (same or cross-vault).
  /// Performs in-memory creation and a single batch save to prevent file corruption.
  static Future<List<KdbxEntry>> bulkCopyEntries({
    required Iterable<KdbxEntry> entries,
    required KdbxGroup targetGroup,
    KdbxBloc? kdbxBloc,
  }) async {
    final targetFile = targetGroup.file;
    final copiedEntries = <KdbxEntry>[];

    for (final src in entries) {
      final copied = await copyEntryToGroup(
        sourceEntry: src,
        targetGroup: targetGroup,
        kdbxBloc: kdbxBloc,
        saveImmediately: false,
      );
      copiedEntries.add(copied);
    }

    if (kdbxBloc != null) {
      await kdbxBloc.saveFile(targetFile);
    } else {
      await targetFile.save();
    }
    return copiedEntries;
  }

  /// Safely moves multiple [entries] into [targetGroup] (same or cross-vault).
  /// Native in-vault move preserves UUID and internal references.
  /// Cross-vault moves copy with full fidelity, permanently remove from source without
  /// placing unwanted copies in Trash, and provide safe transactional rollback.
  static Future<List<KdbxEntry>> bulkMoveEntries({
    required Iterable<KdbxEntry> entries,
    required KdbxGroup targetGroup,
    KdbxBloc? kdbxBloc,
  }) async {
    final targetFile = targetGroup.file;
    final inVaultEntries = <KdbxEntry>[];
    final crossVaultEntries = <KdbxEntry>[];

    for (final src in entries) {
      if (src.parent == targetGroup && src.file == targetFile) {
        continue;
      }
      if (src.file == targetFile) {
        inVaultEntries.add(src);
      } else {
        crossVaultEntries.add(src);
      }
    }

    final movedEntries = <KdbxEntry>[];

    // 1. Process in-vault moves
    for (final src in inVaultEntries) {
      targetFile.move(src, targetGroup);
      movedEntries.add(src);
    }

    // 2. Process cross-vault moves with rollback protection
    if (crossVaultEntries.isNotEmpty) {
      final newlyCopied = <KdbxEntry>[];
      try {
        for (final src in crossVaultEntries) {
          final copied = await copyEntryToGroup(
            sourceEntry: src,
            targetGroup: targetGroup,
            kdbxBloc: kdbxBloc,
            saveImmediately: false,
          );
          newlyCopied.add(copied);
        }

        // Batch save destination vault
        if (kdbxBloc != null) {
          await kdbxBloc.saveFile(targetFile);
        } else {
          await targetFile.save();
        }
      } catch (e) {
        // Rollback destination additions if save fails
        newlyCopied.forEach(targetFile.deletePermanently);
        rethrow;
      }

      // Destination saved successfully; permanently delete original entries from source vaults without sending to Trash
      final sourceFiles = <KdbxFile>{};
      for (final src in crossVaultEntries) {
        src.file.deletePermanently(src);
        sourceFiles.add(src.file);
      }

      for (final sf in sourceFiles) {
        if (kdbxBloc != null) {
          await kdbxBloc.saveFile(sf);
        } else {
          await sf.save();
        }
      }

      movedEntries.addAll(newlyCopied);
    } else if (inVaultEntries.isNotEmpty) {
      if (kdbxBloc != null) {
        await kdbxBloc.saveFile(targetFile);
      } else {
        await targetFile.save();
      }
    }

    return movedEntries;
  }

  /// Safely deletes multiple [entries] from their respective vaults (moving to recycle bin if enabled).
  /// Batch-saves each affected vault once.
  static Future<void> bulkDeleteEntries({
    required Iterable<KdbxEntry> entries,
    KdbxBloc? kdbxBloc,
  }) async {
    final affectedFiles = <KdbxFile>{};

    for (final entry in entries) {
      affectedFiles.add(entry.file);
      entry.file.deleteEntry(entry);
    }

    for (final file in affectedFiles) {
      if (kdbxBloc != null) {
        await kdbxBloc.saveFile(file);
      } else {
        await file.save();
      }
    }
  }

  /// Interactive helper for moving or copying an entry into [targetGroup].
  /// If the target is in a different vault, prompts user whether to Move or Copy.
  /// Returns `true` if entry was moved (meaning it was removed from current vault),
  /// or `false` if entry was copied or operation was cancelled.
  static Future<bool> promptAndMoveOrCopyEntry({
    required BuildContext context,
    required KdbxEntry entry,
    required KdbxGroup targetGroup,
    required KdbxBloc kdbxBloc,
  }) async {
    if (entry.file == targetGroup.file) {
      entry.file.move(entry, targetGroup);
      await kdbxBloc.saveFile(entry.file);
      return true;
    }

    final targetVaultName = KeyNestVaultScope.cleanVaultName(
      kdbxBloc,
      targetGroup.file,
    );
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move or Copy to Vault?'),
        content: Text(
          'The selected folder is in "$targetVaultName".\n\n'
          'Would you like to move or copy this item to the other vault?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(ctx).pop('copy'),
            child: const Text('Copy Item'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop('move'),
            child: const Text('Move Item'),
          ),
        ],
      ),
    );

    if (choice == 'move') {
      await moveEntryToGroup(
        sourceEntry: entry,
        targetGroup: targetGroup,
        kdbxBloc: kdbxBloc,
      );
      return true;
    } else if (choice == 'copy') {
      await copyEntryToGroup(
        sourceEntry: entry,
        targetGroup: targetGroup,
        kdbxBloc: kdbxBloc,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Item copied to "$targetVaultName" folder "${targetGroup.name.get() ?? 'Folder'}".',
            ),
          ),
        );
      }
      return false;
    }
    return false;
  }
}

extension KeyNestEntryDuplication on KdbxEntry {
  /// Creates a duplicated copy of the entry with a unique UUID,
  /// copied fields, appended title suffix, updated timestamp, and placed into [parentGroup].
  KdbxEntry duplicate({String suffix = ' - Copy'}) {
    final parentGroup = parent ?? file.body.rootGroup;
    final cloned = KdbxEntry.create(file, parentGroup);
    parentGroup.addEntry(cloned);

    // Copy all string entries (username, password, URL, notes, custom fields, etc.)
    for (final entry in stringEntries) {
      cloned.setString(entry.key, entry.value);
    }

    // Copy custom data (e.g. FieldType_...)
    for (final cd in customData.entries) {
      cloned.customData[cd.key] = cd.value;
    }

    // Copy icon
    if (customIcon != null) {
      cloned.customIcon = customIcon;
    } else {
      cloned.icon.set(icon.get());
    }

    // Update Title with duplicate suffix
    final oldTitle = label?.isNotEmpty == true ? label! : 'Item';
    cloned.setString(KdbxKeyCommon.TITLE, PlainValue('$oldTitle$suffix'));

    // Copy any binary attachments
    for (final binEntry in binaryEntries) {
      if (cloned.getBinary(binEntry.key) == null) {
        cloned.file.ctx.addBinary(binEntry.value);
        cloned.createBinary(
          isProtected: binEntry.value.isProtected,
          name: binEntry.key.key,
          bytes: binEntry.value.value,
        );
      }
    }

    cloned.times.lastModificationTime.set(DateTime.now().toUtc());
    return cloned;
  }
}

class _CachedItemClassification {
  _CachedItemClassification({
    this.itemType,
    this.recordType,
    required this.modTime,
    required this.stringCount,
  });

  final KeyNestItemType? itemType;
  final String? recordType;
  final DateTime? modTime;
  final int stringCount;
}
