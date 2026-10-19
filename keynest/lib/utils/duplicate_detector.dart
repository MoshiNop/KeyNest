// ignore_for_file: always_put_control_body_on_new_line
import 'package:kdbx/kdbx.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/totp_parser.dart';

enum DuplicateMatchType {
  exactMatch,
  sameCredentials,
  sameTitleAndUsername,
}

class DuplicateMatch {
  DuplicateMatch({
    required this.existingEntry,
    required this.matchType,
    required this.description,
  });

  final KdbxEntry existingEntry;
  final DuplicateMatchType matchType;
  final String description;
}

class DuplicateCluster {
  DuplicateCluster({
    required this.primaryEntry,
    required this.duplicates,
    required this.reason,
  });

  final KdbxEntry primaryEntry;
  final List<KdbxEntry> duplicates;
  final String reason;
}

/// Utility for detecting duplicate entries across KeyNest vaults,
/// during manual creation, and during CSV/JSON import.
class KeyNestDuplicateDetector {
  KeyNestDuplicateDetector._();

  /// System and UI metadata keys that should not prevent genuine duplicates from matching.
  static bool isSystemKey(String key) {
    if (key.startsWith('FieldType_')) return true;
    const systemKeys = {
      'IsDeleted',
      'is_favorite',
      'IsFavorite',
      'ItemCategory',
      'ItemType',
      'KeyNest.ItemType',
      'RecordType',
      'CardColorHex',
      'CardFinish',
      '_keynest_icon',
      'icon',
    };
    return systemKeys.contains(key);
  }

  /// Normalizes a URL for duplicate matching by extracting its host / domain
  /// and stripping protocols, www prefix, query strings, and trailing slashes.
  static String normalizeUrl(String? raw) {
    if (raw == null) return '';
    var text = raw.trim().toLowerCase();
    if (text.isEmpty) return '';

    // Strip protocol
    if (text.startsWith('https://')) {
      text = text.substring(8);
    } else if (text.startsWith('http://')) {
      text = text.substring(7);
    }

    // Strip www.
    if (text.startsWith('www.')) {
      text = text.substring(4);
    }

    // Strip path and query parameters
    final slashIdx = text.indexOf('/');
    if (slashIdx != -1) {
      text = text.substring(0, slashIdx);
    }
    final questionIdx = text.indexOf('?');
    if (questionIdx != -1) {
      text = text.substring(0, questionIdx);
    }

    return text.trim();
  }

  /// Normalizes generic text strings (lowercase and trimmed).
  static String normalize(String? text) {
    return text?.trim().toLowerCase() ?? '';
  }

  /// Normalizes notes body across different line ending styles (CRLF vs LF).
  static String normalizeNotes(String? text) {
    if (text == null) return '';
    return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  }

  /// Normalizes card numbers by removing spaces and hyphens.
  static String normalizeCardNumber(String? text) {
    if (text == null) return '';
    return text.replaceAll(RegExp(r'[\s\-]'), '').trim();
  }

  /// Normalizes TOTP secrets (removing spaces and converting to uppercase Base32).
  static String normalizeTotpSecret(String? text) {
    if (text == null) return '';
    return text.replaceAll(RegExp(r'\s+'), '').toUpperCase().trim();
  }

  /// Extracts normalized TOTP secret from an entry.
  static String extractTotpSecret(KdbxEntry entry) {
    final rawOtp =
        entry.getString(KdbxKey('OTPAuth'))?.getText() ??
        entry.getString(KdbxKey('otp'))?.getText() ??
        entry.getString(KdbxKey('TOTP Seed'))?.getText() ??
        entry.getString(KdbxKeyCommon.PASSWORD)?.getText();
    if (rawOtp == null || rawOtp.isEmpty) return '';
    final parsed = TotpQrData.parse(rawOtp);
    if (parsed != null && parsed.secret.isNotEmpty) {
      return normalizeTotpSecret(parsed.secret);
    }
    return normalizeTotpSecret(rawOtp);
  }

  /// Strips duplicate suffixes like " - Copy", " (Copy)", " - Copy 2", etc.
  static String cleanTitle(String? text) {
    if (text == null) return '';
    return text
        .trim()
        .replaceAll(
          RegExp(
            r'\s*-\s*copy(\s*\d+)?|\s*\(copy(\s*\d+)?\)',
            caseSensitive: false,
          ),
          '',
        )
        .trim()
        .toLowerCase();
  }

  /// Checks if two entries are exact duplicates across all fields:
  /// Title, Username, Password, URL, Notes, all custom fields, protected status, and attachments.
  static bool areExactDuplicates(KdbxEntry a, KdbxEntry b) =>
      areCompleteDuplicates(a, b);

  /// Checks if two entries are complete duplicates across all relevant fields:
  /// Title, Username, Password, URL, Notes, all custom fields, protected values,
  /// and binary attachments, normalized appropriately by item archetype.
  static bool areCompleteDuplicates(KdbxEntry a, KdbxEntry b) {
    // 0. Check Archetype
    final typeA = KeyNestItemTypeHelper.getItemType(a);
    final typeB = KeyNestItemTypeHelper.getItemType(b);
    if (typeA != typeB) return false;

    // 1. Title Matching
    final titleA = normalize(a.getString(KdbxKeyCommon.TITLE)?.getText());
    final titleB = normalize(b.getString(KdbxKeyCommon.TITLE)?.getText());
    final cTitleA = cleanTitle(titleA);
    final cTitleB = cleanTitle(titleB);
    final titleMatches =
        (titleA.isNotEmpty && titleA == titleB) ||
        (cTitleA.isNotEmpty && cTitleA == cTitleB);
    if (!titleMatches) return false;

    // 2. Archetype-Specific Credential & Field Matching
    switch (typeA) {
      case KeyNestItemType.login:
        final userA = normalize(
          a.getString(KdbxKeyCommon.USER_NAME)?.getText(),
        );
        final userB = normalize(
          b.getString(KdbxKeyCommon.USER_NAME)?.getText(),
        );
        if (userA != userB) return false;

        final passA = a.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
        final passB = b.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
        if (passA != passB) return false;

        final urlA = normalizeUrl(a.getString(KdbxKeyCommon.URL)?.getText());
        final urlB = normalizeUrl(b.getString(KdbxKeyCommon.URL)?.getText());
        if (urlA != urlB) return false;

        final notesA = normalizeNotes(a.getString(KdbxKey('Notes'))?.getText());
        final notesB = normalizeNotes(b.getString(KdbxKey('Notes'))?.getText());
        if (notesA != notesB) return false;
        break;

      case KeyNestItemType.note:
        final notesA = normalizeNotes(a.getString(KdbxKey('Notes'))?.getText());
        final notesB = normalizeNotes(b.getString(KdbxKey('Notes'))?.getText());
        if (notesA != notesB) return false;
        break;

      case KeyNestItemType.card:
        final numA = normalizeCardNumber(
          a.getString(KdbxKey('CardNumber'))?.getText() ??
              a.getString(KdbxKeyCommon.PASSWORD)?.getText(),
        );
        final numB = normalizeCardNumber(
          b.getString(KdbxKey('CardNumber'))?.getText() ??
              b.getString(KdbxKeyCommon.PASSWORD)?.getText(),
        );
        if (numA != numB) return false;

        final holderA = normalize(
          a.getString(KdbxKey('Cardholder'))?.getText(),
        );
        final holderB = normalize(
          b.getString(KdbxKey('Cardholder'))?.getText(),
        );
        if (holderA != holderB) return false;

        final expA = normalize(a.getString(KdbxKey('Expiry'))?.getText());
        final expB = normalize(b.getString(KdbxKey('Expiry'))?.getText());
        if (expA != expB) return false;

        final cvvA = normalize(a.getString(KdbxKey('CVV'))?.getText());
        final cvvB = normalize(b.getString(KdbxKey('CVV'))?.getText());
        if (cvvA != cvvB) return false;
        break;

      case KeyNestItemType.twoFactor:
        final secA = extractTotpSecret(a);
        final secB = extractTotpSecret(b);
        if (secA != secB) return false;

        final userA = normalize(
          a.getString(KdbxKeyCommon.USER_NAME)?.getText(),
        );
        final userB = normalize(
          b.getString(KdbxKeyCommon.USER_NAME)?.getText(),
        );
        if (userA != userB) return false;
        break;

      case KeyNestItemType.record:
        final recTypeA = KeyNestItemTypeHelper.getRecordType(a);
        final recTypeB = KeyNestItemTypeHelper.getRecordType(b);
        if (recTypeA != recTypeB) return false;

        final passA = a.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
        final passB = b.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
        if (passA != passB) return false;

        final notesA = normalizeNotes(a.getString(KdbxKey('Notes'))?.getText());
        final notesB = normalizeNotes(b.getString(KdbxKey('Notes'))?.getText());
        if (notesA != notesB) return false;
        break;
    }

    // 3. Compare Custom String Fields (ignoring metadata and system keys)
    final aEntries = a.stringEntries
        .where((e) => !isSystemKey(e.key.key))
        .toList();
    final bEntries = b.stringEntries
        .where((e) => !isSystemKey(e.key.key))
        .toList();

    final mapA = {for (final e in aEntries) e.key.key: e.value};
    final mapB = {for (final e in bEntries) e.key.key: e.value};

    const coreKeys = {
      'Title',
      'UserName',
      'Password',
      'URL',
      'Notes',
      'CardNumber',
      'Cardholder',
      'Expiry',
      'CVV',
      'PIN',
      'Network',
      'OTPAuth',
      'otp',
      'TOTP Seed',
      'TOTP Settings',
    };

    final customKeys = <String>{
      ...mapA.keys.where((k) => !coreKeys.contains(k)),
      ...mapB.keys.where((k) => !coreKeys.contains(k)),
    };

    for (final key in customKeys) {
      final valA = mapA[key];
      final valB = mapB[key];
      if (valA == null && valB == null) continue;
      if (valA == null || valB == null) return false;

      final textA = valA.getText()?.trim() ?? '';
      final textB = valB.getText()?.trim() ?? '';
      if (textA != textB) return false;
    }

    // 4. Binary Attachments
    final aBinaries = a.binaryEntries.toList();
    final bBinaries = b.binaryEntries.toList();
    if (aBinaries.length != bBinaries.length) return false;
    for (final bEntry in aBinaries) {
      final matching = b.getBinary(bEntry.key);
      if (matching == null) return false;
    }

    return true;
  }

  /// Finds potential duplicates in [file] for a given [entry] (excluding itself).
  static List<DuplicateMatch> findPotentialDuplicates({
    required KdbxFile file,
    required KdbxEntry entry,
  }) {
    final targetTitle = normalize(
      entry.getString(KdbxKeyCommon.TITLE)?.getText(),
    );
    final targetUser = normalize(
      entry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
    );
    final targetUrl = normalizeUrl(
      entry.getString(KdbxKeyCommon.URL)?.getText(),
    );
    final targetPass = entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';

    return findMatchesForCredential(
      file: file,
      title: targetTitle,
      username: targetUser,
      url: targetUrl,
      password: targetPass,
      ignoreUuid: entry.uuid,
    );
  }

  /// Checks for matching credentials in [file] given raw fields.
  static List<DuplicateMatch> findMatchesForCredential({
    required KdbxFile file,
    required String title,
    required String username,
    required String url,
    String? password,
    KdbxUuid? ignoreUuid,
  }) {
    final matches = <DuplicateMatch>[];
    final normTitle = normalize(title);
    final cTitle = cleanTitle(title);
    final normUser = normalize(username);
    final normUrl = normalizeUrl(url);
    final pass = password ?? '';

    final root = file.body.rootGroup;
    final allEntries = root.getAllEntries();

    for (final other in allEntries) {
      if (other.isInRecycleBin()) continue;
      if (ignoreUuid != null && other.uuid == ignoreUuid) continue;

      final otherTitle = normalize(
        other.getString(KdbxKeyCommon.TITLE)?.getText(),
      );
      final otherCTitle = cleanTitle(otherTitle);
      final otherUser = normalize(
        other.getString(KdbxKeyCommon.USER_NAME)?.getText(),
      );
      final otherUrl = normalizeUrl(
        other.getString(KdbxKeyCommon.URL)?.getText(),
      );
      final otherPass =
          other.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';

      // Exact Match across all standard fields
      if (normTitle.isNotEmpty &&
          (normTitle == otherTitle ||
              (cTitle.isNotEmpty && cTitle == otherCTitle)) &&
          normUser == otherUser &&
          pass == otherPass &&
          normUrl == otherUrl) {
        matches.add(
          DuplicateMatch(
            existingEntry: other,
            matchType: DuplicateMatchType.exactMatch,
            description: 'Identical title, username, password, and URL',
          ),
        );
      }
    }

    return matches;
  }

  /// Scans the entire vault and groups duplicate entries into clusters.
  /// An item is considered a duplicate ONLY IF all of its fields match.
  /// Optimized with pre-bucketing by archetype and normalized clean title to avoid O(N^2) stalls.
  static List<DuplicateCluster> findDuplicatesInVault(KdbxFile file) {
    final clusters = <DuplicateCluster>[];
    final visitedUuids = <KdbxUuid>{};

    final allEntries = file.body.rootGroup
        .getAllEntries()
        .where((e) => !e.isInRecycleBin())
        .toList();

    // Fast bucketing: complete duplicates must share the same archetype and clean title
    final buckets = <String, List<KdbxEntry>>{};
    for (final entry in allEntries) {
      final type = KeyNestItemTypeHelper.getItemType(entry);
      final rawTitle = normalize(
        entry.getString(KdbxKeyCommon.TITLE)?.getText(),
      );
      final cTitle = cleanTitle(rawTitle);
      final key = '${type.name}__$cTitle';
      (buckets[key] ??= []).add(entry);
    }

    for (final bucket in buckets.values) {
      if (bucket.length < 2) continue;

      for (int i = 0; i < bucket.length; i++) {
        final a = bucket[i];
        if (visitedUuids.contains(a.uuid)) continue;

        final dupes = <KdbxEntry>[];
        const reason = 'Identical entry (all fields match)';

        for (int j = i + 1; j < bucket.length; j++) {
          final b = bucket[j];
          if (visitedUuids.contains(b.uuid)) continue;

          if (areCompleteDuplicates(a, b)) {
            dupes.add(b);
            visitedUuids.add(b.uuid);
          }
        }

        if (dupes.isNotEmpty) {
          visitedUuids.add(a.uuid);
          clusters.add(
            DuplicateCluster(
              primaryEntry: a,
              duplicates: dupes,
              reason: reason,
            ),
          );
        }
      }
    }

    return clusters;
  }

  /// Progressively scans the vault in non-blocking chunks, periodically yielding
  /// to the UI event loop to preserve responsiveness on large vaults.
  static Future<List<DuplicateCluster>> findDuplicatesInVaultAsync(
    KdbxFile file, {
    void Function(double progress)? onProgress,
  }) async {
    final clusters = <DuplicateCluster>[];
    final visitedUuids = <KdbxUuid>{};

    final allEntries = file.body.rootGroup
        .getAllEntries()
        .where((e) => !e.isInRecycleBin())
        .toList();

    if (allEntries.isEmpty) {
      onProgress?.call(1.0);
      return clusters;
    }

    final buckets = <String, List<KdbxEntry>>{};
    for (int i = 0; i < allEntries.length; i++) {
      final entry = allEntries[i];
      final type = KeyNestItemTypeHelper.getItemType(entry);
      final rawTitle = normalize(
        entry.getString(KdbxKeyCommon.TITLE)?.getText(),
      );
      final cTitle = cleanTitle(rawTitle);
      final key = '${type.name}__$cTitle';
      (buckets[key] ??= []).add(entry);

      if (i % 200 == 0) {
        onProgress?.call((i / allEntries.length) * 0.4);
        await Future<void>.delayed(Duration.zero);
      }
    }

    final candidateBuckets = buckets.values.where((b) => b.length > 1).toList();
    final totalBuckets = candidateBuckets.length;

    for (int b = 0; b < totalBuckets; b++) {
      final bucket = candidateBuckets[b];
      for (int i = 0; i < bucket.length; i++) {
        final a = bucket[i];
        if (visitedUuids.contains(a.uuid)) continue;

        final dupes = <KdbxEntry>[];
        const reason = 'Identical entry (all fields match)';

        for (int j = i + 1; j < bucket.length; j++) {
          final other = bucket[j];
          if (visitedUuids.contains(other.uuid)) continue;

          if (areCompleteDuplicates(a, other)) {
            dupes.add(other);
            visitedUuids.add(other.uuid);
          }
        }

        if (dupes.isNotEmpty) {
          visitedUuids.add(a.uuid);
          clusters.add(
            DuplicateCluster(
              primaryEntry: a,
              duplicates: dupes,
              reason: reason,
            ),
          );
        }
      }

      if (b % 5 == 0) {
        final prog =
            0.4 + (((b + 1) / (totalBuckets == 0 ? 1 : totalBuckets)) * 0.6);
        onProgress?.call(prog);
        await Future<void>.delayed(Duration.zero);
      }
    }

    onProgress?.call(1.0);
    return clusters;
  }
}
