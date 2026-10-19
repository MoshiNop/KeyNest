import 'package:autofill_shared/credential_matcher.dart';
import 'package:kdbx/kdbx.dart';

/// In-memory-only record of a credential selected on Step 1 of a multi-step login.
/// Never persisted to disk. Never stores passwords or secrets.
class PendingLoginRecord {
  PendingLoginRecord({
    required this.entryUuid,
    required this.verifiedContext,
    required this.username,
    required this.createdAt,
  });

  final String entryUuid;
  final String verifiedContext;
  final String username;
  final DateTime createdAt;

  bool isExpired([Duration ttl = const Duration(minutes: 2)]) {
    return DateTime.now().difference(createdAt) > ttl;
  }
}

/// Service managing the carry-over of a chosen login entry to the subsequent password step.
class KeyNestPendingLoginMemory {
  KeyNestPendingLoginMemory._();

  static final KeyNestPendingLoginMemory instance =
      KeyNestPendingLoginMemory._();

  PendingLoginRecord? _currentRecord;

  /// Remembers the chosen entry on step 1 (username/email).
  void remember({
    required String entryUuid,
    required String verifiedContext,
    required String username,
  }) {
    _currentRecord = PendingLoginRecord(
      entryUuid: entryUuid,
      verifiedContext: verifiedContext.trim().toLowerCase(),
      username: username.trim(),
      createdAt: DateTime.now(),
    );
  }

  /// Retrieves the remembered entry if the context matches and has not expired.
  PendingLoginRecord? getRemembered(String targetContext) {
    final record = _currentRecord;
    if (record == null) {
      return null;
    }

    if (record.isExpired()) {
      _currentRecord = null;
      return null;
    }

    final normalizedTarget = targetContext.trim().toLowerCase();
    final normalizedSaved = record.verifiedContext;

    // Check exact match
    if (normalizedTarget == normalizedSaved) {
      return record;
    }

    // Check same registrable domain (eTLD+1)
    final savedDomain = CredentialMatcher.instance.registrableDomain(
      normalizedSaved,
    );
    final targetDomain = CredentialMatcher.instance.registrableDomain(
      normalizedTarget,
    );
    if (savedDomain != null &&
        targetDomain != null &&
        savedDomain == targetDomain) {
      return record;
    }

    return null;
  }

  /// Finds the matching [KdbxEntry] in the given open vaults for the remembered record.
  KdbxEntry? resolveEntry(List<KdbxFile> openFiles, String targetContext) {
    final record = getRemembered(targetContext);
    if (record == null) {
      return null;
    }

    for (final file in openFiles) {
      for (final entry in file.body.rootGroup.getAllEntries()) {
        if (entry.isInRecycleBin()) {
          continue;
        }
        if (entry.uuid.uuid == record.entryUuid) {
          return entry;
        }
      }
    }
    return null;
  }

  /// Clears the pending login memory.
  void clear() {
    _currentRecord = null;
  }
}
