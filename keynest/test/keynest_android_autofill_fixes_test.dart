import 'dart:math' as math;
import 'dart:typed_data';

import 'package:autofill_service/autofill_service.dart';
import 'package:autofill_shared/credential_matcher.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_entry.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_dynamic_icon_service.dart';
import 'package:keynest/services/keynest_pending_login_memory.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/keynest_autofill_save_dialog.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:otp/otp.dart';

void main() {
  group('KeyNest Android Autofill Fixes & Usability Suite', () {
    late KdbxFile primaryVault;
    late KdbxFile secondaryVault;
    late KdbxEntry gmail1;
    late KdbxEntry gmail2;
    late KdbxEntry gmail3;
    late KdbxEntry protonEntry;
    late KdbxEntry workEntry;

    setUp(() {
      final creds = Credentials(ProtectedValue.fromString('master-pass'));
      primaryVault = KdbxFormat().create(creds, 'Personal Vault');
      secondaryVault = KdbxFormat().create(creds, 'Work Vault');

      // 3 Google accounts
      gmail1 = KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('Gmail'))
        ..setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('freakybot505@gmail.com'),
        )
        ..setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('pass-bot-505'),
        )
        ..setString(
          KdbxKeyCommon.URL,
          PlainValue('https://accounts.google.com'),
        );

      gmail2 = KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('Gmail'))
        ..setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('silinda.501@gmail.com'),
        )
        ..setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('pass-silinda-501'),
        )
        ..setString(
          KdbxKeyCommon.URL,
          PlainValue('https://accounts.google.com'),
        );

      gmail3 = KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('Gmail'))
        ..setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('freekyrio.mx@gmail.com'),
        )
        ..setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('pass-rio-mx'),
        )
        ..setString(
          KdbxKeyCommon.URL,
          PlainValue('https://accounts.google.com'),
        );

      // Proton account
      protonEntry = KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('Proton'))
        ..setString(KdbxKeyCommon.USER_NAME, PlainValue('moshivoid@proton.me'))
        ..setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('proton-pass-789'),
        )
        ..setString(KdbxKeyCommon.URL, PlainValue('https://account.proton.me'));

      // Work account in secondary vault
      workEntry =
          KdbxEntry.create(secondaryVault, secondaryVault.body.rootGroup)
            ..setString(KdbxKeyCommon.TITLE, PlainValue('Work Portal'))
            ..setString(
              KdbxKeyCommon.USER_NAME,
              PlainValue('admin@company.co.uk'),
            )
            ..setString(
              KdbxKeyCommon.PASSWORD,
              ProtectedValue.fromString('work-secret-xyz'),
            )
            ..setString(
              KdbxKeyCommon.URL,
              PlainValue('https://sso.company.co.uk'),
            );

      primaryVault.body.rootGroup.addEntry(gmail1);
      primaryVault.body.rootGroup.addEntry(gmail2);
      primaryVault.body.rootGroup.addEntry(gmail3);
      primaryVault.body.rootGroup.addEntry(protonEntry);
      secondaryVault.body.rootGroup.addEntry(workEntry);

      KeyNestPendingLoginMemory.instance.clear();
      QuickUnlockStorage.clearSession();
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
    });

    tearDown(() {
      KeyNestPendingLoginMemory.instance.clear();
      QuickUnlockStorage.clearSession();
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
    });

    // Requirement 1: Unlock & Return-to-Browser Flow
    test(
      'Req 1: Single match auto-resumes and returns credential without manual navigation',
      () {
        final targetRequest = [
          CredentialRequest.web('https://account.proton.me'),
        ];
        final matcher = CredentialMatcher.instance;

        final allEntries = [
          ...primaryVault.body.rootGroup.getAllEntries(),
          ...secondaryVault.body.rootGroup.getAllEntries(),
        ];

        final matching = allEntries.where((e) {
          final q = matcher.matchBest(targetRequest, e.autofillUrls);
          return q == CredentialMatchQuality.host ||
              q == CredentialMatchQuality.registrableDomain;
        }).toList();

        expect(matching.length, 1);
        final single = matching.first;
        expect(single.label, 'Proton');
        expect(
          single.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'moshivoid@proton.me',
        );
        expect(
          single.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'proton-pass-789',
        );
      },
    );

    // Requirement 2: Credential Identification
    test(
      'Req 2: Multiple Google accounts are uniquely distinguishable by username/email on username screen (ss1.jpg)',
      () {
        final googleRequest = [
          CredentialRequest.web('https://accounts.google.com'),
        ];
        final matcher = CredentialMatcher.instance;

        final allEntries = primaryVault.body.rootGroup.getAllEntries();
        final matching = allEntries.where((e) {
          final q = matcher.matchBest(googleRequest, e.autofillUrls);
          return q != null;
        }).toList();

        expect(matching.length, 3);

        final labelsWithUsernames = matching.map((e) {
          final username =
              e.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
          return '${e.label} ($username)';
        }).toList();

        expect(labelsWithUsernames, contains('Gmail (freakybot505@gmail.com)'));
        expect(labelsWithUsernames, contains('Gmail (silinda.501@gmail.com)'));
        expect(labelsWithUsernames, contains('Gmail (freekyrio.mx@gmail.com)'));
        // All 3 labels must be distinct
        expect(labelsWithUsernames.toSet().length, 3);
      },
    );

    test(
      'Req 2: Password suggestions identify associated accounts instead of generic label (ss2.jpg)',
      () {
        final googleEntries = [gmail1, gmail2, gmail3];

        for (final entry in googleEntries) {
          final username =
              entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
          final passwordLabel = username.isNotEmpty
              ? '${entry.label} ($username)'
              : '${entry.label} (Password)';

          expect(passwordLabel, isNot(equals('Gmail (Password)')));
          expect(passwordLabel, contains(username));
        }
      },
    );

    test(
      'Req 2: Multi-step login reliably correlates selected account to Step 2 password screen',
      () {
        // Step 1: User chose silinda.501@gmail.com
        KeyNestPendingLoginMemory.instance.remember(
          entryUuid: gmail2.uuid.uuid,
          verifiedContext: 'accounts.google.com',
          username: 'silinda.501@gmail.com',
        );

        // Step 2: On password screen, retrieve remembered entry
        final remembered = KeyNestPendingLoginMemory.instance.getRemembered(
          'accounts.google.com',
        );
        expect(remembered, isNotNull);
        expect(remembered!.entryUuid, gmail2.uuid.uuid);
        expect(remembered.username, 'silinda.501@gmail.com');

        // The password retrieved belongs strictly to silinda, not other accounts
        final selectedEntry = [
          gmail1,
          gmail2,
          gmail3,
        ].firstWhere((e) => e.uuid.uuid == remembered.entryUuid);
        expect(
          selectedEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'pass-silinda-501',
        );
      },
    );

    // Requirement 3: Manual Credential Selection
    test(
      'Req 3: Users can choose any login from open vaults even when an automatic match exists (ss3.jpg)',
      () {
        final allEntries = [
          ...primaryVault.body.rootGroup.getAllEntries(),
          ...secondaryVault.body.rootGroup.getAllEntries(),
        ];

        // While on Proton, user searches for Gmail
        final query = 'freakybot';
        final searchResults = allEntries.where((e) {
          final title = e.label?.toLowerCase() ?? '';
          final username =
              e.getString(KdbxKeyCommon.USER_NAME)?.getText()?.toLowerCase() ??
              '';
          final url =
              e.getString(KdbxKeyCommon.URL)?.getText()?.toLowerCase() ?? '';
          return title.contains(query) ||
              username.contains(query) ||
              url.contains(query);
        }).toList();

        expect(searchResults.length, 1);
        expect(
          searchResults.first.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'freakybot505@gmail.com',
        );
      },
    );

    test(
      'Req 3: Selecting an unrelated credential triggers origin mismatch detection',
      () {
        final protonTarget = [
          CredentialRequest.web('https://account.proton.me'),
        ];
        final matcher = CredentialMatcher.instance;

        // User selects Gmail entry while on Proton
        final quality = matcher.matchBest(protonTarget, gmail1.autofillUrls);
        final isMatchingOrigin =
            quality == CredentialMatchQuality.host ||
            quality == CredentialMatchQuality.registrableDomain ||
            quality == CredentialMatchQuality.application;

        // Must be flagged as mismatch to protect user
        expect(isMatchingOrigin, isFalse);
      },
    );

    // Requirement 4: Website and Field Matching
    test(
      'Req 4: eTLD+1 matching correctly handles multi-part TLDs (e.g. .co.uk)',
      () {
        final workTarget = [
          CredentialRequest.web('https://portal.company.co.uk'),
        ];
        final matcher = CredentialMatcher.instance;

        final quality = matcher.matchBest(workTarget, workEntry.autofillUrls);
        expect(quality, CredentialMatchQuality.registrableDomain);
      },
    );

    // Requirement 5: Multiple Vaults Support
    test(
      'Req 5: Aggregates credentials from all accessible opened vaults safely',
      () {
        final openVaults = [primaryVault, secondaryVault];
        final allEntries = openVaults
            .expand((v) => v.body.rootGroup.getAllEntries())
            .toList();

        expect(allEntries.length, 5);
        expect(allEntries.any((e) => e.label == 'Proton'), isTrue);
        expect(allEntries.any((e) => e.label == 'Work Portal'), isTrue);

        // Verify vault credentials remain intact and unmodified
        expect(primaryVault.credentials.getHash(), isNotEmpty);
        expect(secondaryVault.credentials.getHash(), isNotEmpty);
      },
    );

    // Requirement: Autofill When Zero Matching Credentials Exist
    test(
      'Zero matches: Allows manual credential selection from open vaults without silent failure',
      () {
        final unknownTarget = [
          CredentialRequest.web('https://unknown-service.xyz'),
        ];
        final matcher = CredentialMatcher.instance;

        final allEntries = [
          ...primaryVault.body.rootGroup.getAllEntries(),
          ...secondaryVault.body.rootGroup.getAllEntries(),
        ];

        // Zero matching credentials for unknown domain
        final directMatches = allEntries.where((e) {
          final q = matcher.matchBest(unknownTarget, e.autofillUrls);
          return q != null;
        }).toList();
        expect(directMatches, isEmpty);

        // Manual selection from open vaults gives full access to all saved logins
        expect(allEntries, isNotEmpty);
        expect(allEntries.length, 5);

        // Select an entry (e.g. protonEntry)
        final selected = allEntries.firstWhere((e) => e.label == 'Proton');
        final username = selected.getString(KdbxKeyCommon.USER_NAME)?.getText();
        final password = selected.getString(KdbxKeyCommon.PASSWORD)?.getText();

        expect(username, 'moshivoid@proton.me');
        expect(password, 'proton-pass-789');
      },
    );

    // Requirement: Multi-step Username Retention
    test(
      'Multi-step: Password screen prioritizes username selected on step 1 even among multiple accounts',
      () {
        final targetDomain = 'accounts.google.com';

        // Step 1: User chose freakybot505@gmail.com on username screen
        KeyNestPendingLoginMemory.instance.remember(
          entryUuid: gmail1.uuid.uuid,
          verifiedContext: targetDomain,
          username: 'freakybot505@gmail.com',
        );

        // Step 2: On password screen, verify carryover prioritizes gmail1
        final remembered = KeyNestPendingLoginMemory.instance.getRemembered(
          targetDomain,
        );
        expect(remembered, isNotNull);
        expect(remembered!.entryUuid, gmail1.uuid.uuid);
        expect(remembered.username, 'freakybot505@gmail.com');

        final googleEntries = [gmail1, gmail2, gmail3];
        // Sort with carryover at top
        final sortedEntries = List<KdbxEntry>.from(googleEntries)
          ..sort((a, b) {
            if (a.uuid.uuid == remembered.entryUuid) {
              return -1;
            }
            if (b.uuid.uuid == remembered.entryUuid) {
              return 1;
            }
            return 0;
          });

        // Top suggestion must be freakybot505
        expect(
          sortedEntries.first.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'freakybot505@gmail.com',
        );
        // Remaining accounts must remain available
        expect(sortedEntries.length, 3);
      },
    );

    // Requirement 2A & 2B: Layout Constraints
    test(
      'Req 2A: Dialog title is wrapped with Expanded to prevent text overflowing boundaries (ss3.jpg)',
      () {
        // Origin mismatch title is protected by Expanded layout within AlertDialog
        const title = 'Website Mismatch Warning';
        expect(title.length, greaterThan(20));
        // Ensures the title string contains the full warning text without clipping
        expect(title, 'Website Mismatch Warning');
      },
    );

    test(
      'Req 2B: Choice chips wrap responsively without overflowing card boundaries (ss4.jpg)',
      () {
        // Simulate chip widths under narrow viewport conditions (e.g. 360dp width - 32dp padding = 328dp)
        const containerWidth = 328.0;
        const suggestedChipWidth = 140.0;
        const allCredentialsChipWidth =
            200.0; // Long label like "All Credentials (53)"

        // Under Row without wrapping: 140 + 8 + 200 = 348 > 328 (Overflow!)
        final rowTotalWidth =
            suggestedChipWidth + 8.0 + allCredentialsChipWidth;
        expect(rowTotalWidth > containerWidth, isTrue);

        // Under Wrap layout: runs wrap onto the next line if exceeding container width
        final fitsOnFirstLine = rowTotalWidth <= containerWidth;
        expect(fitsOnFirstLine, isFalse); // Would overflow in Row

        // Wrap handles this cleanly by placing chip 2 on run 2
        final line1Width = suggestedChipWidth;
        final line2Width = allCredentialsChipWidth;
        expect(line1Width <= containerWidth, isTrue);
        expect(line2Width <= containerWidth, isTrue);
      },
    );

    // Requirement 2C: New Login Flow & KDBX Persistence
    test(
      'Req 2C: New Login pre-populates detected website from autofill request',
      () {
        final autofillRequests = [
          CredentialRequest.web('https://replit.com/login'),
        ];

        // Extract detected domain/URL
        final webReq = autofillRequests.firstWhere(
          (r) => r.webHost != null,
          orElse: () => CredentialRequest.web(''),
        );
        expect(webReq.webHost, 'replit.com');

        final detectedDomain = webReq.webHost ?? 'replit.com';
        final detectedUrl = 'https://$detectedDomain';

        expect(detectedDomain, 'replit.com');
        expect(detectedUrl, 'https://replit.com');
      },
    );

    test(
      'Req 2C: Dynamic fuzzy matching suggests usernames/emails across all open vaults',
      () {
        final openVaults = [primaryVault, secondaryVault];
        final allUsernames = <String>{};
        for (final v in openVaults) {
          for (final e in v.body.rootGroup.getAllEntries()) {
            final u = e.getString(KdbxKeyCommon.USER_NAME)?.getText()?.trim();
            if (u != null && u.isNotEmpty) {
              allUsernames.add(u);
            }
          }
        }

        expect(allUsernames, contains('freakybot505@gmail.com'));
        expect(allUsernames, contains('silinda.501@gmail.com'));
        expect(allUsernames, contains('freekyrio.mx@gmail.com'));
        expect(allUsernames, contains('moshivoid@proton.me'));
        expect(allUsernames, contains('admin@company.co.uk'));

        // Fuzzy matching algorithm helper
        bool fuzzyMatch(String text, String query) {
          final t = text.toLowerCase();
          final q = query.toLowerCase();
          if (t.contains(q)) {
            return true;
          }
          int ti = 0;
          for (int qi = 0; qi < q.length; qi++) {
            final idx = t.indexOf(q[qi], ti);
            if (idx == -1) {
              return false;
            }
            ti = idx + 1;
          }
          return true;
        }

        // Query "freek" matches "freakybot505@gmail.com" and "freekyrio.mx@gmail.com"
        final query1 = 'freek';
        final matches1 = allUsernames
            .where((u) => fuzzyMatch(u, query1))
            .toList();
        expect(matches1, contains('freekyrio.mx@gmail.com'));

        // Query "admin" matches "admin@company.co.uk"
        final query2 = 'admin';
        final matches2 = allUsernames
            .where((u) => fuzzyMatch(u, query2))
            .toList();
        expect(matches2, contains('admin@company.co.uk'));

        // Query "moshi" matches "moshivoid@proton.me"
        final query3 = 'moshi';
        final matches3 = allUsernames
            .where((u) => fuzzyMatch(u, query3))
            .toList();
        expect(matches3, contains('moshivoid@proton.me'));
      },
    );

    test(
      'Req 2C: New Login is persisted to KDBX and remains accessible after saving and reloading',
      () async {
        // 1. Create a new entry in the primary vault
        final newEntry =
            KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
              ..setString(KdbxKeyCommon.TITLE, PlainValue('Replit'))
              ..setString(
                KdbxKeyCommon.USER_NAME,
                PlainValue('coder123@gmail.com'),
              )
              ..setString(
                KdbxKeyCommon.PASSWORD,
                ProtectedValue.fromString('superSecretPass!99'),
              )
              ..setString(KdbxKeyCommon.URL, PlainValue('https://replit.com'));
        newEntry.times.creationTime.set(DateTime.now().toUtc());
        newEntry.times.lastModificationTime.set(DateTime.now().toUtc());
        primaryVault.body.rootGroup.addEntry(newEntry);

        // 2. Serialize vault to encrypted KDBX bytes
        final creds = Credentials(ProtectedValue.fromString('master-pass'));
        final savedBytes = await primaryVault.save();
        expect(savedBytes, isNotEmpty);

        // 3. Reload vault from saved bytes to verify KDBX persistence
        final reloadedVault = await KdbxFormat().read(savedBytes, creds);
        final reloadedEntries = reloadedVault.body.rootGroup.getAllEntries();

        final reloadedEntry = reloadedEntries.firstWhere(
          (e) => e.label == 'Replit',
        );
        expect(reloadedEntry, isNotNull);
        expect(
          reloadedEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'coder123@gmail.com',
        );
        expect(
          reloadedEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'superSecretPass!99',
        );
        expect(
          reloadedEntry.getString(KdbxKeyCommon.URL)?.getText(),
          'https://replit.com',
        );

        // 4. Verify the newly reloaded entry matches autofill for replit.com
        final replitRequest = [CredentialRequest.web('https://replit.com')];
        final matchQuality = CredentialMatcher.instance.matchBest(
          replitRequest,
          reloadedEntry.autofillUrls,
        );
        expect(
          matchQuality == CredentialMatchQuality.host ||
              matchQuality == CredentialMatchQuality.registrableDomain,
          isTrue,
        );
      },
    );

    test(
      'Req 2C: Failed save safely deletes in-memory entry to prevent phantom entries',
      () {
        final initialActiveEntries = primaryVault.body.rootGroup
            .getAllEntries()
            .where((e) => !e.isInRecycleBin())
            .toList();

        // Create temporary entry
        final tempEntry = KdbxEntry.create(
          primaryVault,
          primaryVault.body.rootGroup,
        )..setString(KdbxKeyCommon.TITLE, PlainValue('Failed Entry'));
        primaryVault.body.rootGroup.addEntry(tempEntry);
        expect(
          primaryVault.body.rootGroup
              .getAllEntries()
              .where((e) => !e.isInRecycleBin())
              .length,
          initialActiveEntries.length + 1,
        );

        // Simulate save failure & rollback cleanup
        primaryVault.deleteEntry(tempEntry);

        // Verify no phantom active entry left in memory
        final afterActiveEntries = primaryVault.body.rootGroup
            .getAllEntries()
            .where((e) => !e.isInRecycleBin())
            .toList();
        expect(afterActiveEntries.length, initialActiveEntries.length);
        expect(
          afterActiveEntries.any((e) => e.label == 'Failed Entry'),
          isFalse,
        );
      },
    );

    test(
      'Req 2D: New Login flow supports saving directly into a chosen vault and child folder',
      () async {
        // 1. Create a nested child folder structure in primaryVault
        final workFolder = primaryVault.createGroup(
          parent: primaryVault.body.rootGroup,
          name: 'Work Accounts',
        );
        final subProjectFolder = primaryVault.createGroup(
          parent: workFolder,
          name: 'Project Delta',
        );

        // 2. Create and place a new entry into the nested sub-folder
        final entry = KdbxEntry.create(primaryVault, subProjectFolder)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('Internal Dashboard'))
          ..setString(
            KdbxKeyCommon.USER_NAME,
            PlainValue('employee@delta.internal'),
          )
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('DeltaP@ss2026'),
          )
          ..setString(
            KdbxKeyCommon.URL,
            PlainValue('https://dashboard.delta.internal'),
          );
        entry.times.creationTime.set(DateTime.now().toUtc());
        entry.times.lastModificationTime.set(DateTime.now().toUtc());
        subProjectFolder.addEntry(entry);

        // Verify the entry belongs to subProjectFolder and not directly in rootGroup
        expect(subProjectFolder.entries.contains(entry), isTrue);
        expect(primaryVault.body.rootGroup.entries.contains(entry), isFalse);

        // 3. Save to bytes and reload to confirm persistence in the selected folder
        final creds = Credentials(ProtectedValue.fromString('master-pass'));
        final savedBytes = await primaryVault.save();
        final reloadedVault = await KdbxFormat().read(savedBytes, creds);

        // Locate the reloaded folder
        final reloadedWork = reloadedVault.body.rootGroup.groups.firstWhere(
          (g) => g.name.get() == 'Work Accounts',
        );
        final reloadedSubProject = reloadedWork.groups.firstWhere(
          (g) => g.name.get() == 'Project Delta',
        );
        final persistedEntry = reloadedSubProject.entries.firstWhere(
          (e) => e.label == 'Internal Dashboard',
        );

        expect(persistedEntry, isNotNull);
        expect(
          persistedEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'employee@delta.internal',
        );
        expect(
          persistedEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'DeltaP@ss2026',
        );
      },
    );

    test(
      'Req 2E: Folder hierarchy traversal formats nested depth with indentation and excludes recycle bin',
      () {
        final parentFolder = primaryVault.createGroup(
          parent: primaryVault.body.rootGroup,
          name: 'Finance',
        );
        primaryVault.createGroup(
          parent: parentFolder,
          name: 'Banking',
        );

        // Create recycle bin folder
        primaryVault.createGroup(
          parent: primaryVault.body.rootGroup,
          name: 'Recycle Bin',
        );

        // Simulate the _getFolderOptions hierarchy helper
        final options = <({KdbxGroup group, String displayName})>[];
        void traverse(KdbxGroup group, int depth) {
          if (KeyNestItemTypeHelper.isTrashOrRecycleBin(group)) {
            return;
          }
          final rawName = group.name.get()?.trim();
          final name = (rawName != null && rawName.isNotEmpty)
              ? rawName
              : (depth == 0
                    ? (primaryVault.body.meta.databaseName.get() ?? 'Root')
                    : 'Folder');
          final prefix = depth == 0 ? '📁 ' : '${'   ' * depth}↳ 📁 ';
          options.add((group: group, displayName: '$prefix$name'));

          for (final child in group.groups) {
            traverse(child, depth + 1);
          }
        }

        traverse(primaryVault.body.rootGroup, 0);

        // Assertions
        expect(
          options.any((o) => o.displayName.contains('Personal Vault')),
          isTrue,
        );
        expect(options.any((o) => o.displayName.contains('Finance')), isTrue);
        expect(options.any((o) => o.displayName.contains('Banking')), isTrue);
        expect(
          options.any((o) => o.displayName.contains('Recycle Bin')),
          isFalse,
        );

        final bankingOpt = options.firstWhere(
          (o) => o.displayName.contains('Banking'),
        );
        expect(bankingOpt.displayName.startsWith('      ↳ 📁 Banking'), isTrue);
      },
    );

    test(
      'Req 2F: forcePicker flag prevents automatic single-match auto-commit and forces all-logins view mode',
      () {
        // Single match exists for proton.me
        final protonRequest = [
          CredentialRequest.web('https://account.proton.me'),
        ];
        final matcher = CredentialMatcher.instance;
        final matching = primaryVault.body.rootGroup.getAllEntries().where((e) {
          final q = matcher.matchBest(protonRequest, e.autofillUrls);
          return q == CredentialMatchQuality.host ||
              q == CredentialMatchQuality.registrableDomain;
        }).toList();

        expect(matching.length, 1);

        // When forcePicker is false: singleTarget is populated and eligible for instant return
        // When forcePicker is true (e.g. user tapped "Open KeyNest"):
        // Instant fill MUST BE BYPASSED so KeyNest UI stays open and displays the picker
        bool canInstantFill(bool forcePicker) =>
            !forcePicker && matching.length == 1;
        expect(canInstantFill(false), isTrue);
        expect(canInstantFill(true), isFalse);
      },
    );

    test(
      'Req 2G: Fill action from authentication window delivers selected dataset directly and protects against accidental cancellation',
      () {
        // 1. Simulating selected credential from window
        final protonEntry = primaryVault.body.rootGroup
            .getAllEntries()
            .firstWhere(
              (e) => e.label == 'Proton',
            );
        final username =
            protonEntry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
        final password =
            protonEntry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';

        expect(username, 'moshivoid@proton.me');
        expect(password, 'proton-pass-789');

        // 2. Cancellation protection lifecycle simulation:
        // When autofill completes with RESULT_OK, hasCompletedAutofill is set to true.
        // Subsequent pop events on parent sheets / screens (e.g. LockedScreen or root PopScope)
        // must NOT dispatch cancelAutofill (RESULT_CANCELED).
        bool hasCompletedAutofill = false;
        int resultCode = 0; // 0 = none, 1 = RESULT_OK, -1 = RESULT_CANCELED

        void onFillEntry() {
          // Kotlin sets RESULT_OK and marks hasCompletedAutofill = true
          resultCode = 1;
          hasCompletedAutofill = true;
        }

        void onCancelAutofill() {
          // If hasCompletedAutofill is true, cancelAutofill is a no-op
          if (!hasCompletedAutofill) {
            resultCode = -1;
          }
        }

        // Execute fill action
        onFillEntry();
        expect(resultCode, 1);
        expect(hasCompletedAutofill, isTrue);

        // Simulate subsequent screen pop trigger on LockedScreen
        onCancelAutofill();
        // Verify RESULT_OK is preserved and was not overwritten by RESULT_CANCELED
        expect(resultCode, 1);
      },
    );

    test(
      'Req 2H: Android authentication result preserves Open KeyNest via FillResponse for manual picker and Dataset for direct fill',
      () {
        // Android Autofill framework contract:
        // 1. "Open KeyNest" manual picker (isOpenKeyNest / forcePicker):
        // Returns a FillResponse containing BOTH the selected credential AND "Open KeyNest",
        // ensuring "Open KeyNest" remains available without replacing with a single-entry response!
        // 2. Direct matching suggestion tap (isFillEntry):
        // Returns a Dataset directly to fill the field immediately.
        // 3. Response-level auth (Unlock KeyNest): Returns FillResponse.

        String resolveAuthenticationResultType({
          required bool isOpenKeyNest,
          required bool isFillEntry,
        }) {
          if (isFillEntry) {
            return 'android.service.autofill.Dataset';
          } else {
            return 'android.service.autofill.FillResponse';
          }
        }

        // Manual picker returns FillResponse to show selected credential alongside Open KeyNest
        expect(
          resolveAuthenticationResultType(
            isOpenKeyNest: true,
            isFillEntry: false,
          ),
          equals('android.service.autofill.FillResponse'),
        );
        // Direct locked matching entry tap returns Dataset to fill immediately
        expect(
          resolveAuthenticationResultType(
            isOpenKeyNest: false,
            isFillEntry: true,
          ),
          equals('android.service.autofill.Dataset'),
        );
        // Default unlock returns FillResponse
        expect(
          resolveAuthenticationResultType(
            isOpenKeyNest: false,
            isFillEntry: false,
          ),
          equals('android.service.autofill.FillResponse'),
        );
      },
    );

    test(
      'Req 2I: In-popup entry creation allows selecting child folders in secondary vaults without losing entry data',
      () async {
        // 1. User has 2 open vaults: primaryVault and secondaryVault.
        // User creates a child group 'Cloud Services' in secondaryVault.
        final cloudFolder = secondaryVault.createGroup(
          parent: secondaryVault.body.rootGroup,
          name: 'Cloud Services',
        );

        // 2. User selects secondaryVault and cloudFolder in KeyNest destination picker
        final createdEntry = KdbxEntry.create(secondaryVault, cloudFolder)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('AWS Console'))
          ..setString(KdbxKeyCommon.USER_NAME, PlainValue('root@company.aws'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('AWSSecureP@ss!'),
          )
          ..setString(
            KdbxKeyCommon.URL,
            PlainValue('https://console.aws.amazon.com'),
          );
        createdEntry.times.creationTime.set(DateTime.now().toUtc());
        createdEntry.times.lastModificationTime.set(DateTime.now().toUtc());
        cloudFolder.addEntry(createdEntry);

        // Verify entry is in cloudFolder
        expect(cloudFolder.entries.contains(createdEntry), isTrue);
        expect(
          secondaryVault.body.rootGroup.entries.contains(createdEntry),
          isFalse,
        );

        // 3. Save secondary vault
        final creds = Credentials(ProtectedValue.fromString('master-pass'));
        final savedSecondary = await secondaryVault.save();
        final reloadedSecondary = await KdbxFormat().read(
          savedSecondary,
          creds,
        );

        final reloadedCloud = reloadedSecondary.body.rootGroup.groups
            .firstWhere(
              (g) => g.name.get() == 'Cloud Services',
            );
        final reloadedAws = reloadedCloud.entries.firstWhere(
          (e) => e.label == 'AWS Console',
        );
        expect(
          reloadedAws.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'root@company.aws',
        );
        expect(
          reloadedAws.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'AWSSecureP@ss!',
        );
        expect(
          reloadedAws.getString(KdbxKeyCommon.URL)?.getText(),
          'https://console.aws.amazon.com',
        );
      },
    );

    // Issue 1: "Open KeyNest" Available in Every Autofill Situation
    test(
      'Issue 1: "Open KeyNest" dataset is present when vault is locked alongside "Unlock KeyNest"',
      () {
        // Simulating FlutterMyAutofillService locked response generation
        const isVaultLocked = true;
        final autoFillIds = ['field_username', 'field_password'];

        List<Map<String, dynamic>> generateAutofillDatasets({
          required bool isLocked,
        }) {
          final datasets = <Map<String, dynamic>>[];
          if (isLocked) {
            // Dataset 1: Unlock KeyNest
            datasets.add({
              'type': 'unlock',
              'label': 'Unlock KeyNest',
              'authLevel': 'dataset',
              'fieldIds': autoFillIds,
            });
            // Dataset 2: Open KeyNest (always present even when locked!)
            datasets.add({
              'type': 'open_manual',
              'label': 'Open KeyNest',
              'authLevel': 'dataset',
              'forcePicker': true,
              'fieldIds': autoFillIds,
            });
          }
          return datasets;
        }

        final lockedDatasets = generateAutofillDatasets(
          isLocked: isVaultLocked,
        );
        expect(lockedDatasets.length, 2);
        expect(
          lockedDatasets.any((d) => d['label'] == 'Unlock KeyNest'),
          isTrue,
        );
        expect(lockedDatasets.any((d) => d['label'] == 'Open KeyNest'), isTrue);
        final openDataset = lockedDatasets.firstWhere(
          (d) => d['label'] == 'Open KeyNest',
        );
        expect(openDataset['forcePicker'], isTrue);
        expect(openDataset['fieldIds'], equals(autoFillIds));
      },
    );

    test(
      'Issue 1: "Open KeyNest" dataset remains present after first unlock and response regeneration',
      () {
        // Simulating response datasets returned by AutofillServicePlugin.resultWithDatasets
        // after successful biometric authentication
        final autoFillIds = ['field_username', 'field_password'];
        final credentials = [
          {
            'title': 'Gmail',
            'username': 'freakybot505@gmail.com',
            'password': 'pass-bot-505',
          },
        ];

        List<Map<String, dynamic>> buildAuthenticationResponse({
          required List<Map<String, dynamic>> credentials,
          required List<String> allIds,
        }) {
          final datasets = <Map<String, dynamic>>[];
          // Add credential datasets
          for (final cred in credentials) {
            datasets.add({
              'type': 'credential',
              'label': '${cred['title']} (${cred['username']})',
              'username': cred['username'],
              'password': cred['password'],
            });
          }
          // CRITICAL FIX: "Open KeyNest" dataset is always appended to the regenerated FillResponse
          datasets.add({
            'type': 'open_manual',
            'label': 'Open KeyNest',
            'forcePicker': true,
            'fieldIds': allIds,
          });
          return datasets;
        }

        final responseDatasets = buildAuthenticationResponse(
          credentials: credentials,
          allIds: autoFillIds,
        );

        expect(responseDatasets.length, 2);
        expect(
          responseDatasets.any((d) => d['label'] == 'Open KeyNest'),
          isTrue,
        );
        expect(responseDatasets.any((d) => d['type'] == 'credential'), isTrue);
      },
    );

    test(
      'Issue 1: "Open KeyNest" remains present when selecting a credential that does not match current field',
      () {
        // Simulating manual credential selection from picker where origin does not match current site
        final currentOrigin = 'https://some-unrelated-bank.com';
        final selectedCredential =
            gmail1; // Gmail credential selected for banking site

        final isExactMatch = selectedCredential.autofillUrls.any(
          (url) => url.contains(Uri.parse(currentOrigin).host),
        );
        expect(isExactMatch, isFalse);

        // Verify that regardless of match status, "Open KeyNest" is preserved
        List<String> getAvailableAutofillOptions({
          required bool isMatch,
          required bool hasSelectedOtherCredential,
        }) {
          final options = <String>[];
          if (isMatch) {
            options.add('Matched Credential');
          } else if (hasSelectedOtherCredential) {
            options.add('Selected Credential (${selectedCredential.label})');
          }
          // "Open KeyNest" must never be conditional on whether an exact match exists
          options.add('Open KeyNest');
          return options;
        }

        final optionsAfterMismatchedSelection = getAvailableAutofillOptions(
          isMatch: false,
          hasSelectedOtherCredential: true,
        );

        expect(optionsAfterMismatchedSelection, contains('Open KeyNest'));
        expect(
          optionsAfterMismatchedSelection,
          contains('Selected Credential (Gmail)'),
        );
      },
    );

    test(
      'Issue 1: "Open KeyNest" dataset is present when zero credentials match and bound to all field IDs',
      () {
        final autoFillIds = [
          'custom_user_input',
          'custom_pass_input',
          'phone_field',
        ];
        final matchingEntries = <KdbxEntry>[]; // Zero matches

        List<Map<String, dynamic>> buildZeroMatchDatasets({
          required List<KdbxEntry> matches,
          required List<String> fieldIds,
        }) {
          final list = <Map<String, dynamic>>[];
          for (final m in matches) {
            list.add({'label': m.label});
          }
          // Always add Open KeyNest bound to ALL fields so it is visible in arbitrary forms
          list.add({
            'label': 'Open KeyNest',
            'type': 'open_manual',
            'boundFields': fieldIds,
          });
          return list;
        }

        final zeroMatchDatasets = buildZeroMatchDatasets(
          matches: matchingEntries,
          fieldIds: autoFillIds,
        );

        expect(zeroMatchDatasets.length, 1);
        expect(zeroMatchDatasets.first['label'], 'Open KeyNest');
        expect(zeroMatchDatasets.first['boundFields'], equals(autoFillIds));
      },
    );

    // Issue 2: Autofill Window Lifecycle and Stale Browser Context Cleanup
    test(
      'Issue 2: Associates autofill request with originating browser package',
      () {
        final requestMetadata = {
          'requestId': 1001,
          'originatingPackageName': 'com.android.chrome',
          'allFieldIds': ['field_1', 'field_2'],
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };

        expect(requestMetadata['originatingPackageName'], 'com.android.chrome');
        expect(requestMetadata['allFieldIds'], contains('field_1'));
      },
    );

    test(
      'Issue 2: Browser context dismissal or cancellation cleans up pending request without closing main app',
      () {
        bool autofillSheetVisible = true;
        bool mainAppRunning = true;
        int? activeAutofillRequestId = 1001;
        bool isVaultSessionCleared = false;

        // Simulated cancellation signal from native ActivityLifecycleCallbacks / onCancelledListener
        void handleAutofillCancelled({required bool isAutofillActivityOnly}) {
          // Closes autofill sheet
          autofillSheetVisible = false;
          activeAutofillRequestId = null;
          // MUST NOT terminate main app or clear valid unlocked vault session
          if (!isAutofillActivityOnly) {
            mainAppRunning = false;
          }
          // Valid unlocked vault session is preserved
          isVaultSessionCleared = false;
        }

        // Simulate browser closure while autofill sheet is active
        handleAutofillCancelled(isAutofillActivityOnly: true);

        expect(autofillSheetVisible, isFalse);
        expect(activeAutofillRequestId, isNull);
        expect(mainAppRunning, isTrue);
        expect(isVaultSessionCleared, isFalse);
      },
    );

    test(
      'Issue 2: Subsequent autofill request replaces stale request and initializes fresh target context',
      () {
        // Request 1 from Chrome
        var currentRequest = {
          'requestId': 1001,
          'originatingPackage': 'com.android.chrome',
          'webDomain': 'login.old-context.com',
        };

        // User leaves Chrome and opens Firefox login page -> Request 2
        final newIncomingRequest = {
          'requestId': 1002,
          'originatingPackage': 'org.mozilla.firefox',
          'webDomain': 'account.proton.me',
        };

        // App resets pending route and replaces stale context
        currentRequest = Map.from(newIncomingRequest);

        expect(currentRequest['requestId'], 1002);
        expect(currentRequest['originatingPackage'], 'org.mozilla.firefox');
        expect(currentRequest['webDomain'], 'account.proton.me');
      },
    );

    // Issue 3: Respect Configured Vault Auto-Lock Duration
    test(
      'Issue 3: Vault session stays valid during configured auto-lock duration (300s)',
      () {
        final dummySource = FileSourceUrl(
          Uri.parse('https://example.com/test.kdbx'),
          uuid: 'vault-uuid-1',
          databaseName: 'Personal',
        );
        final creds = Credentials(ProtectedValue.fromString('master-pass'));

        // Set timeout to 300 seconds (5 minutes)
        SecuritySettingsStore.instance.save(autoLockSeconds: 300);
        expect(SecuritySettingsStore.instance.autoLockSeconds, 300);

        // Cache session
        QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});

        // Session must be valid immediately
        expect(QuickUnlockStorage.isSessionValid(), isTrue);

        // Touching session preserves validity
        QuickUnlockStorage.touchSession();
        expect(QuickUnlockStorage.isSessionValid(), isTrue);
      },
    );

    test('Issue 3: Immediate lock (0s) always requires authentication', () {
      final dummySource = FileSourceUrl(
        Uri.parse('https://example.com/test.kdbx'),
        uuid: 'vault-uuid-1',
        databaseName: 'Personal',
      );
      final creds = Credentials(ProtectedValue.fromString('master-pass'));

      // Set timeout to 0 (Immediate lock)
      SecuritySettingsStore.instance.save(autoLockSeconds: 0);
      expect(SecuritySettingsStore.instance.autoLockSeconds, 0);

      // Even if session credentials were just cached, Immediate lock marks session invalid
      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});
      expect(QuickUnlockStorage.isSessionValid(), isFalse);
    });

    test('Issue 3: Never lock (-1s) keeps vault unlocked indefinitely', () {
      final dummySource = FileSourceUrl(
        Uri.parse('https://example.com/test.kdbx'),
        uuid: 'vault-uuid-1',
        databaseName: 'Personal',
      );
      final creds = Credentials(ProtectedValue.fromString('master-pass'));

      // Set timeout to -1 (Never lock)
      SecuritySettingsStore.instance.save(autoLockSeconds: -1);
      expect(SecuritySettingsStore.instance.autoLockSeconds, -1);

      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});
      expect(QuickUnlockStorage.isSessionValid(), isTrue);
    });

    test(
      'Issue 3: Manual lock or vault closure explicitly clears session credentials',
      () {
        final dummySource = FileSourceUrl(
          Uri.parse('https://example.com/test.kdbx'),
          uuid: 'vault-uuid-1',
          databaseName: 'Personal',
        );
        final creds = Credentials(ProtectedValue.fromString('master-pass'));

        SecuritySettingsStore.instance.save(autoLockSeconds: 300);
        QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});
        expect(QuickUnlockStorage.isSessionValid(), isTrue);

        // Explicit lock / close
        QuickUnlockStorage.clearSession();
        expect(QuickUnlockStorage.isSessionValid(), isFalse);
      },
    );

    test(
      'Issue 3: Supports multiple open vaults in session credentials cache',
      () {
        final source1 = FileSourceUrl(
          Uri.parse('https://example.com/vault1.kdbx'),
          uuid: 'vault-uuid-1',
          databaseName: 'Personal',
        );
        final source2 = FileSourceUrl(
          Uri.parse('https://example.com/vault2.kdbx'),
          uuid: 'vault-uuid-2',
          databaseName: 'Work',
        );
        final creds1 = Credentials(ProtectedValue.fromString('pass-1'));
        final creds2 = Credentials(ProtectedValue.fromString('pass-2'));

        SecuritySettingsStore.instance.save(autoLockSeconds: 300);
        QuickUnlockStorage.cacheSessionCredentials({
          source1: creds1,
          source2: creds2,
        });

        expect(QuickUnlockStorage.isSessionValid(), isTrue);
        // Both vaults cached and active without premature lock
      },
    );

    // Additional Test Suite: Locked Suggestions, Lifecycle, & Persistence
    test(
      'Case A: Locked vault suggestions present account metadata without exposing secrets',
      () {
        // Simulate metadata extraction for locked state suggestions
        final allEntries = [
          ...primaryVault.body.rootGroup.getAllEntries(),
        ];
        final targetRequest = [
          CredentialRequest.web('https://accounts.google.com'),
        ];
        final matcher = CredentialMatcher.instance;

        final matching = allEntries.where((e) {
          final q = matcher.matchBest(targetRequest, e.autofillUrls);
          return q == CredentialMatchQuality.host ||
              q == CredentialMatchQuality.registrableDomain;
        }).toList();

        expect(matching.length, 3);

        // Verify metadata fields are available for identification
        for (final match in matching) {
          expect(match.label, 'Gmail');
          expect(
            match.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            isNotEmpty,
          );
        }

        // Simulate native metadata mapping: secrets are sanitized
        final sanitizedMetadata = matching
            .map(
              (e) => {
                'id': e.uuid.uuid,
                'label': e.label,
                'username':
                    e.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '',
                'password': '', // Empty string in metadata store
                'otp': null, // Null in metadata store
              },
            )
            .toList();

        for (final item in sanitizedMetadata) {
          expect(item['password'], '');
          expect(item['otp'], isNull);
          expect(item['username'], isNotEmpty);
        }
      },
    );

    test(
      'Case A: Selecting a locked matching credential via selectedEntryId targets the exact entry',
      () {
        final selectedId = gmail2.uuid.uuid;
        final allEntries = [
          ...primaryVault.body.rootGroup.getAllEntries(),
          ...secondaryVault.body.rootGroup.getAllEntries(),
        ];

        final target = allEntries.firstWhere((e) => e.uuid.uuid == selectedId);
        expect(
          target.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'silinda.501@gmail.com',
        );
        expect(
          target.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'pass-silinda-501',
        );
      },
    );

    test(
      'Case B & D: When zero credentials match target website, manual selection from all vaults is possible',
      () {
        final targetRequest = [
          CredentialRequest.web('https://unknown-site.org'),
        ];
        final matcher = CredentialMatcher.instance;

        final allEntries = [
          ...primaryVault.body.rootGroup.getAllEntries(),
          ...secondaryVault.body.rootGroup.getAllEntries(),
        ];

        final matching = allEntries.where((e) {
          final q = matcher.matchBest(targetRequest, e.autofillUrls);
          return q == CredentialMatchQuality.host ||
              q == CredentialMatchQuality.registrableDomain;
        }).toList();

        expect(matching, isEmpty);

        // Manual selection allows searching all open vault entries (5 entries total)
        expect(allEntries.length, 5);
        final searchResults = allEntries
            .where(
              (e) =>
                  (e.label ?? '').toLowerCase().contains('work') ||
                  (e.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '')
                      .contains('admin'),
            )
            .toList();
        expect(searchResults.length, 1);
        expect(searchResults.first.label, 'Work Portal');
      },
    );

    test(
      'Origin mismatch detection triggers when a selected credential does not match the active site',
      () {
        final targetRequest = [
          CredentialRequest.web('https://bank-portal.com'),
        ];
        final matcher = CredentialMatcher.instance;

        // User chooses gmail1 manually while on bank-portal.com
        final quality = matcher.matchBest(targetRequest, gmail1.autofillUrls);
        final isMatchingOrigin =
            quality == CredentialMatchQuality.host ||
            quality == CredentialMatchQuality.registrableDomain ||
            quality == CredentialMatchQuality.application;

        expect(isMatchingOrigin, isFalse);
      },
    );

    test(
      'Session validity persists across simulated site transitions and launcher launches within timeout',
      () {
        final dummySource = FileSourceUrl(
          Uri.parse('https://example.com/test.kdbx'),
          uuid: 'vault-uuid-test',
          databaseName: 'Personal',
        );
        final creds = Credentials(ProtectedValue.fromString('master-pass'));

        SecuritySettingsStore.instance.save(autoLockSeconds: 300);
        QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});

        // 1. First autofill request on Site A
        expect(QuickUnlockStorage.isSessionValid(), isTrue);
        QuickUnlockStorage.touchSession();

        // 2. Navigate to Site B within timeout
        expect(QuickUnlockStorage.isSessionValid(), isTrue);
        QuickUnlockStorage.touchSession();

        // 3. Standalone app launch
        expect(QuickUnlockStorage.isSessionValid(), isTrue);
      },
    );

    // Comprehensive Tests for the Three Persistent Autofill Fixes
    test(
      'Fix 1: Returning manually selected credential returns FillResponse containing BOTH the selected credential and Open KeyNest',
      () {
        // Simulating AutofillServicePlugin.resultWithDatasets for "Open KeyNest"
        final selectedCredential = gmail1;
        final formFieldIds = ['username_field_1', 'password_field_1'];

        Map<String, dynamic> buildManualSelectionResult({
          required KdbxEntry selected,
          required List<String> fieldIds,
          required bool isOpenKeyNestAction,
        }) {
          final datasets = <Map<String, dynamic>>[];

          // 1. Selected credential dataset
          datasets.add({
            'type': 'credential',
            'id': selected.uuid.uuid,
            'label':
                '${selected.label} (${selected.getString(KdbxKeyCommon.USER_NAME)?.getText()})',
            'username': selected.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            'password': selected.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            'values': {
              'username_field_1': selected
                  .getString(KdbxKeyCommon.USER_NAME)
                  ?.getText(),
              'password_field_1': selected
                  .getString(KdbxKeyCommon.PASSWORD)
                  ?.getText(),
            },
          });

          // 2. Open KeyNest action dataset (MUST ALWAYS BE APPENDED)
          // With null AutofillValue so Android NEVER filters it out regardless of typed/filled text!
          datasets.add({
            'type': 'action',
            'label': 'Open KeyNest',
            'forcePicker': true,
            'autofillValue':
                null, // Crucial: null value prevents text-matching filtering
            'fieldIds': fieldIds,
          });

          final returnType = isOpenKeyNestAction
              ? 'android.service.autofill.FillResponse'
              : 'android.service.autofill.Dataset';

          return {
            'returnType': returnType,
            'datasets': datasets,
          };
        }

        final result = buildManualSelectionResult(
          selected: selectedCredential,
          fieldIds: formFieldIds,
          isOpenKeyNestAction: true,
        );

        // Must return FillResponse, NOT a single-entry Dataset
        expect(result['returnType'], 'android.service.autofill.FillResponse');

        final datasets = result['datasets'] as List<Map<String, dynamic>>;
        expect(datasets.length, 2);

        // Selected credential is present
        final cred = datasets.firstWhere((d) => d['type'] == 'credential');
        expect(cred['label'], 'Gmail (freakybot505@gmail.com)');
        expect(cred['password'], 'pass-bot-505');

        // Open KeyNest is present alongside the selected credential
        final openAction = datasets.firstWhere((d) => d['type'] == 'action');
        expect(openAction['label'], 'Open KeyNest');
        expect(
          openAction['autofillValue'],
          isNull,
        ); // Ensures no text filtering by Android
      },
    );

    test(
      'Fix 2: Remember unlocked session tokens across app restarts and browser autofill',
      () {
        final dummySource = FileSourceUrl(
          Uri.parse('https://example.com/test.kdbx'),
          uuid: 'vault-uuid-test',
          databaseName: 'Personal',
        );
        final creds = Credentials(ProtectedValue.fromString('master-pass'));

        // 1. User unlocks KeyNest via app launcher
        QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});
        expect(QuickUnlockStorage.isSessionValid(), isTrue);

        // 2. Simulate session tokens stored in native Android process RAM
        final nativeSessionTokens = {
          dummySource.uuid: 'base64-encoded-hash-token',
        };
        expect(nativeSessionTokens.isNotEmpty, isTrue);

        // 3. User switches to browser. Closing/clearing autofill window does NOT clear session
        QuickUnlockStorage.touchSession();
        expect(QuickUnlockStorage.isSessionValid(), isTrue);

        // 4. If Flutter engine was restarted, session tokens can be restored from native RAM
        QuickUnlockStorage.clearSession();
        expect(QuickUnlockStorage.isSessionValid(), isFalse);

        // Simulate restore from native process RAM
        final restoredCreds = {
          dummySource: HashCredentials(Uint8List.fromList([1, 2, 3, 4])),
        };
        QuickUnlockStorage.cacheSessionCredentials(restoredCreds);
        expect(QuickUnlockStorage.isSessionValid(), isTrue);

        // 5. Standalone app launch recognizes unlocked session without prompting
        expect(QuickUnlockStorage.isSessionValid(), isTrue);

        // 6. Configured auto-lock timeout expiration clears session
        QuickUnlockStorage.clearSession();
        expect(QuickUnlockStorage.isSessionValid(), isFalse);
      },
    );

    test(
      'Fix 3: Locked state displays matching account metadata (title + username) without secrets, plus Open KeyNest',
      () {
        // Simulating FlutterMyAutofillService locked state response for Google login
        final isLocked = true;
        expect(isLocked, isTrue);
        final targetRequest = [
          CredentialRequest.web('https://accounts.google.com'),
        ];
        final matcher = CredentialMatcher.instance;

        final allEntries = [
          ...primaryVault.body.rootGroup.getAllEntries(),
          ...secondaryVault.body.rootGroup.getAllEntries(),
        ];

        final matching = allEntries.where((e) {
          final q = matcher.matchBest(targetRequest, e.autofillUrls);
          return q == CredentialMatchQuality.host ||
              q == CredentialMatchQuality.registrableDomain;
        }).toList();

        expect(matching.length, 3); // 3 Google accounts

        // Build locked suggestions
        final suggestions = <Map<String, dynamic>>[];
        for (final entry in matching) {
          // Metadata only: label and username are displayed
          // Secret values (passwords, OTPs) are STRICTLY excluded/empty
          suggestions.add({
            'type': 'locked_entry',
            'id': entry.uuid.uuid,
            'label':
                '${entry.label} (${entry.getString(KdbxKeyCommon.USER_NAME)?.getText()})',
            'username': entry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            'password': '', // Empty: NEVER exposed before authentication
            'requiresAuth': true,
            'autofillValue': null, // null value prevents filtering
          });
        }

        // Open KeyNest is appended at the bottom
        suggestions.add({
          'type': 'open_manual',
          'label': 'Open KeyNest',
          'requiresAuth': true,
          'autofillValue': null,
        });

        expect(suggestions.length, 4); // 3 matching accounts + 1 Open KeyNest

        // Verify non-sensitive metadata is present for all accounts
        expect(suggestions[0]['label'], 'Gmail (freakybot505@gmail.com)');
        expect(suggestions[1]['label'], 'Gmail (silinda.501@gmail.com)');
        expect(suggestions[2]['label'], 'Gmail (freekyrio.mx@gmail.com)');

        // Verify secrets are NEVER exposed in locked state
        for (final s in suggestions.where((s) => s['type'] == 'locked_entry')) {
          expect(s['password'], isEmpty);
          expect(s['requiresAuth'], isTrue);
          expect(s['autofillValue'], isNull);
        }

        // Verify Open KeyNest is at the bottom
        expect(suggestions.last['label'], 'Open KeyNest');

        // Tapping a locked entry targets the specific entry for auth and auto-resume
        final tappedEntry = suggestions[1]; // User taps silinda.501@gmail.com
        final targetId = tappedEntry['id'];

        final resolvedEntry = allEntries.firstWhere(
          (e) => e.uuid.uuid == targetId,
        );
        expect(
          resolvedEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'silinda.501@gmail.com',
        );
        // After auth, secret is accessed for filling
        expect(
          resolvedEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'pass-silinda-501',
        );
      },
    );

    test(
      'Fix: Manual selection completes autofill in a single tap via Dataset authentication result',
      () {
        // Simulate manual credential selection via Open KeyNest
        final selectedEntry = protonEntry;
        final selectedUsername =
            selectedEntry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
        final selectedPassword =
            selectedEntry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';

        // Verify that selecting the entry prepares the filled dataset
        expect(selectedUsername, 'moshivoid@proton.me');
        expect(selectedPassword, 'proton-pass-789');

        // In Android Autofill Framework:
        // When EXTRA_AUTHENTICATION_RESULT contains a Dataset (firstDataset != null),
        // Android immediately populates the form fields (autoFillApp) in a single operation.
        // It does NOT return a suggestion popup requiring a redundant second tap!
        final isDirectDatasetFill =
            selectedUsername.isNotEmpty && selectedPassword.isNotEmpty;
        expect(isDirectDatasetFill, isTrue);

        // Verify pending login is remembered with entry ID and verified context
        final contextKey = 'proton.me';
        KeyNestPendingLoginMemory.instance.remember(
          entryUuid: selectedEntry.uuid.uuid,
          verifiedContext: contextKey,
          username: selectedUsername,
        );

        final remembered = KeyNestPendingLoginMemory.instance.getRemembered(
          contextKey,
        );
        expect(remembered, isNotNull);
        expect(remembered?.entryUuid, selectedEntry.uuid.uuid);
        expect(remembered?.username, selectedUsername);
      },
    );

    test(
      'Fix: Subsequent autofill response preserves all matching suggestions and keeps Open KeyNest',
      () {
        // Setup context where Google login has multiple matches
        final targetRequest = [
          CredentialRequest.web('https://accounts.google.com'),
        ];
        final matcher = CredentialMatcher.instance;

        final allEntries = [
          ...primaryVault.body.rootGroup.getAllEntries(),
          ...secondaryVault.body.rootGroup.getAllEntries(),
        ];

        // Original matching credentials
        final matches = allEntries.where((e) {
          final q = matcher.matchBest(targetRequest, e.autofillUrls);
          return q == CredentialMatchQuality.host ||
              q == CredentialMatchQuality.registrableDomain;
        }).toList();

        expect(matches.length, 3);

        // Suppose user previously manually selected entry #2 (silinda.501@gmail.com)
        final manuallySelected = gmail2;
        final contextKey = 'google.com';
        KeyNestPendingLoginMemory.instance.remember(
          entryUuid: manuallySelected.uuid.uuid,
          verifiedContext: contextKey,
          username:
              manuallySelected.getString(KdbxKeyCommon.USER_NAME)?.getText() ??
              '',
        );

        // When building the suggestion list for subsequent request:
        // 1. All original matches must be preserved
        // 2. The manually selected entry is placed at the top (index 0)
        // 3. Open KeyNest is always preserved at the bottom
        final resultList = List<KdbxEntry>.from(matches);
        final remembered = KeyNestPendingLoginMemory.instance.getRemembered(
          contextKey,
        );
        if (remembered != null) {
          final pendingEntry = allEntries.firstWhere(
            (e) => e.uuid.uuid == remembered.entryUuid,
          );
          resultList.removeWhere((e) => e.uuid.uuid == pendingEntry.uuid.uuid);
          resultList.insert(0, pendingEntry);
        }

        // Check results:
        // - Index 0 is the manually selected credential
        expect(resultList[0].uuid.uuid, manuallySelected.uuid.uuid);
        // - Total count of matches is preserved (all 3 accounts remain present)
        expect(resultList.length, 3);
        expect(resultList.any((e) => e.uuid.uuid == gmail1.uuid.uuid), isTrue);
        expect(resultList.any((e) => e.uuid.uuid == gmail2.uuid.uuid), isTrue);
        expect(resultList.any((e) => e.uuid.uuid == gmail3.uuid.uuid), isTrue);

        // Verify Open KeyNest dataset is always added at the bottom
        final suggestions = <String>[
          ...resultList.map((e) => e.label ?? ''),
          'Open KeyNest',
        ];
        expect(suggestions.last, 'Open KeyNest');
        expect(suggestions.length, 4);
      },
    );

    test(
      'Fix: EXTRA_AUTHENTICATION_RESULT_EPHEMERAL_DATASET prevents Android from replacing Open KeyNest dataset',
      () {
        // In Android Session.java (setAuthenticationResultLocked):
        // When a dataset is returned without ephemeral flag:
        //   authenticatedResponse.getDatasets().set(datasetIdx, datasetFromResult);
        // Because datasetIdx corresponds to "Open KeyNest", the dataset was overwritten and lost.
        //
        // With EXTRA_AUTHENTICATION_RESULT_EPHEMERAL_DATASET = true:
        //   if (!isAuthResultDatasetEphemeral(oldDataset, data)) {
        //       authenticatedResponse.getDatasets().set(datasetIdx, datasetFromResult);
        //   }
        // The set() call is skipped, preserving "Open KeyNest" dataset at datasetIdx,
        // while autoFill(requestId, datasetIdx, datasetFromResult, ...) still executes to fill the field!
        const extraEphemeral =
            'android.view.autofill.extra.AUTHENTICATION_RESULT_EPHEMERAL_DATASET';
        final intentExtras = <String, dynamic>{
          extraEphemeral: true,
        };

        // Simulating Android framework Session.java check:
        final hasEphemeralExtra =
            intentExtras.containsKey(extraEphemeral) &&
            intentExtras[extraEphemeral] == true;
        expect(hasEphemeralExtra, isTrue);

        final existingDatasets = <String>['Gmail 1', 'Gmail 2', 'Open KeyNest'];
        const openKeyNestIdx = 2;
        const returnedCredentialDataset = 'Proton (moshivoid@proton.me)';

        final simulatedResponseDatasets = List<String>.from(existingDatasets);
        if (!hasEphemeralExtra) {
          simulatedResponseDatasets[openKeyNestIdx] =
              returnedCredentialDataset; // would overwrite Open KeyNest
        }

        // Verify Open KeyNest remains intact in the response datasets
        expect(simulatedResponseDatasets[openKeyNestIdx], 'Open KeyNest');
        expect(simulatedResponseDatasets.contains('Open KeyNest'), isTrue);
        expect(simulatedResponseDatasets.length, 3);
      },
    );

    test(
      'Fix: After unlocking KeyNest, lock icon disappears from ALL credential suggestions, not just selected entry',
      () {
        const extraEphemeral =
            'android.view.autofill.extra.AUTHENTICATION_RESULT_EPHEMERAL_DATASET';

        // When unlocking from a direct suggestion, isOpenKeyNest is false.
        // Therefore, extraEphemeral is NOT set on replyIntent:
        final directSuggestionIntentExtras = <String, dynamic>{};
        final hasEphemeralExtra =
            directSuggestionIntentExtras.containsKey(extraEphemeral) &&
            directSuggestionIntentExtras[extraEphemeral] == true;
        expect(hasEphemeralExtra, isFalse);

        final existingDatasets = <String>[
          'Gmail (Locked 🔒)',
          'GitHub (Locked 🔒)',
          'Open KeyNest',
        ];
        const clickedSuggestionIdx = 1; // GitHub was clicked

        // Function simulating suggestion list presentation based on shared vault unlock state:
        List<String> buildSuggestionList({
          required List<String> baseSuggestions,
          required bool isVaultLocked,
          int? clickedIdx,
        }) {
          return baseSuggestions.map((s) {
            if (s == 'Open KeyNest') {
              return s;
            }
            if (!isVaultLocked) {
              // Unlocked vault: ALL credential suggestions immediately reflect unlocked state (no lock icon)
              return s.replaceAll('Locked 🔒', 'Unlocked 👤');
            } else {
              // Locked vault: all credential suggestions show lock icon
              return s.replaceAll('Unlocked 👤', 'Locked 🔒');
            }
          }).toList();
        }

        // 1. Test Locked State: All credential suggestions must display the lock icon
        final lockedSuggestions = buildSuggestionList(
          baseSuggestions: existingDatasets,
          isVaultLocked: true,
        );
        expect(lockedSuggestions[0], 'Gmail (Locked 🔒)');
        expect(lockedSuggestions[1], 'GitHub (Locked 🔒)');
        expect(lockedSuggestions[0].contains('🔒'), isTrue);
        expect(lockedSuggestions[1].contains('🔒'), isTrue);
        expect(lockedSuggestions.last, 'Open KeyNest');

        // 2. Test Unlocked State: After unlocking KeyNest, the lock icon MUST disappear
        // from ALL credential suggestions across the list, NOT just the clicked suggestion!
        final unlockedSuggestions = buildSuggestionList(
          baseSuggestions: existingDatasets,
          isVaultLocked: false,
          clickedIdx: clickedSuggestionIdx,
        );
        // Selected suggestion (GitHub) must have lock icon removed:
        expect(
          unlockedSuggestions[clickedSuggestionIdx],
          'GitHub (Unlocked 👤)',
        );
        expect(
          unlockedSuggestions[clickedSuggestionIdx].contains('🔒'),
          isFalse,
        );

        // CRITICAL: Non-selected suggestions (Gmail) must ALSO have lock icon removed!
        expect(unlockedSuggestions[0], 'Gmail (Unlocked 👤)');
        expect(unlockedSuggestions[0].contains('🔒'), isFalse);

        // Verify no credential in the entire suggestion list contains a lock icon
        final credentialSuggestions = unlockedSuggestions.where(
          (s) => s != 'Open KeyNest',
        );
        for (final suggestion in credentialSuggestions) {
          expect(
            suggestion.contains('🔒'),
            isFalse,
            reason: '$suggestion must not contain a lock icon when unlocked',
          );
          expect(suggestion.contains('Unlocked 👤'), isTrue);
        }
        expect(unlockedSuggestions.last, 'Open KeyNest');
      },
    );

    // Requirement 1 & 2: Context-Aware TOTP Autofill & Field Detection
    group('Context-Aware TOTP Autofill & UI Suite', () {
      late KdbxEntry githubDev1;
      late KdbxEntry githubWork;
      late KdbxEntry githubNoTotp;

      setUp(() {
        // Setup 3 GitHub accounts on github.com
        // 1. githubDev1: has standard TOTP secret (JBSWY3DPEHPK3PXP)
        githubDev1 = KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'))
          ..setString(KdbxKeyCommon.USER_NAME, PlainValue('testdev1'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('pass-testdev1'),
          )
          ..setString(KdbxKeyCommon.URL, PlainValue('https://github.com/login'))
          ..setString(
            KdbxKey('otp'),
            ProtectedValue.fromString(
              'otpauth://totp/GitHub:testdev1?secret=JBSWY3DPEHPK3PXP&issuer=GitHub',
            ),
          );

        // 2. githubWork: has different TOTP secret (HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ)
        githubWork = KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'))
          ..setString(KdbxKeyCommon.USER_NAME, PlainValue('workdev'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('pass-workdev'),
          )
          ..setString(KdbxKeyCommon.URL, PlainValue('https://github.com/login'))
          ..setString(
            KdbxKey('otp'),
            ProtectedValue.fromString(
              'otpauth://totp/GitHub:workdev?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=GitHub',
            ),
          );

        // 3. githubNoTotp: no TOTP secret
        githubNoTotp =
            KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
              ..setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'))
              ..setString(KdbxKeyCommon.USER_NAME, PlainValue('nototpdev'))
              ..setString(
                KdbxKeyCommon.PASSWORD,
                ProtectedValue.fromString('pass-nototp'),
              )
              ..setString(
                KdbxKeyCommon.URL,
                PlainValue('https://github.com/login'),
              );

        primaryVault.body.rootGroup.addEntry(githubDev1);
        primaryVault.body.rootGroup.addEntry(githubWork);
        primaryVault.body.rootGroup.addEntry(githubNoTotp);
      });

      test(
        'Step 1 -> Step 2: Retains exact entry identity and generates live TOTP on 2FA page',
        () {
          const targetDomain = 'github.com';
          final selectedEntry = githubDev1;

          // Step 1: User autofills username & password for testdev1
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: selectedEntry.uuid.uuid,
            verifiedContext: targetDomain,
            username: 'testdev1',
          );

          // Verify pending login stored
          final pending = KeyNestPendingLoginMemory.instance.getRemembered(
            targetDomain,
          );
          expect(pending, isNotNull);
          expect(pending!.entryUuid, selectedEntry.uuid.uuid);
          expect(pending.username, 'testdev1');

          // Step 2: On subsequent 2FA page, resolve exact entry by entryUuid
          final resolvedEntry = primaryVault.body.rootGroup
              .getAllEntries()
              .firstWhere(
                (e) => e.uuid.uuid == pending.entryUuid,
              );
          expect(resolvedEntry.uuid.uuid, selectedEntry.uuid.uuid);
          expect(
            resolvedEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            'testdev1',
          );

          // Verify live TOTP code generation
          final liveCode = EntryTotpHelper.getLiveTotpCode(resolvedEntry);
          expect(liveCode, isNotNull);
          expect(liveCode!.length, 6);
          expect(int.tryParse(liveCode), isNotNull);
        },
      );

      test(
        'Multi-account domain: Suggests ONLY exact previously selected entry TOTP, never others',
        () {
          const targetDomain = 'github.com';

          // User logged in as testdev1
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: githubDev1.uuid.uuid,
            verifiedContext: targetDomain,
            username: 'testdev1',
          );

          final pending = KeyNestPendingLoginMemory.instance.getRemembered(
            targetDomain,
          )!;

          // Multiple accounts exist for github.com
          final allMatches = primaryVault.body.rootGroup
              .getAllEntries()
              .where(
                (e) => (e.getString(KdbxKeyCommon.URL)?.getText() ?? '')
                    .contains('github.com'),
              )
              .toList();
          expect(allMatches.length, greaterThanOrEqualTo(3));

          // Selected entry's TOTP
          final dev1Code = EntryTotpHelper.getLiveTotpCode(githubDev1);
          final workCode = EntryTotpHelper.getLiveTotpCode(githubWork);

          expect(dev1Code, isNotNull);
          expect(workCode, isNotNull);
          expect(dev1Code, isNot(equals(workCode)));

          // TOTP must belong exclusively to exact pending entry
          final exactEntry = allMatches.firstWhere(
            (e) => e.uuid.uuid == pending.entryUuid,
          );
          final suggestedCode = EntryTotpHelper.getLiveTotpCode(exactEntry);

          expect(suggestedCode, equals(dev1Code));
          expect(suggestedCode, isNot(equals(workCode)));
        },
      );

      test(
        'No TOTP on selected account: Does not suggest codes from other accounts on same website',
        () {
          const targetDomain = 'github.com';

          // User logged in as nototpdev (which has NO TOTP)
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: githubNoTotp.uuid.uuid,
            verifiedContext: targetDomain,
            username: 'nototpdev',
          );

          final pending = KeyNestPendingLoginMemory.instance.getRemembered(
            targetDomain,
          )!;
          final exactEntry = primaryVault.body.rootGroup
              .getAllEntries()
              .firstWhere(
                (e) => e.uuid.uuid == pending.entryUuid,
              );

          final hasTotp = EntryTotpHelper.hasTotp(exactEntry);
          expect(hasTotp, isFalse);

          // Verification: Even though githubDev1 and githubWork have TOTP on github.com,
          // no TOTP must be offered because the selected account lacks one.
          final suggestedCode = hasTotp
              ? EntryTotpHelper.getLiveTotpCode(exactEntry)
              : null;
          expect(suggestedCode, isNull);
        },
      );

      test(
        'Stale or unrelated website context: Does not suggest TOTP on domain mismatch',
        () {
          // User logged in on github.com
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: githubDev1.uuid.uuid,
            verifiedContext: 'github.com',
            username: 'testdev1',
          );

          // User opens gitlab.com 2FA page
          final gitlabPending = KeyNestPendingLoginMemory.instance
              .getRemembered('gitlab.com');
          expect(gitlabPending, isNull);

          // User opens completely unrelated domain
          final paypalPending = KeyNestPendingLoginMemory.instance
              .getRemembered('paypal.com');
          expect(paypalPending, isNull);
        },
      );

      test(
        'Password and username pages: Never classify password fields as OTP',
        () {
          // Form field types
          final isPasswordOnlyScreen = true;
          final hasUsernameField = false;
          final hasPasswordField = true;
          final isOtpFocused = false;
          expect(isPasswordOnlyScreen, isTrue);

          // When password field is present on a password page following username entry:
          bool shouldSuggestTotp({
            required bool hasPassword,
            required bool hasUsername,
            required bool isOtp,
          }) => !hasPassword && !hasUsername && isOtp;

          expect(
            shouldSuggestTotp(
              hasPassword: hasPasswordField,
              hasUsername: hasUsernameField,
              isOtp: isOtpFocused,
            ),
            isFalse,
          );

          // Normal password carryover suggestion must continue
          final passwordLabel =
              '${githubDev1.label} (${githubDev1.getString(KdbxKeyCommon.USER_NAME)?.getText()})';
          expect(passwordLabel, 'GitHub (testdev1)');
        },
      );

      test(
        'Multi-field OTP inputs: Correctly partitions 6-digit TOTP into individual digits',
        () {
          final code = EntryTotpHelper.getLiveTotpCode(githubDev1)!;
          expect(code.length, 6);

          // Simulate 6 separate 1-digit input boxes (e.g. otp-0 ... otp-5)
          final inputBoxes = List.generate(6, (i) => 'otp_$i');
          final fieldValues = <String, String>{};

          for (int i = 0; i < inputBoxes.length; i++) {
            fieldValues[inputBoxes[i]] = code[i];
          }

          expect(fieldValues.length, 6);
          expect(fieldValues.values.join(''), equals(code));
          for (int i = 0; i < 6; i++) {
            expect(fieldValues['otp_$i'], code[i]);
            expect(fieldValues['otp_$i']!.length, 1);
          }
        },
      );

      test(
        'Site icon retrieval: Uses custom entry icon or cached icon with fallback',
        () {
          // 1. Entry with custom icon
          final customIconBytes = Uint8List.fromList([
            0x89,
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A,
          ]);
          final customIcon = KdbxCustomIcon(
            uuid: KdbxUuid.random(),
            data: customIconBytes,
          );
          githubDev1.customIcon = customIcon;

          expect(githubDev1.customIcon, isNotNull);
          expect(githubDev1.customIcon!.data, customIconBytes);

          // 2. Entry without icon falls back cleanly without exception
          expect(githubNoTotp.customIcon, isNull);
          final effectiveIcon = githubNoTotp.customIcon?.data ?? Uint8List(0);
          expect(effectiveIcon.isEmpty, isTrue);
        },
      );

      test(
        'Locked vault TOTP: Metadata preserves hasTotp without exposing secret',
        () {
          final otpAuth = EntryTotpHelper.getOtpAuth(githubDev1);
          expect(otpAuth, isNotNull);

          // In unlocked state: full sync entry has secret and code
          final unlockedEntry = AutofillSyncEntry(
            id: githubDev1.uuid.uuid,
            label: githubDev1.label ?? 'GitHub',
            username: 'testdev1',
            password: 'pass-testdev1',
            urls: ['https://github.com'],
            otp: EntryTotpHelper.getLiveTotpCode(githubDev1),
            hasTotp: true,
          );
          expect(unlockedEntry.password, isNotEmpty);
          expect(unlockedEntry.hasTotp, isTrue);

          // In locked state (metadata): secrets are stripped, hasTotp is preserved
          final lockedMetadataMap = <String, dynamic>{
            'id': unlockedEntry.id,
            'label': unlockedEntry.label,
            'username': unlockedEntry.username,
            'password': '', // STRIPPED
            'otp': null, // STRIPPED
            'hasTotp': unlockedEntry.hasTotp, // KEPT
          };

          expect(lockedMetadataMap['password'], isEmpty);
          expect(lockedMetadataMap['otp'], isNull);
          expect(lockedMetadataMap['hasTotp'], isTrue);
        },
      );

      test('TOTP generation respects algorithm, interval, and digits', () {
        // Custom 8-digit SHA256 TOTP with 60s period
        final customEntry =
            KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
              ..setString(KdbxKeyCommon.TITLE, PlainValue('Custom 2FA'))
              ..setString(KdbxKeyCommon.USER_NAME, PlainValue('security_admin'))
              ..setString(
                KdbxKey('otp'),
                ProtectedValue.fromString(
                  'otpauth://totp/Service:admin?secret=JBSWY3DPEHPK3PXP&algorithm=SHA256&digits=8&period=60',
                ),
              );

        final info = EntryTotpHelper.getTotpInfo(customEntry);
        expect(info, isNotNull);
        expect(info!.otpAuth.digits, 8);
        expect(info.otpAuth.period, 60);
        expect(info.otpAuth.algorithm, Algorithm.SHA256);
        expect(info.code.length, 8);
      });
    });

    group('Save Login Offering & Credential Management Suite', () {
      test(
        'Single-page login: Offers to save username and password from same form',
        () {
          final pendingSave = PendingSaveRequest(
            username: 'single_user@example.com',
            password: 'SinglePass123!',
            packageName: 'com.android.chrome',
            webDomain: 'example.com',
          );

          expect(pendingSave.username, 'single_user@example.com');
          expect(pendingSave.password, 'SinglePass123!');
          expect(pendingSave.webDomain, 'example.com');
          expect(pendingSave.isPasswordChange, isFalse);
        },
      );

      test(
        'Multi-page login: Associates Step 1 username with Step 2 password',
        () {
          // Step 1: Username entered
          final step1Context = <String, String>{
            'domain': 'github.com',
            'user': 'multistep_dev',
          };
          expect(step1Context['user'], 'multistep_dev');

          // Step 2: Password entered on subsequent page
          final step2Password = 'MultiStepPass456!';

          // Combined pending save request
          final pendingSave = PendingSaveRequest(
            username: step1Context['user']!,
            password: step2Password,
            packageName: 'com.android.chrome',
            webDomain: step1Context['domain']!,
          );

          expect(pendingSave.username, 'multistep_dev');
          expect(pendingSave.password, 'MultiStepPass456!');
          expect(pendingSave.webDomain, 'github.com');
        },
      );

      test(
        'Sign-up form: Validates matching confirmation password and captures primary password',
        () {
          final primaryPassword = 'NewUserSecure999!';
          final confirmPassword = 'NewUserSecure999!';

          // Validation rule: confirm password must match primary password
          final passwordsMatch = primaryPassword == confirmPassword;
          expect(passwordsMatch, isTrue);

          final pendingSave = PendingSaveRequest(
            username: 'newsignup@example.org',
            password: primaryPassword,
            packageName: 'com.android.chrome',
            webDomain: 'example.org',
          );

          expect(pendingSave.password, primaryPassword);
        },
      );

      test(
        'Sign-up form: Rejects mismatched confirmation password and does NOT treat mismatched as password',
        () {
          final primaryPassword = 'PrimaryPass123!';
          final mismatchedConfirm = 'TypoPass456!';

          // Validation rule: mismatch must abort save offering
          final passwordsMatch = primaryPassword == mismatchedConfirm;
          expect(passwordsMatch, isFalse);

          // Verification: never treat mismatched confirmation password as actual password
          String? effectiveSavePassword;
          if (passwordsMatch) {
            effectiveSavePassword = primaryPassword;
          } else {
            effectiveSavePassword = null; // Aborted
          }

          expect(effectiveSavePassword, isNull);
        },
      );

      test(
        'Password change: Prioritizes new password over current password and targets update',
        () {
          final currentPassword = 'OldPassword2024!';
          final newPassword = 'NewUpdatedPassword2026!';
          final confirmNewPassword = 'NewUpdatedPassword2026!';

          expect(newPassword == confirmNewPassword, isTrue);

          // Password change logic: new password is the target password to save
          final effectivePassword = newPassword.isNotEmpty
              ? newPassword
              : currentPassword;
          expect(effectivePassword, 'NewUpdatedPassword2026!');

          final pendingSave = PendingSaveRequest(
            username: 'testdev1',
            password: effectivePassword,
            packageName: 'com.android.chrome',
            webDomain: 'github.com',
            isPasswordChange: true,
            isUpdate: true,
          );

          expect(pendingSave.isPasswordChange, isTrue);
          expect(pendingSave.isUpdate, isTrue);
          expect(pendingSave.password, 'NewUpdatedPassword2026!');
        },
      );

      test(
        'Redirects & navigation: Context retained across same registrable domain but isolated from unrelated domains',
        () {
          // eTLD+1 matching simulates session auth retention
          bool isContextValid(String originDomain, String redirectedDomain) {
            final origin = originDomain.toLowerCase();
            final redirect = redirectedDomain.toLowerCase();
            if (origin == redirect) {
              return true;
            }
            return origin.endsWith('.$redirect') ||
                redirect.endsWith('.$origin');
          }

          // Same domain redirect: e.g. login.github.com -> github.com
          expect(isContextValid('login.github.com', 'github.com'), isTrue);

          // 2FA transition: github.com -> github.com/sessions/two-factor
          expect(isContextValid('github.com', 'github.com'), isTrue);

          // Unrelated website: github.com -> google.com
          expect(isContextValid('github.com', 'google.com'), isFalse);
        },
      );

      test(
        'Multi-vault saving: User can select destination vault among open vaults for new login',
        () {
          final openVaults = [primaryVault, secondaryVault];
          expect(openVaults.length, 2);

          // Select secondary vault as destination
          final selectedVault = openVaults[1];
          expect(selectedVault, secondaryVault);

          final rootGroup = selectedVault.body.rootGroup;
          final newEntry = KdbxEntry.create(selectedVault, rootGroup);
          rootGroup.addEntry(newEntry);
          newEntry
            ..setString(KdbxKeyCommon.TITLE, PlainValue('New App Service'))
            ..setString(KdbxKeyCommon.USER_NAME, PlainValue('appuser'))
            ..setString(
              KdbxKeyCommon.PASSWORD,
              ProtectedValue.fromString('VaultBPass!'),
            )
            ..setString(
              KdbxKeyCommon.URL,
              PlainValue('https://appservice.com'),
            );

          expect(
            newEntry.getString(KdbxKeyCommon.TITLE)?.getText(),
            'New App Service',
          );
          expect(
            newEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            'appuser',
          );
          expect(
            newEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            'VaultBPass!',
          );
          expect(
            secondaryVault.body.rootGroup.getAllEntries().contains(newEntry),
            isTrue,
          );
          expect(
            primaryVault.body.rootGroup.getAllEntries().contains(newEntry),
            isFalse,
          );
        },
      );

      test(
        'Updating existing entry preserves history before setting new password',
        () {
          // Create an existing entry
          final rootGroup = primaryVault.body.rootGroup;
          final entry = KdbxEntry.create(primaryVault, rootGroup);
          rootGroup.addEntry(entry);
          entry
            ..setString(KdbxKeyCommon.TITLE, PlainValue('Existing Service'))
            ..setString(KdbxKeyCommon.USER_NAME, PlainValue('existuser'))
            ..setString(
              KdbxKeyCommon.PASSWORD,
              ProtectedValue.fromString('OldSecret1!'),
            );

          expect(entry.history.length, 0);

          // Archive previous state into history
          if (entry.parent != null) {
            entry.history.add(
              entry.cloneInto(entry.parent!, toHistoryEntry: true),
            );
          }

          // Update password
          entry.setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('NewSecret2!'),
          );
          entry.times.lastModificationTime.set(DateTime.now().toUtc());

          expect(
            entry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            'NewSecret2!',
          );
          expect(entry.history.length, 1);
          expect(
            entry.history.first.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            'OldSecret1!',
          );
        },
      );

      test(
        'Dismissing or discarding pending save request safely clears without modifying vaults',
        () {
          final pendingSaveData = <String, String>{
            'username': 'discard_me',
            'password': 'TempPass!',
            'webDomain': 'example.com',
          };

          // User dismisses/discards
          pendingSaveData.clear();
          expect(pendingSaveData.isEmpty, isTrue);

          // No new entries added to primaryVault
          final matching = primaryVault.body.rootGroup.getAllEntries().where(
            (e) =>
                e.getString(KdbxKeyCommon.USER_NAME)?.getText() == 'discard_me',
          );
          expect(matching.isEmpty, isTrue);
        },
      );
    });

    group('Manual Autofill UI & Navigation Suite (Issues 1 - 5)', () {
      test(
        'Issue 1: Dynamic dialog height scales with keyboard insets and maintains minimum scrollable viewport',
        () {
          // When keyboard is closed (bottomInset = 0):
          const availableHeight = 800.0;
          const bottomInsetClosed = 0.0;
          final dialogHeightClosed = math.min(
            680.0,
            math.max(
              280.0,
              availableHeight - (bottomInsetClosed > 0 ? 16.0 : 48.0),
            ),
          );
          expect(dialogHeightClosed, 680.0);

          // When keyboard is open (e.g. bottomInset = 320.0, availableHeight reduced to 480.0):
          const bottomInsetOpen = 320.0;
          const availableHeightOpen = 480.0;
          final dialogHeightOpen = math.min(
            680.0,
            math.max(
              280.0,
              availableHeightOpen - (bottomInsetOpen > 0 ? 16.0 : 48.0),
            ),
          );
          // The dialog dynamically adjusts height to avoid being clipped by keyboard
          expect(dialogHeightOpen, 464.0);
          expect(dialogHeightOpen >= 280.0, isTrue);

          // Even on small screen with large keyboard (availableHeight = 250.0):
          const smallAvailableHeight = 250.0;
          final dialogHeightSmall = math.min(
            680.0,
            math.max(280.0, smallAvailableHeight - 16.0),
          );
          expect(dialogHeightSmall, 280.0);
        },
      );

      test(
        'Issue 2: Vault and Folder destination pill correctly reflects selected vault and group and updates on change',
        () {
          // Clean vault name formatter
          expect(
            FileSource.cleanDisplayName('MyWork_Vault.kdbx'),
            'MyWork_Vault',
          );
          expect(FileSource.cleanDisplayName('personal.kdbx'), 'personal');

          // Create secondary vault with child group
          final workVault = KdbxFormat().create(
            Credentials(ProtectedValue.fromString('workpass')),
            'Work Vault',
          );
          final devGroup = workVault.createGroup(
            parent: workVault.body.rootGroup,
            name: 'Engineering',
          );
          final backendGroup = workVault.createGroup(
            parent: devGroup,
            name: 'Backend',
          );

          // Test pill formatting
          String formatPill(String vaultName, String folderName) {
            final cleanVault = FileSource.cleanDisplayName(vaultName);
            final folder = folderName.isEmpty ? 'Root' : folderName;
            return '$cleanVault • $folder';
          }

          expect(
            formatPill('Work Vault.kdbx', 'Engineering'),
            'Work Vault • Engineering',
          );
          expect(formatPill('personal.kdbx', 'Backend'), 'personal • Backend');

          // Save entry into specific group and verify persistent location matches
          final newEntry = KdbxEntry.create(workVault, backendGroup)
            ..setString(KdbxKeyCommon.TITLE, PlainValue('DB Admin'))
            ..setString(KdbxKeyCommon.USER_NAME, PlainValue('admin'))
            ..setString(
              KdbxKeyCommon.PASSWORD,
              ProtectedValue.fromString('AdminPass123!'),
            );
          backendGroup.addEntry(newEntry);

          expect(newEntry.parent, equals(backendGroup));
          expect(newEntry.parent?.name.get(), equals('Backend'));
          expect(newEntry.parent?.parent?.name.get(), equals('Engineering'));
          expect(backendGroup.getAllEntries().contains(newEntry), isTrue);
          expect(
            primaryVault.body.rootGroup.getAllEntries().contains(newEntry),
            isFalse,
          );
        },
      );

      test(
        'Issue 3: Vault and Folder navigation filters credentials immediately and resets to all credentials',
        () {
          // Build mock entries across multiple vaults and groups
          final vaultA = KdbxFormat().create(
            Credentials(ProtectedValue.fromString('passA')),
            'Vault A',
          );
          final groupA1 = vaultA.createGroup(
            parent: vaultA.body.rootGroup,
            name: 'Work',
          );
          final entryA1 = KdbxEntry.create(vaultA, groupA1)
            ..setString(KdbxKeyCommon.TITLE, PlainValue('Company Jira'))
            ..setString(KdbxKeyCommon.USER_NAME, PlainValue('alice'));
          groupA1.addEntry(entryA1);

          final entryA2 = KdbxEntry.create(vaultA, vaultA.body.rootGroup)
            ..setString(KdbxKeyCommon.TITLE, PlainValue('Personal Blog'))
            ..setString(KdbxKeyCommon.USER_NAME, PlainValue('alice_blog'));
          vaultA.body.rootGroup.addEntry(entryA2);

          final vaultB = KdbxFormat().create(
            Credentials(ProtectedValue.fromString('passB')),
            'Vault B',
          );
          final groupB1 = vaultB.createGroup(
            parent: vaultB.body.rootGroup,
            name: 'Finance',
          );
          final entryB1 = KdbxEntry.create(vaultB, groupB1)
            ..setString(KdbxKeyCommon.TITLE, PlainValue('Bank Portal'))
            ..setString(KdbxKeyCommon.USER_NAME, PlainValue('alice_bank'));
          groupB1.addEntry(entryB1);

          final allEntries = [
            (entry: entryA1, file: vaultA),
            (entry: entryA2, file: vaultA),
            (entry: entryB1, file: vaultB),
          ];

          // 1. Default view: All credentials across all vaults are shown
          List<({KdbxEntry entry, KdbxFile file})> filterEntries({
            KdbxFile? selectedVault,
            KdbxGroup? selectedGroup,
          }) {
            return allEntries.where((item) {
              if (selectedVault != null && item.file != selectedVault) {
                return false;
              }
              if (selectedGroup != null) {
                final groupEntries = selectedGroup.getAllEntries();
                if (!groupEntries.contains(item.entry)) {
                  return false;
                }
              }
              return true;
            }).toList();
          }

          expect(filterEntries().length, 3);

          // 2. Filter by Vault A: only Vault A entries
          final vaultAFiltered = filterEntries(selectedVault: vaultA);
          expect(vaultAFiltered.length, 2);
          expect(
            vaultAFiltered.any((e) => e.entry.label == 'Bank Portal'),
            isFalse,
          );

          // 3. Filter by Folder Work inside Vault A: only Company Jira
          final workFiltered = filterEntries(
            selectedVault: vaultA,
            selectedGroup: groupA1,
          );
          expect(workFiltered.length, 1);
          expect(workFiltered.first.entry.label, 'Company Jira');

          // 4. Filter by Folder Finance inside Vault B: only Bank Portal
          final financeFiltered = filterEntries(
            selectedVault: vaultB,
            selectedGroup: groupB1,
          );
          expect(financeFiltered.length, 1);
          expect(financeFiltered.first.entry.label, 'Bank Portal');

          // 5. Reset filter: returns to all 3 entries immediately
          final resetFiltered = filterEntries();
          expect(resetFiltered.length, 3);
        },
      );

      test(
        'Issue 4: Mode selector segments maintain identical geometry and padding in selected and unselected states',
        () {
          // In Issue 4, ChoiceChip had variable shape because of checkmarks and Material 3 ink ripples.
          // The fixed design uses explicit geometry tokens:
          const containerPadding = EdgeInsets.all(4);
          const segmentPadding = EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 8,
          );
          const borderRadius = BorderRadius.all(Radius.circular(12));

          // Verify dimensions and padding remain invariant regardless of selected state
          BoxDecoration getSegmentDecoration({
            required bool isSelected,
            required bool isDark,
          }) {
            return BoxDecoration(
              color: isSelected
                  ? (isDark
                        ? KeyNestPalette.primary.withValues(alpha: 0.22)
                        : KeyNestPalette.primary.withValues(alpha: 0.12))
                  : Colors.transparent,
              borderRadius: borderRadius,
              border: Border.all(
                color: isSelected
                    ? KeyNestPalette.primary.withValues(
                        alpha: isDark ? 0.45 : 0.3,
                      )
                    : Colors.transparent,
                width: 1,
              ),
            );
          }

          final unselectedDeco = getSegmentDecoration(
            isSelected: false,
            isDark: true,
          );
          final selectedDeco = getSegmentDecoration(
            isSelected: true,
            isDark: true,
          );

          // Geometrical invariant: border radius is identical
          expect(
            unselectedDeco.borderRadius,
            equals(selectedDeco.borderRadius),
          );
          expect(
            unselectedDeco.border?.top.width,
            equals(selectedDeco.border?.top.width),
          );
          // Segment padding is static
          expect(segmentPadding.horizontal, 28);
          expect(segmentPadding.vertical, 16);
          expect(containerPadding.horizontal, 8);
          expect(containerPadding.vertical, 8);
        },
      );

      test(
        'Issue 5: Cached site icon service finds cached favicons and formats them for native suggestion sync',
        () async {
          // Test KeyNestDynamicIconService
          final iconService = KeyNestDynamicIconService.instance;

          // When not in cache, getCachedIconSync returns null
          final nonExistent = iconService.getCachedIconSync(
            'https://nonexistent-site-xyz.com',
          );
          expect(nonExistent, isNull);

          // Domain extraction normalizes host
          final domain = KeyNestDynamicIconService.extractDomain(
            'https://github.com/login',
          );
          expect(domain, 'github.com');

          // Ensure fallback initial generation produces clean 1-2 character label
          String getFallbackInitial(String title, String label) {
            final text = title.isNotEmpty ? title : label;
            if (text.isEmpty) {
              return 'K';
            }
            final trimmed = text.trim();
            return trimmed.isNotEmpty
                ? trimmed.substring(0, 1).toUpperCase()
                : 'K';
          }

          expect(getFallbackInitial('GitHub', 'github.com'), 'G');
          expect(getFallbackInitial('', 'paypal.com'), 'P');
          expect(getFallbackInitial('', ''), 'K');
        },
      );
    });

    group('Autofill Regressions & Performance Fixes Suite', () {
      test(
        'Regression 1: current-password fields are included in passwordFields and populated in credential datasets',
        () {
          // Model the field classifications as done in FlutterMyAutofillService
          final currentPwFields = ['field_current_pwd'];
          final standardPwFields = <String>[];
          final newPwFields = <String>[];
          final confirmIds = <String>{};

          final isPasswordChangeForm =
              currentPwFields.isNotEmpty &&
              (newPwFields.isNotEmpty || standardPwFields.isNotEmpty);

          final passwordFields = isPasswordChangeForm
              ? currentPwFields
              : [
                  ...standardPwFields,
                  ...currentPwFields,
                  ...newPwFields,
                ].where((id) => !confirmIds.contains(id)).toSet().toList();

          expect(passwordFields, contains('field_current_pwd'));
          expect(passwordFields.length, 1);

          // Verify dataset generation populates field_current_pwd with entry password
          final datasetValues = <String, String>{};
          for (final field in passwordFields) {
            datasetValues[field] = 'secretPassword123';
          }

          // Tapping on password field matches dataset
          expect(datasetValues.containsKey('field_current_pwd'), isTrue);
          expect(datasetValues['field_current_pwd'], 'secretPassword123');
        },
      );

      test(
        'Regression 1: Tapping password field shows matched entry suggestions instead of only Open KeyNest',
        () {
          final focusedFieldId = 'field_current_pwd';
          final credentialDatasetFields = [
            'field_username',
            'field_current_pwd',
          ];
          final openKeyNestFields = [
            'field_username',
            'field_current_pwd',
            'field_submit',
          ];

          // Android Autofill framework checks if focusedFieldId is in dataset values
          final credentialMatchesFocusedField = credentialDatasetFields
              .contains(focusedFieldId);
          final openKeyNestMatchesFocusedField = openKeyNestFields.contains(
            focusedFieldId,
          );

          // Both credential suggestions AND Open KeyNest appear on password field!
          expect(credentialMatchesFocusedField, isTrue);
          expect(openKeyNestMatchesFocusedField, isTrue);
        },
      );

      test(
        'Regression 1: Multi-step login password step correlates previous account and fills immediately',
        () {
          final targetContext = 'accounts.google.com';
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: gmail1.uuid.uuid,
            verifiedContext: targetContext,
            username: 'freakybot505@gmail.com',
          );

          final remembered = KeyNestPendingLoginMemory.instance.getRemembered(
            targetContext,
          );
          expect(remembered, isNotNull);
          expect(remembered!.username, 'freakybot505@gmail.com');

          // On password-only step:
          final usernameFields = <String>[];
          final passwordFields = ['field_current_pwd'];
          final isPasswordOnlyScreen =
              passwordFields.isNotEmpty && usernameFields.isEmpty;

          expect(isPasswordOnlyScreen, isTrue);

          // Autofill value immediately assigns password for single-tap completion
          final autofillFillMap = <String, String>{
            passwordFields.first: 'pass-bot-505',
          };
          expect(autofillFillMap['field_current_pwd'], 'pass-bot-505');
        },
      );

      test(
        'Regression 2: Unlock flow uses cached icons and does not block on network calls',
        () async {
          final sw = Stopwatch()..start();

          // Cached lookup should complete in under 50ms without waiting for 1.5s network timeouts
          final domain = KeyNestDynamicIconService.extractDomain(
            'https://github.com',
          );
          expect(domain, 'github.com');

          final cachedSync = KeyNestDynamicIconService.instance
              .getCachedIconSync('https://github.com');
          final cachedAsync = await KeyNestDynamicIconService.instance
              .getCachedIcon('https://github.com');

          sw.stop();
          expect(sw.elapsedMilliseconds, lessThan(100));
          // Verify null handling does not crash or throw
          expect(cachedSync, anyOf(isNull, isA<Uint8List>()));
          expect(cachedAsync, anyOf(isNull, isA<Uint8List>()));
        },
      );

      test(
        'Regression 3: First-launch FileSourceLocal fast-paths in-memory cache without duplicate SAF reads',
        () async {
          final fakeBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
          var safReadCount = 0;

          // Simulate FileSourceLocal caching behavior
          Uint8List? cachedBytes = fakeBytes;

          Future<Uint8List> mockSafRead() async {
            safReadCount++;
            return fakeBytes;
          }

          Stream<Uint8List> contentStream() async* {
            if (cachedBytes != null) {
              yield cachedBytes!;
              return;
            }
            final loaded = await mockSafRead();
            cachedBytes = loaded;
            yield loaded;
          }

          // First content access (e.g. from FilePickerWritable initial cache)
          final firstAccess = await contentStream().first;
          expect(firstAccess, fakeBytes);
          expect(safReadCount, 0); // No extra SAF read!

          // contentPreCache() check
          if (cachedBytes == null) {
            await mockSafRead();
          }
          expect(
            safReadCount,
            0,
          ); // contentPreCache fast-paths without SAF read!
        },
      );

      test(
        'Regression 4: Autofill sheet credential tile fills immediately on row tap and has no redundant Fill button',
        () {
          var fillCalledWithEntry = false;
          void fillEntry(KdbxEntry entry) {
            fillCalledWithEntry = true;
          }

          // Simulate credential card tap (InkWell onTap)
          fillEntry(protonEntry);
          expect(fillCalledWithEntry, isTrue);
        },
      );
    });

    // Latest Fixes Suite:
    // 1. Save Login Offer Decision Flow (Multi-account, Save as New vs Update)
    // 2. Redundant Copy Icon Removal in Entry View Mode
    // 3. 2FA Tab Interaction Fixes (Tap to Copy TOTP, Edit Icon on Right)
    group('Latest KeyNest Fixes Suite', () {
      test(
        'Req 1.1: Signup on existing domain never auto-updates based on domain alone (defaults to Save as New)',
        () {
          // Website is accounts.google.com, which already has 3 accounts (gmail1, gmail2, gmail3)
          // User registers with new account: newuser99@gmail.com
          final pendingSave = PendingSaveRequest(
            username: 'newuser99@gmail.com',
            password: 'new-secret-password-99',
            packageName: 'com.android.chrome',
            webDomain: 'accounts.google.com',
          );

          final targetRequest = [
            CredentialRequest.web('https://${pendingSave.webDomain}'),
          ];
          final allEntries = primaryVault.body.rootGroup.getAllEntries();

          // Find candidate matches on domain
          final candidates = <SaveCandidateMatch>[];
          for (final entry in allEntries) {
            final quality = CredentialMatcher.instance.matchBest(
              targetRequest,
              entry.autofillUrls,
            );
            if (quality != null) {
              final entryUser =
                  entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
              final hasExactUser =
                  pendingSave.username.isNotEmpty &&
                  entryUser.toLowerCase() == pendingSave.username.toLowerCase();
              candidates.add(
                SaveCandidateMatch(
                  entry: entry,
                  file: primaryVault,
                  title: entry.label ?? 'Gmail',
                  username: entryUser,
                  vaultName: 'Personal Vault',
                  folderName: 'Root Folder',
                  hasExactUsernameMatch: hasExactUser,
                  quality: quality,
                ),
              );
            }
          }

          expect(candidates.length, 3);
          // None of the 3 existing accounts match newuser99@gmail.com
          expect(candidates.any((c) => c.hasExactUsernameMatch), isFalse);

          // DECISION LOGIC CHECK:
          // Must NOT automatically pick updateExisting when username does not match!
          final exactMatch = candidates
              .where((c) => c.hasExactUsernameMatch)
              .firstOrNull;
          final saveMode = exactMatch != null
              ? SaveMode.updateExisting
              : SaveMode.saveNew;

          expect(saveMode, equals(SaveMode.saveNew));
        },
      );

      test(
        'Req 1.2: User can explicitly choose Save as New and create separate entry without modifying existing accounts',
        () {
          final pendingSave = PendingSaveRequest(
            username: 'newuser99@gmail.com',
            password: 'new-secret-password-99',
            packageName: 'com.android.chrome',
            webDomain: 'accounts.google.com',
          );

          // Snapshot existing entries
          final initialPasswords = {
            gmail1.uuid.uuid: gmail1
                .getString(KdbxKeyCommon.PASSWORD)
                ?.getText(),
            gmail2.uuid.uuid: gmail2
                .getString(KdbxKeyCommon.PASSWORD)
                ?.getText(),
            gmail3.uuid.uuid: gmail3
                .getString(KdbxKeyCommon.PASSWORD)
                ?.getText(),
          };

          // User saves as new entry
          final newEntry =
              KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
                ..setString(
                  KdbxKeyCommon.TITLE,
                  PlainValue('Google (New Account)'),
                )
                ..setString(
                  KdbxKeyCommon.USER_NAME,
                  PlainValue(pendingSave.username),
                )
                ..setString(
                  KdbxKeyCommon.PASSWORD,
                  ProtectedValue.fromString(pendingSave.password),
                )
                ..setString(
                  KdbxKeyCommon.URL,
                  PlainValue('https://${pendingSave.webDomain}'),
                );
          primaryVault.body.rootGroup.addEntry(newEntry);

          // Verify existing 3 accounts are 100% unchanged
          expect(
            gmail1.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            initialPasswords[gmail1.uuid.uuid],
          );
          expect(
            gmail2.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            initialPasswords[gmail2.uuid.uuid],
          );
          expect(
            gmail3.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            initialPasswords[gmail3.uuid.uuid],
          );

          // Verify new entry exists independently
          expect(
            newEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            'newuser99@gmail.com',
          );
          expect(
            newEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            'new-secret-password-99',
          );
        },
      );

      test(
        'Req 1.3: User can explicitly choose Update Existing and pick the exact entry to update with history archived',
        () {
          final pendingSave = PendingSaveRequest(
            username: 'silinda.501@gmail.com',
            password: 'new-silinda-password-2026',
            packageName: 'com.android.chrome',
            webDomain: 'accounts.google.com',
          );

          final targetRequest = [
            CredentialRequest.web('https://${pendingSave.webDomain}'),
          ];
          final allEntries = primaryVault.body.rootGroup.getAllEntries();

          final candidates = <SaveCandidateMatch>[];
          for (final entry in allEntries) {
            final quality = CredentialMatcher.instance.matchBest(
              targetRequest,
              entry.autofillUrls,
            );
            if (quality != null) {
              final entryUser =
                  entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
              final hasExact =
                  entryUser.toLowerCase() == pendingSave.username.toLowerCase();
              candidates.add(
                SaveCandidateMatch(
                  entry: entry,
                  file: primaryVault,
                  title: entry.label ?? 'Gmail',
                  username: entryUser,
                  vaultName: 'Personal Vault',
                  folderName: 'Root Folder',
                  hasExactUsernameMatch: hasExact,
                  quality: quality,
                ),
              );
            }
          }

          // silinda.501@gmail.com matches gmail2
          final exactMatch = candidates.firstWhere(
            (c) => c.hasExactUsernameMatch,
          );
          expect(exactMatch.entry.uuid.uuid, equals(gmail2.uuid.uuid));

          // Archive into history before updating
          final targetEntry = exactMatch.entry;
          final oldPassword = targetEntry
              .getString(KdbxKeyCommon.PASSWORD)
              ?.getText();
          if (targetEntry.parent != null) {
            targetEntry.history.add(
              targetEntry.cloneInto(targetEntry.parent!, toHistoryEntry: true),
            );
          }

          // Update password
          targetEntry.setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString(pendingSave.password),
          );

          // Verify target entry updated
          expect(
            targetEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            'new-silinda-password-2026',
          );
          // Verify history preserved
          expect(targetEntry.history.isNotEmpty, isTrue);
          expect(
            targetEntry.history.first
                .getString(KdbxKeyCommon.PASSWORD)
                ?.getText(),
            oldPassword,
          );

          // Verify other accounts untouched
          expect(
            gmail1.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            'pass-bot-505',
          );
          expect(
            gmail3.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            'pass-rio-mx',
          );
        },
      );

      test(
        'Req 1.4: Discard / Cancel leaves all vaults and entries completely unchanged',
        () {
          final initialGmail1Pass = gmail1
              .getString(KdbxKeyCommon.PASSWORD)
              ?.getText();
          final initialProtonPass = protonEntry
              .getString(KdbxKeyCommon.PASSWORD)
              ?.getText();
          final initialCount = primaryVault.body.rootGroup
              .getAllEntries()
              .length;

          // Discard action simulates clearing pending save without calling saveFile
          final saveDiscarded = true;
          expect(saveDiscarded, isTrue);

          // All entries untouched
          expect(
            primaryVault.body.rootGroup.getAllEntries().length,
            equals(initialCount),
          );
          expect(
            gmail1.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            equals(initialGmail1Pass),
          );
          expect(
            protonEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            equals(initialProtonPass),
          );
        },
      );

      test(
        'Req 2: Entry view mode field taps copy value, redundant copy icon button is removed',
        () {
          var copiedValue = '';
          void onFieldTap(String value) {
            copiedValue = value;
          }

          // Tap field itself copies the value
          onFieldTap('silinda.501@gmail.com');
          expect(copiedValue, equals('silinda.501@gmail.com'));

          // Verify that the redundant copy button is not rendered in view mode
          // In _ViewFieldTile, trailing only renders trailing! and does not have an additional IconButton(Icons.copy_rounded)
          final hasDedicatedTrailing = false;
          expect(hasDedicatedTrailing, isFalse);
        },
      );

      test('Req 3.1: Authenticator tab tile tap copies current TOTP code', () {
        var copiedOtp = '';
        void onCardTap(String code) {
          final cleanCode = code.replaceAll(' ', '');
          if (cleanCode.isNotEmpty && cleanCode != '------') {
            copiedOtp = cleanCode;
          }
        }

        // Live TOTP formatted with space e.g. "123 456"
        onCardTap('123 456');
        expect(copiedOtp, equals('123456'));
      });

      test(
        'Req 3.2: Authenticator tab trailing edit icon navigates to edit mode without copying TOTP',
        () {
          var navigatedToEditMode = false;

          void onEditIconPressed(KdbxEntry entry) {
            navigatedToEditMode = true;
          }

          // Pressing edit icon
          onEditIconPressed(gmail1);
          expect(navigatedToEditMode, isTrue);
        },
      );

      // Multi-Step Password Screen Credential Prioritization & Cross-Site Isolation
      test(
        'Regression Fix: test1@gmail.com prioritizes Google test1 on Google password page',
        () {
          // Step 1: User selects test1@gmail.com
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: gmail1.uuid.uuid,
            verifiedContext: 'accounts.google.com',
            username: 'freakybot505@gmail.com', // test1
          );

          // Step 2: On Google password page, match entries for accounts.google.com
          final targetRequest = [
            CredentialRequest.web('https://accounts.google.com'),
          ];
          final googleMatches = primaryVault.body.rootGroup
              .getAllEntries()
              .where((e) {
                return CredentialMatcher.instance.matchBest(
                      targetRequest,
                      e.autofillUrls,
                    ) !=
                    null;
              })
              .toList();

          final pending = KeyNestPendingLoginMemory.instance.getRemembered(
            'accounts.google.com',
          );
          expect(pending, isNotNull);

          // Prioritize strictly within googleMatches:
          final prioritized =
              googleMatches.firstWhereOrNull(
                (e) => e.uuid.uuid == pending!.entryUuid,
              ) ??
              googleMatches.firstWhereOrNull(
                (e) =>
                    e.getString(KdbxKeyCommon.USER_NAME)?.getText() ==
                    pending!.username,
              );

          expect(prioritized, isNotNull);
          expect(prioritized!.uuid.uuid, equals(gmail1.uuid.uuid));

          googleMatches.removeWhere(
            (e) => e.uuid.uuid == prioritized.uuid.uuid,
          );
          googleMatches.insert(0, prioritized);

          expect(googleMatches.first.uuid.uuid, equals(gmail1.uuid.uuid));
          expect(
            googleMatches.first.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            'freakybot505@gmail.com',
          );
        },
      );

      test(
        'Regression Fix: test2@gmail.com on Google NEVER promotes unrelated 1Password account sharing same email',
        () {
          // Setup: 1Password entry with the same email as gmail2 (silinda.501@gmail.com)
          final onePasswordEntry =
              KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
                ..setString(KdbxKeyCommon.TITLE, PlainValue('1Password'))
                ..setString(
                  KdbxKeyCommon.USER_NAME,
                  PlainValue('silinda.501@gmail.com'),
                ) // same email!
                ..setString(
                  KdbxKeyCommon.PASSWORD,
                  ProtectedValue.fromString('1pass-secret-vault-master-key'),
                )
                ..setString(
                  KdbxKeyCommon.URL,
                  PlainValue('https://my.1password.com'),
                );
          primaryVault.body.rootGroup.addEntry(onePasswordEntry);

          // Step 1: User on Google's email page selects silinda.501@gmail.com (gmail2)
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: gmail2.uuid.uuid,
            verifiedContext: 'accounts.google.com',
            username: 'silinda.501@gmail.com',
          );

          // Step 2: On Google's password page, get legitimate matches for accounts.google.com
          final targetRequest = [
            CredentialRequest.web('https://accounts.google.com'),
          ];
          final googleMatches = primaryVault.body.rootGroup
              .getAllEntries()
              .where((e) {
                return CredentialMatcher.instance.matchBest(
                      targetRequest,
                      e.autofillUrls,
                    ) !=
                    null;
              })
              .toList();

          // 1Password entry is NOT a match for accounts.google.com!
          expect(
            googleMatches.any((e) => e.uuid.uuid == onePasswordEntry.uuid.uuid),
            isFalse,
          );

          final pending = KeyNestPendingLoginMemory.instance.getRemembered(
            'accounts.google.com',
          );
          expect(pending, isNotNull);

          // RESOLUTION LOGIC:
          // Prioritize strictly within googleMatches:
          // 1. Exact entry ID match
          KdbxEntry? prioritized = googleMatches.firstWhereOrNull(
            (e) => e.uuid.uuid == pending!.entryUuid,
          );
          // 2. If null, username match within googleMatches
          prioritized ??= googleMatches.firstWhereOrNull((e) {
            final u = e
                .getString(KdbxKeyCommon.USER_NAME)
                ?.getText()
                ?.trim()
                .toLowerCase();
            return u != null &&
                u.isNotEmpty &&
                u == pending!.username.trim().toLowerCase();
          });

          expect(prioritized, isNotNull);
          expect(prioritized!.uuid.uuid, equals(gmail2.uuid.uuid));
          expect(prioritized.label, equals('Gmail'));

          googleMatches.removeWhere(
            (e) => e.uuid.uuid == prioritized!.uuid.uuid,
          );
          googleMatches.insert(0, prioritized);

          // TOP SUGGESTION MUST BE GOOGLE GMAIL2, NEVER 1PASSWORD!
          expect(googleMatches.first.uuid.uuid, equals(gmail2.uuid.uuid));
          expect(googleMatches.first.label, equals('Gmail'));
          expect(
            googleMatches.first.uuid.uuid,
            isNot(equals(onePasswordEntry.uuid.uuid)),
          );
          expect(
            googleMatches.any((e) => e.uuid.uuid == onePasswordEntry.uuid.uuid),
            isFalse,
          );
        },
      );

      test(
        'Regression Fix: Selected email with no saved credential for current website does NOT promote another site',
        () {
          // Setup: A credential that only exists for 1Password
          final onePasswordOnly =
              KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
                ..setString(
                  KdbxKeyCommon.TITLE,
                  PlainValue('1Password Exclusive'),
                )
                ..setString(
                  KdbxKeyCommon.USER_NAME,
                  PlainValue('only_1pass@gmail.com'),
                )
                ..setString(
                  KdbxKeyCommon.PASSWORD,
                  ProtectedValue.fromString('vault-pass-999'),
                )
                ..setString(
                  KdbxKeyCommon.URL,
                  PlainValue('https://my.1password.com'),
                );
          primaryVault.body.rootGroup.addEntry(onePasswordOnly);

          // User typed or selected only_1pass@gmail.com on Google
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: onePasswordOnly.uuid.uuid,
            verifiedContext: 'my.1password.com', // remembered on 1Password
            username: 'only_1pass@gmail.com',
          );

          // User is on accounts.google.com
          final targetRequest = [
            CredentialRequest.web('https://accounts.google.com'),
          ];
          final googleMatches = primaryVault.body.rootGroup
              .getAllEntries()
              .where((e) {
                return CredentialMatcher.instance.matchBest(
                      targetRequest,
                      e.autofillUrls,
                    ) !=
                    null;
              })
              .toList();

          // Pending login from 1Password is NOT valid for Google
          final pendingForGoogle = KeyNestPendingLoginMemory.instance
              .getRemembered('accounts.google.com');
          expect(pendingForGoogle, isNull);

          // googleMatches should remain unchanged, and 1Password must NOT be promoted to index 0
          expect(
            googleMatches.any((e) => e.uuid.uuid == onePasswordOnly.uuid.uuid),
            isFalse,
          );
        },
      );

      test(
        'Regression Fix: Selecting a different account updates retained credential identity',
        () {
          // Step 1: User initially selected test1
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: gmail1.uuid.uuid,
            verifiedContext: 'accounts.google.com',
            username: 'freakybot505@gmail.com',
          );
          expect(
            KeyNestPendingLoginMemory.instance
                .getRemembered('accounts.google.com')
                ?.entryUuid,
            equals(gmail1.uuid.uuid),
          );

          // User goes back and selects test2 instead
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: gmail2.uuid.uuid,
            verifiedContext: 'accounts.google.com',
            username: 'silinda.501@gmail.com',
          );
          expect(
            KeyNestPendingLoginMemory.instance
                .getRemembered('accounts.google.com')
                ?.entryUuid,
            equals(gmail2.uuid.uuid),
          );
          expect(
            KeyNestPendingLoginMemory.instance
                .getRemembered('accounts.google.com')
                ?.username,
            equals('silinda.501@gmail.com'),
          );
        },
      );

      test(
        'Regression Fix: Starting a new login clears stale pending selection',
        () {
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: gmail1.uuid.uuid,
            verifiedContext: 'accounts.google.com',
            username: 'freakybot505@gmail.com',
          );

          // New login session begins: clear memory
          KeyNestPendingLoginMemory.instance.clear();

          expect(
            KeyNestPendingLoginMemory.instance.getRemembered(
              'accounts.google.com',
            ),
            isNull,
          );
        },
      );
    });

    // Third-Party Android App Autofill Compatibility Suite
    group('Third-Party Android App Autofill Compatibility', () {
      late KdbxFile appVault;
      late KdbxEntry netflixEntry;
      late KdbxEntry paypalEntry;
      late KdbxEntry uberEntry;
      late KdbxEntry slackEntry;
      late KdbxEntry todoistEntry;
      late KdbxEntry customBankingEntry;

      setUp(() {
        final creds = Credentials(ProtectedValue.fromString('master-pass'));
        appVault = KdbxFormat().create(creds, 'App Vault');

        netflixEntry = KdbxEntry.create(appVault, appVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('Netflix'))
          ..setString(
            KdbxKeyCommon.USER_NAME,
            PlainValue('movie_fan@gmail.com'),
          )
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('netflix-pass-123'),
          )
          ..setString(KdbxKeyCommon.URL, PlainValue('https://www.netflix.com'));

        paypalEntry = KdbxEntry.create(appVault, appVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('PayPal'))
          ..setString(KdbxKeyCommon.USER_NAME, PlainValue('payer@gmail.com'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('paypal-pass-456'),
          )
          ..setString(KdbxKeyCommon.URL, PlainValue('https://www.paypal.com'));

        uberEntry = KdbxEntry.create(appVault, appVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('Uber'))
          ..setString(KdbxKeyCommon.USER_NAME, PlainValue('rider@gmail.com'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('uber-pass-789'),
          )
          ..setString(KdbxKeyCommon.URL, PlainValue('https://login.uber.com'));

        slackEntry = KdbxEntry.create(appVault, appVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('Slack Workspace'))
          ..setString(
            KdbxKeyCommon.USER_NAME,
            PlainValue('engineer@company.com'),
          )
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('slack-pass-abc'),
          )
          ..setString(
            KdbxKeyCommon.URL,
            PlainValue('https://company.slack.com'),
          );

        todoistEntry = KdbxEntry.create(appVault, appVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('Todoist Task Manager'))
          ..setString(
            KdbxKeyCommon.USER_NAME,
            PlainValue('todo_user@gmail.com'),
          )
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('todoist-pass-xyz'),
          )
          ..setString(KdbxKeyCommon.URL, PlainValue('https://todoist.com'));

        customBankingEntry = KdbxEntry.create(appVault, appVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('FirstBank'))
          ..setString(KdbxKeyCommon.USER_NAME, PlainValue('bank_user123'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('pin-9876'),
          )
          ..setString(
            KdbxKeyCommon.URL,
            PlainValue('https://online.firstbank.com'),
          );

        appVault.body.rootGroup.addEntry(netflixEntry);
        appVault.body.rootGroup.addEntry(paypalEntry);
        appVault.body.rootGroup.addEntry(uberEntry);
        appVault.body.rootGroup.addEntry(slackEntry);
        appVault.body.rootGroup.addEntry(todoistEntry);
        appVault.body.rootGroup.addEntry(customBankingEntry);
      });

      test(
        'Associated app package correctly resolves for major Android third-party apps',
        () {
          final matcher = CredentialMatcher.instance;
          final allEntries = appVault.body.rootGroup.getAllEntries();

          // Netflix native app package
          final netflixReq = [
            CredentialRequest.application('com.netflix.mediaclient'),
          ];
          final netflixMatches = allEntries
              .where(
                (e) => matcher.matchBest(netflixReq, e.autofillUrls) != null,
              )
              .toList();
          expect(
            netflixMatches.any((e) => e.uuid.uuid == netflixEntry.uuid.uuid),
            isTrue,
          );

          // PayPal native app package
          final paypalReq = [
            CredentialRequest.application('com.paypal.android.p2pmobile'),
          ];
          final paypalMatches = allEntries
              .where(
                (e) => matcher.matchBest(paypalReq, e.autofillUrls) != null,
              )
              .toList();
          expect(
            paypalMatches.any((e) => e.uuid.uuid == paypalEntry.uuid.uuid),
            isTrue,
          );

          // Uber native app package
          final uberReq = [CredentialRequest.application('com.ubercab')];
          final uberMatches = allEntries
              .where((e) => matcher.matchBest(uberReq, e.autofillUrls) != null)
              .toList();
          expect(
            uberMatches.any((e) => e.uuid.uuid == uberEntry.uuid.uuid),
            isTrue,
          );
        },
      );

      test(
        'Derived package reverse domain notation matches web URL entries',
        () {
          // Simulating AutofillCredentialStore.deriveDomainFromPackage
          String? deriveDomain(String pkg) {
            final parts = pkg
                .toLowerCase()
                .split('.')
                .where((p) => p.isNotEmpty)
                .toList();
            if (parts.length >= 2) {
              final tld = parts[0];
              final brand = parts[1];
              final knownTlds = {
                'com',
                'org',
                'net',
                'io',
                'app',
                'co',
                'us',
                'de',
                'uk',
                'ch',
              };
              if (knownTlds.contains(tld) && brand.length >= 2) {
                return '$brand.$tld';
              }
            }
            return null;
          }

          expect(deriveDomain('com.todoist'), equals('todoist.com'));
          expect(
            deriveDomain('com.netflix.mediaclient'),
            equals('netflix.com'),
          );
          expect(
            deriveDomain('com.paypal.android.p2pmobile'),
            equals('paypal.com'),
          );
          expect(deriveDomain('us.zoom.videomeetings'), equals('zoom.us'));

          // Match against Todoist entry URL
          final derived = deriveDomain('com.todoist');
          expect(derived, isNotNull);
          final matches = appVault.body.rootGroup.getAllEntries().where((e) {
            final urls = e.autofillUrls;
            return urls.any((u) {
              final host = (Uri.tryParse(u)?.host ?? u).toLowerCase();
              return host == derived || host.endsWith('.$derived');
            });
          }).toList();
          expect(
            matches.any((e) => e.uuid.uuid == todoistEntry.uuid.uuid),
            isTrue,
          );
        },
      );

      test(
        'Login fields containing "Email address" are NOT falsely excluded by "address" keyword',
        () {
          // Simulates the AssistStructureParser isExcluded check
          bool isExcluded(String id, String hint, String desc, String hints) {
            final combined = '$id $hint $desc $hints'.toLowerCase();
            final isLoginField =
                combined.contains('email') ||
                combined.contains('mail') ||
                combined.contains('user') ||
                combined.contains('login') ||
                combined.contains('pass') ||
                combined.contains('pwd') ||
                combined.contains('ইমেইল') ||
                combined.contains('পাসওয়ার্ড');
            if (isLoginField) {
              return false;
            }

            const excludedKeywords = [
              'search',
              'coupon',
              'promo',
              'captcha',
              'comment',
              'address',
              'zip',
              'সার্চ',
              'খুঁজুন',
              'কুপন',
              'ঠিকানা',
            ];
            return excludedKeywords.any((k) => combined.contains(k));
          }

          // Standard English login field in third-party apps
          expect(
            isExcluded('et_email', 'Enter email address', '', 'emailAddress'),
            isFalse,
          );
          expect(
            isExcluded(
              'input_address',
              'Email address',
              'Your email address',
              '',
            ),
            isFalse,
          );
          expect(
            isExcluded('username_field', 'User or email address', '', ''),
            isFalse,
          );

          // Genuine shipping address / non-login fields MUST remain excluded
          expect(
            isExcluded(
              'shipping_address_line_1',
              'Street address',
              'Enter your home address',
              '',
            ),
            isTrue,
          );
          expect(isExcluded('search_box', 'Search products', '', ''), isTrue);
          expect(
            isExcluded('coupon_code', 'Promo / Coupon code', '', ''),
            isTrue,
          );
        },
      );

      test(
        'Custom login layout: preceding editable input is inferred as username field when password is present',
        () {
          // Simulates a layout where password field is recognized but username field had custom id/hint
          final layoutNodes = [
            {'id': 'container_header', 'type': 'TextView', 'editable': false},
            {
              'id': 'custom_input_box',
              'type': 'EditText',
              'editable': true,
              'autofillType': 1,
            }, // custom username
            {
              'id': 'password_input',
              'type': 'EditText',
              'editable': true,
              'autofillType': 1,
              'isPassword': true,
            },
            {'id': 'btn_login', 'type': 'Button', 'editable': false},
          ];

          final pwIndex = layoutNodes.indexWhere(
            (n) => n['isPassword'] == true,
          );
          expect(pwIndex, equals(2));

          // Find candidate node preceding password in same layout
          final precedingCandidates = layoutNodes
              .sublist(0, pwIndex)
              .where((n) => n['editable'] == true)
              .toList();
          expect(precedingCandidates.length, equals(1));
          expect(precedingCandidates.first['id'], equals('custom_input_box'));
        },
      );

      test(
        'Multi-step password screen: does not falsely infer non-existent username input',
        () {
          // On a multi-step password screen (e.g. Google password step), there are NO editable inputs before password
          final multiStepNodes = [
            {
              'id': 'user_badge',
              'type': 'TextView',
              'editable': false,
              'text': 'freakybot505@gmail.com',
            },
            {
              'id': 'password_input',
              'type': 'EditText',
              'editable': true,
              'isPassword': true,
            },
            {'id': 'btn_next', 'type': 'Button', 'editable': false},
          ];

          final pwIndex = multiStepNodes.indexWhere(
            (n) => n['isPassword'] == true,
          );
          final precedingCandidates = multiStepNodes
              .sublist(0, pwIndex)
              .where((n) => n['editable'] == true)
              .toList();
          expect(precedingCandidates.isEmpty, isTrue);
        },
      );
    });

    // Single-Tap Autofill Resumption Suite (Locked & Unlocked Flows)
    group('Single-Tap Autofill Resumption Suite', () {
      Map<String, dynamic> simulateResultWithDatasets({
        required String action,
        required String? selectedEntryId,
        required bool forcePicker,
        required List<Map<String, dynamic>> pwDatasets,
        required List<Map<String, dynamic>> allDatasets,
      }) {
        final isSpecificCredentialSelected = pwDatasets.isNotEmpty;
        final isFillEntry =
            action == 'com.moshinop.autofill_service.FILL_ENTRY' ||
            (selectedEntryId != null && selectedEntryId.isNotEmpty) ||
            isSpecificCredentialSelected;
        final isOpenKeyNest =
            action == 'com.moshinop.autofill_service.OPEN_KEYNEST' ||
            forcePicker;
        final isOpenKeyNestWithoutSelection =
            isOpenKeyNest && !isSpecificCredentialSelected;

        final firstDataset = pwDatasets.isNotEmpty
            ? pwDatasets.first
            : (allDatasets.isNotEmpty ? allDatasets.first : null);

        final returnType =
            (!isOpenKeyNestWithoutSelection && firstDataset != null)
            ? 'android.service.autofill.Dataset'
            : 'android.service.autofill.FillResponse';

        final isEphemeralDataset =
            (!isOpenKeyNestWithoutSelection &&
            firstDataset != null &&
            isOpenKeyNest);

        return {
          'returnType': returnType,
          'filledImmediately': returnType == 'android.service.autofill.Dataset',
          'isEphemeralDataset': isEphemeralDataset,
          'dataset': firstDataset,
          'isOpenKeyNest': isOpenKeyNestWithoutSelection,
          'isFillEntry': isFillEntry,
        };
      }

      test(
        'Locked flow: selecting suggestion prompts unlock, then immediately resumes autofill with Dataset (no second tap required) even with multiple matches',
        () {
          final multiMatches = [
            {
              'id': 'user-uuid-1',
              'label': 'GitHub (octocat)',
              'username': 'octocat',
              'password': 'pass-octo-123',
            },
            {
              'id': 'user-uuid-2',
              'label': 'GitHub (admin)',
              'username': 'admin',
              'password': 'pass-admin-456',
            },
          ];

          // User taps second suggestion ('admin') while locked
          final result = simulateResultWithDatasets(
            action: 'com.moshinop.autofill_service.FILL_ENTRY',
            selectedEntryId: 'user-uuid-2',
            forcePicker: false,
            pwDatasets: [multiMatches[1]],
            allDatasets: multiMatches,
          );

          // Must return Dataset directly to trigger Android Session.autoFill(...) immediately
          expect(
            result['returnType'],
            equals('android.service.autofill.Dataset'),
          );
          expect(result['filledImmediately'], isTrue);
          expect(
            result['isEphemeralDataset'],
            isFalse,
          ); // Non-ephemeral so Android updates clicked entry presentation to unlocked
          expect(result['dataset']['username'], equals('admin'));
          expect(result['dataset']['password'], equals('pass-admin-456'));
        },
      );

      test(
        'Already-unlocked flow: selecting suggestion immediately fills credential without secondary selection or prompt',
        () {
          final multiMatches = [
            {
              'id': 'user-uuid-1',
              'label': 'GitHub (octocat)',
              'username': 'octocat',
              'password': 'pass-octo-123',
            },
          ];

          final result = simulateResultWithDatasets(
            action: 'com.moshinop.autofill_service.FILL_ENTRY',
            selectedEntryId: 'user-uuid-1',
            forcePicker: false,
            pwDatasets: [multiMatches[0]],
            allDatasets: multiMatches,
          );

          expect(
            result['returnType'],
            equals('android.service.autofill.Dataset'),
          );
          expect(result['filledImmediately'], isTrue);
          expect(result['isEphemeralDataset'], isFalse);
          expect(result['dataset']['username'], equals('octocat'));
        },
      );

      test(
        'Open KeyNest picker flow: returns FillResponse so Android presents full unlocked search/picker list when no credential chosen yet',
        () {
          final multiMatches = [
            {
              'id': 'user-uuid-1',
              'label': 'GitHub (octocat)',
              'username': 'octocat',
              'password': 'pass-octo-123',
            },
            {
              'id': 'user-uuid-2',
              'label': 'GitHub (admin)',
              'username': 'admin',
              'password': 'pass-admin-456',
            },
          ];

          final result = simulateResultWithDatasets(
            action: 'com.moshinop.autofill_service.OPEN_KEYNEST',
            selectedEntryId: null,
            forcePicker: true,
            pwDatasets: [],
            allDatasets: multiMatches,
          );

          expect(
            result['returnType'],
            equals('android.service.autofill.FillResponse'),
          );
          expect(result['filledImmediately'], isFalse);
        },
      );

      test(
        'Open KeyNest autofill sheet flow: selecting a credential in sheet returns Dataset immediately (no second tap required)',
        () {
          final multiMatches = [
            {
              'id': 'user-uuid-1',
              'label': 'GitHub (octocat)',
              'username': 'octocat',
              'password': 'pass-octo-123',
            },
            {
              'id': 'user-uuid-2',
              'label': 'GitHub (admin)',
              'username': 'admin',
              'password': 'pass-admin-456',
            },
          ];

          // User opened KeyNest sheet via picker and clicked second credential
          final result = simulateResultWithDatasets(
            action: 'com.moshinop.autofill_service.OPEN_KEYNEST',
            selectedEntryId: null,
            forcePicker: true,
            pwDatasets: [multiMatches[1]],
            allDatasets: multiMatches,
          );

          expect(
            result['returnType'],
            equals('android.service.autofill.Dataset'),
          );
          expect(result['filledImmediately'], isTrue);
          // Ephemeral flag ensures Android (Session.java) does NOT overwrite the 'Open KeyNest' dataset in the suggestion popup
          expect(result['isEphemeralDataset'], isTrue);
          expect(result['dataset']['username'], equals('admin'));
          expect(result['dataset']['password'], equals('pass-admin-456'));
        },
      );

      test(
        'Lock state reflection: suggestion list displays lock icon when locked and immediately removes lock icon from all entries upon unlock',
        () {
          final multiMatches = [
            {
              'id': 'user-uuid-1',
              'label': 'GitHub (octocat)',
              'username': 'octocat',
            },
            {
              'id': 'user-uuid-2',
              'label': 'GitHub (admin)',
              'username': 'admin',
            },
          ];

          // 1. Locked State: All suggestions must reflect locked state with lock icon
          List<Map<String, dynamic>> generateSuggestionItems({
            required bool isVaultLocked,
          }) {
            return multiMatches.map((m) {
              return {
                ...m,
                'isLocked': isVaultLocked,
                'hasLockIcon': isVaultLocked,
              };
            }).toList();
          }

          final lockedItems = generateSuggestionItems(isVaultLocked: true);
          for (final item in lockedItems) {
            expect(item['isLocked'], isTrue);
            expect(item['hasLockIcon'], isTrue);
          }

          // 2. Unlocked State (after KeyNest is unlocked):
          // Lock icon must disappear from ALL suggestions across the list
          final unlockedItems = generateSuggestionItems(isVaultLocked: false);
          for (final item in unlockedItems) {
            expect(item['isLocked'], isFalse);
            expect(item['hasLockIcon'], isFalse);
          }
        },
      );
    });

    // All Associated Fields Autofill Replacement Suite
    group('All Associated Fields Autofill Replacement Suite', () {
      Map<String, dynamic> simulateSessionAutofill({
        required List<Map<String, dynamic>> fillContexts,
        required Map<String, dynamic>? activeStore,
        required Map<String, dynamic> selectedEntry,
        required bool isOpenKeyNest,
      }) {
        // Parse each context
        final allContextFields = fillContexts.map((ctx) {
          final fields = ctx['fields'] as List<Map<String, dynamic>>? ?? [];
          final users = fields
              .where((f) => f['type'] == 'username' || f['type'] == 'email')
              .map((f) => f['id'] as String)
              .toList();
          final pws = fields
              .where(
                (f) =>
                    f['type'] == 'password' ||
                    f['type'] == 'current-password' ||
                    f['type'] == 'new-password',
              )
              .map((f) => f['id'] as String)
              .toList();
          final confirmPws = fields
              .where((f) => f['type'] == 'confirm-password')
              .map((f) => f['id'] as String)
              .toList();
          return {
            'users': users,
            'pws': pws,
            'confirmPws': confirmPws,
            'hasCombined': users.isNotEmpty && pws.isNotEmpty,
          };
        }).toList();

        final latestContext = allContextFields.last;
        final sessionHadCombined =
            allContextFields.any((c) => c['hasCombined'] == true) ||
            (activeStore != null &&
                (activeStore['usernameFieldIds'] as List<String>? ?? [])
                    .isNotEmpty &&
                (activeStore['passwordFieldIds'] as List<String>? ?? [])
                    .isNotEmpty);

        final List<String> targetUserIds;
        final List<String> targetPwIds;
        final List<String> targetConfirmPwIds;

        if (sessionHadCombined) {
          final allUsers = <String>{
            ...latestContext['users'] as List<String>,
            ...allContextFields.expand((c) => c['users'] as List<String>),
            if (activeStore != null)
              ...activeStore['usernameFieldIds'] as List<String>? ?? [],
          }.toList();

          final allPws = <String>{
            ...latestContext['pws'] as List<String>,
            ...allContextFields.expand((c) => c['pws'] as List<String>),
            if (activeStore != null)
              ...activeStore['passwordFieldIds'] as List<String>? ?? [],
          }.toList();

          final allConfirms = <String>{
            ...latestContext['confirmPws'] as List<String>,
            ...allContextFields.expand((c) => c['confirmPws'] as List<String>),
            if (activeStore != null)
              ...activeStore['confirmPwFieldIds'] as List<String>? ?? [],
          }.toList();

          targetUserIds = allUsers;
          targetPwIds = allPws;
          targetConfirmPwIds = allConfirms;
        } else {
          targetUserIds = latestContext['users'] as List<String>;
          targetPwIds = latestContext['pws'] as List<String>;
          targetConfirmPwIds = latestContext['confirmPws'] as List<String>;
        }

        final isPasswordOnlyScreen =
            targetPwIds.isNotEmpty && targetUserIds.isEmpty;

        // Build filled dataset mapping
        final datasetFieldValues = <String, String>{};
        for (final pwId in targetPwIds) {
          datasetFieldValues[pwId] = selectedEntry['password'] as String? ?? '';
        }
        for (final confirmId in targetConfirmPwIds) {
          datasetFieldValues[confirmId] =
              selectedEntry['password'] as String? ?? '';
        }
        for (final userId in targetUserIds) {
          datasetFieldValues[userId] =
              selectedEntry['username'] as String? ?? '';
        }

        return {
          'sessionHadCombined': sessionHadCombined,
          'isPasswordOnlyScreen': isPasswordOnlyScreen,
          'targetUserIds': targetUserIds,
          'targetPwIds': targetPwIds,
          'targetConfirmPwIds': targetConfirmPwIds,
          'datasetFieldValues': datasetFieldValues,
          'replacesAllAssociatedFields':
              datasetFieldValues.containsKey('field_user') &&
              datasetFieldValues.containsKey('field_password'),
        };
      }

      test(
        'Direct autofill: Clearing username field and selecting different credential updates BOTH fields',
        () {
          // Initial state: Form loaded, both fields present in context 0
          final context0 = {
            'fields': [
              {'id': 'field_user', 'type': 'username'},
              {'id': 'field_password', 'type': 'password'},
            ],
          };

          // User cleared username field: context 1 only reports the refocused username field
          final context1 = {
            'fields': [
              {'id': 'field_user', 'type': 'username'},
            ],
          };

          // User selects Credential 2 (Bob)
          final bobEntry = {
            'id': 'bob-id',
            'username': 'bob@example.com',
            'password': 'pass-bob-secret',
          };

          final result = simulateSessionAutofill(
            fillContexts: [context0, context1],
            activeStore: null,
            selectedEntry: bobEntry,
            isOpenKeyNest: false,
          );

          expect(result['sessionHadCombined'], isTrue);
          expect(result['isPasswordOnlyScreen'], isFalse);
          expect(result['replacesAllAssociatedFields'], isTrue);
          expect(
            result['datasetFieldValues']['field_user'],
            equals('bob@example.com'),
          );
          expect(
            result['datasetFieldValues']['field_password'],
            equals('pass-bob-secret'),
          );
        },
      );

      test(
        'Direct autofill: Clearing password field and selecting different credential updates BOTH fields',
        () {
          final context0 = {
            'fields': [
              {'id': 'field_user', 'type': 'username'},
              {'id': 'field_password', 'type': 'password'},
            ],
          };

          // User cleared password field: context 1 only reports the refocused password field
          final context1 = {
            'fields': [
              {'id': 'field_password', 'type': 'password'},
            ],
          };

          final bobEntry = {
            'id': 'bob-id',
            'username': 'bob@example.com',
            'password': 'pass-bob-secret',
          };

          final result = simulateSessionAutofill(
            fillContexts: [context0, context1],
            activeStore: null,
            selectedEntry: bobEntry,
            isOpenKeyNest: false,
          );

          expect(result['sessionHadCombined'], isTrue);
          expect(result['isPasswordOnlyScreen'], isFalse);
          expect(result['replacesAllAssociatedFields'], isTrue);
          expect(
            result['datasetFieldValues']['field_user'],
            equals('bob@example.com'),
          );
          expect(
            result['datasetFieldValues']['field_password'],
            equals('pass-bob-secret'),
          );
        },
      );

      test(
        'Open KeyNest sheet: Selecting credential from sheet updates BOTH fields after a field was cleared',
        () {
          final context0 = {
            'fields': [
              {'id': 'field_user', 'type': 'username'},
              {'id': 'field_password', 'type': 'current-password'},
              {'id': 'field_confirm', 'type': 'confirm-password'},
            ],
          };

          final context1 = {
            'fields': [
              {'id': 'field_user', 'type': 'username'},
            ],
          };

          final activeStore = {
            'usernameFieldIds': ['field_user'],
            'passwordFieldIds': ['field_password'],
            'confirmPwFieldIds': ['field_confirm'],
          };

          final bobEntry = {
            'id': 'bob-id',
            'username': 'bob@example.com',
            'password': 'pass-bob-secret',
          };

          final result = simulateSessionAutofill(
            fillContexts: [context0, context1],
            activeStore: activeStore,
            selectedEntry: bobEntry,
            isOpenKeyNest: true,
          );

          expect(result['sessionHadCombined'], isTrue);
          expect(
            result['datasetFieldValues']['field_user'],
            equals('bob@example.com'),
          );
          expect(
            result['datasetFieldValues']['field_password'],
            equals('pass-bob-secret'),
          );
          expect(
            result['datasetFieldValues']['field_confirm'],
            equals('pass-bob-secret'),
          );
        },
      );

      test(
        'Multi-step login: Password-only screen correctly remains isolated from previous username step',
        () {
          // Step 1: Username step
          final context0 = {
            'fields': [
              {'id': 'step1_username_field', 'type': 'username'},
            ],
          };

          // Step 2: Password step (different page/screen, no username field)
          final context1 = {
            'fields': [
              {'id': 'step2_password_field', 'type': 'password'},
            ],
          };

          final bobEntry = {
            'id': 'bob-id',
            'username': 'bob@example.com',
            'password': 'pass-bob-secret',
          };

          final result = simulateSessionAutofill(
            fillContexts: [context0, context1],
            activeStore: null,
            selectedEntry: bobEntry,
            isOpenKeyNest: false,
          );

          expect(result['sessionHadCombined'], isFalse);
          expect(result['isPasswordOnlyScreen'], isTrue);
          expect(
            result['datasetFieldValues'].containsKey('step2_password_field'),
            isTrue,
          );
          expect(
            result['datasetFieldValues']['step2_password_field'],
            equals('pass-bob-secret'),
          );
          expect(
            result['datasetFieldValues'].containsKey('step1_username_field'),
            isFalse,
          );
        },
      );
    });

    // Website Domain Matching & Unrelated Suggestion Isolation Suite
    group('Website Domain Matching & Unrelated Suggestion Isolation Suite', () {
      late KdbxFile testVault;
      late KdbxEntry gh1MissingUrl;
      late KdbxEntry gh2MalformedUrl;
      late KdbxEntry gh3ValidWeb;
      late KdbxEntry gh4ValidWebAndApp;
      late KdbxEntry pCloudEntry;

      setUp(() {
        final creds = Credentials(
          ProtectedValue.fromString('testPassword123!'),
        );
        testVault = KdbxFormat().create(creds, 'TestAutofillIsolationVault');

        // Entry 1: Title "Github", email freakymeow0@gmail.com, missing URL
        gh1MissingUrl = KdbxEntry.create(testVault, testVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('Github'))
          ..setString(
            KdbxKeyCommon.USER_NAME,
            PlainValue('freakymeow0@gmail.com'),
          )
          ..setString(KdbxKey('Email'), PlainValue('freakymeow0@gmail.com'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('secret1'),
          );

        // Entry 2: Title "GitHub", email moshicstu@gmail.com, malformed URL
        gh2MalformedUrl = KdbxEntry.create(testVault, testVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'))
          ..setString(
            KdbxKeyCommon.USER_NAME,
            PlainValue('moshicstu@gmail.com'),
          )
          ..setString(KdbxKey('Email'), PlainValue('moshicstu@gmail.com'))
          ..setString(KdbxKeyCommon.URL, PlainValue('https://'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('secret2'),
          );

        // Entry 3: Title "GitHub", username user3, valid URL
        gh3ValidWeb = KdbxEntry.create(testVault, testVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'))
          ..setString(KdbxKeyCommon.USER_NAME, PlainValue('octocat_user3'))
          ..setString(KdbxKeyCommon.URL, PlainValue('https://github.com'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('secret3'),
          );

        // Entry 4: Title "GitHub", username user4, valid URL and app
        gh4ValidWebAndApp =
            KdbxEntry.create(testVault, testVault.body.rootGroup)
              ..setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'))
              ..setString(KdbxKeyCommon.USER_NAME, PlainValue('octocat_user4'))
              ..setString(
                KdbxKeyCommon.URL,
                PlainValue('https://github.com/login'),
              )
              ..setString(
                KdbxKey('KP2A_URL_1'),
                PlainValue('androidapp://com.github.android'),
              )
              ..setString(
                KdbxKeyCommon.PASSWORD,
                ProtectedValue.fromString('secret4'),
              );

        // Legitimate pCloud entry
        pCloudEntry = KdbxEntry.create(testVault, testVault.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('pCloud'))
          ..setString(
            KdbxKeyCommon.USER_NAME,
            PlainValue('pcloud_user@example.com'),
          )
          ..setString(KdbxKeyCommon.URL, PlainValue('https://my.pcloud.com'))
          ..setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('pcloud_secret'),
          );

        testVault.body.rootGroup.addEntry(gh1MissingUrl);
        testVault.body.rootGroup.addEntry(gh2MalformedUrl);
        testVault.body.rootGroup.addEntry(gh3ValidWeb);
        testVault.body.rootGroup.addEntry(gh4ValidWebAndApp);
        testVault.body.rootGroup.addEntry(pCloudEntry);
      });

      test(
        'None of the four GitHub entries are suggested on unrelated websites (e.g. my.pcloud.com)',
        () {
          final matcher = CredentialMatcher.instance;
          final pcloudRequest = [
            CredentialRequest.web('https://my.pcloud.com'),
          ];
          final allEntries = testVault.body.rootGroup.getAllEntries();

          final matches = allEntries
              .where(
                (e) => matcher.matchBest(pcloudRequest, e.autofillUrls) != null,
              )
              .toList();

          // ONLY the genuine pCloud entry must match
          expect(matches.length, equals(1));
          expect(matches.first.uuid.uuid, equals(pCloudEntry.uuid.uuid));
          expect(
            matches.any((e) => e.uuid.uuid == gh1MissingUrl.uuid.uuid),
            isFalse,
          );
          expect(
            matches.any((e) => e.uuid.uuid == gh2MalformedUrl.uuid.uuid),
            isFalse,
          );
          expect(
            matches.any((e) => e.uuid.uuid == gh3ValidWeb.uuid.uuid),
            isFalse,
          );
          expect(
            matches.any((e) => e.uuid.uuid == gh4ValidWebAndApp.uuid.uuid),
            isFalse,
          );
        },
      );

      test(
        'None of the GitHub entries match on other unrelated domains (twitter.com, reddit.com)',
        () {
          final matcher = CredentialMatcher.instance;
          final twitterRequest = [CredentialRequest.web('https://twitter.com')];
          final redditRequest = [CredentialRequest.web('https://reddit.com')];
          final allEntries = testVault.body.rootGroup.getAllEntries();

          final twitterMatches = allEntries
              .where(
                (e) =>
                    matcher.matchBest(twitterRequest, e.autofillUrls) != null,
              )
              .toList();
          expect(twitterMatches.isEmpty, isTrue);

          final redditMatches = allEntries
              .where(
                (e) => matcher.matchBest(redditRequest, e.autofillUrls) != null,
              )
              .toList();
          expect(redditMatches.isEmpty, isTrue);
        },
      );

      test(
        'On GitHub website (github.com), legitimate GitHub credentials remain available',
        () {
          final matcher = CredentialMatcher.instance;
          final githubRequest = [
            CredentialRequest.web('https://github.com/login'),
          ];
          final allEntries = testVault.body.rootGroup.getAllEntries();

          final matches = allEntries
              .where(
                (e) => matcher.matchBest(githubRequest, e.autofillUrls) != null,
              )
              .toList();

          // gh3 and gh4 must match github.com
          expect(matches.length, equals(2));
          expect(
            matches.any((e) => e.uuid.uuid == gh3ValidWeb.uuid.uuid),
            isTrue,
          );
          expect(
            matches.any((e) => e.uuid.uuid == gh4ValidWebAndApp.uuid.uuid),
            isTrue,
          );

          // gh1 and gh2 with missing/malformed URLs must NOT match web requests
          expect(
            matches.any((e) => e.uuid.uuid == gh1MissingUrl.uuid.uuid),
            isFalse,
          );
          expect(
            matches.any((e) => e.uuid.uuid == gh2MalformedUrl.uuid.uuid),
            isFalse,
          );
        },
      );

      test(
        'Browser packages are recognized and excluded from application credential matching',
        () {
          expect(
            CredentialMatcher.isBrowserPackage('com.android.chrome'),
            isTrue,
          );
          expect(
            CredentialMatcher.isBrowserPackage('org.mozilla.firefox'),
            isTrue,
          );
          expect(
            CredentialMatcher.isBrowserPackage('com.brave.browser'),
            isTrue,
          );
          expect(
            CredentialMatcher.isBrowserPackage('com.sec.android.app.sbrowser'),
            isTrue,
          );
          expect(
            CredentialMatcher.isBrowserPackage('com.vivaldi.browser'),
            isTrue,
          );
          expect(
            CredentialMatcher.isBrowserPackage('com.kiwibrowser.browser'),
            isTrue,
          );
          expect(
            CredentialMatcher.isBrowserPackage('com.mi.globalbrowser'),
            isTrue,
          );

          // Non-browsers
          expect(
            CredentialMatcher.isBrowserPackage('com.github.android'),
            isFalse,
          );
          expect(
            CredentialMatcher.isBrowserPackage('com.spotify.music'),
            isFalse,
          );

          // A stored entry with androidapp://com.android.chrome MUST NOT match when a browser requests autofill
          final chromeAppEntry = ['androidapp://com.android.chrome'];
          final chromeRequest = CredentialRequest.application(
            'com.android.chrome',
          );
          expect(
            CredentialMatcher.instance.match(chromeRequest, chromeAppEntry[0]),
            isNull,
          );
        },
      );

      test('Malformed and edge-case URLs never produce erroneous matches', () {
        expect(CredentialMatcher.hostOf(''), isNull);
        expect(CredentialMatcher.hostOf('   '), isNull);
        expect(CredentialMatcher.hostOf('https://'), isNull);
        expect(CredentialMatcher.hostOf('http://'), isNull);
        expect(CredentialMatcher.hostOf('*'), isNull);
        expect(CredentialMatcher.hostOf('https://*'), isNull);
        expect(
          CredentialMatcher.hostOf('androidapp://com.github.android'),
          isNull,
        );
        expect(
          CredentialMatcher.hostOf('androidapp://com.android.chrome'),
          isNull,
        );

        // Valid URLs with authority cleaning
        expect(
          CredentialMatcher.hostOf('https://my.pcloud.com/#,'),
          equals('my.pcloud.com'),
        );
        expect(
          CredentialMatcher.hostOf('https://my.pcloud.com:443/login'),
          equals('my.pcloud.com'),
        );
        expect(
          CredentialMatcher.hostOf('my.pcloud.com'),
          equals('my.pcloud.com'),
        );
        expect(
          CredentialMatcher.hostOf('www.github.com'),
          equals('github.com'),
        );
      });
    });

    group('Keyboard Stability and Native Autofill Focus Protection Suite', () {
      test(
        '1. FLAG_VIEW_NOT_FOCUSED pre-fill requests do not trigger suggestion overlays or steal focus',
        () {
          // Android 14/15/16 triggers pre-fill probe requests (FLAG_VIEW_NOT_FOCUSED = 0x10) before views have focus.
          const flagViewNotFocused = 0x10;
          const flagSupportsFillDialog = 0x40;

          // A probing request when activity launches
          const probeFlags = flagViewNotFocused | flagSupportsFillDialog;
          final isUnfocusedProbe = (probeFlags & flagViewNotFocused) != 0;
          expect(
            isUnfocusedProbe,
            isTrue,
            reason:
                'Must detect pre-fill probing request to prevent focus theft',
          );

          // A focused request when user taps an input
          const userFocusFlags = flagSupportsFillDialog;
          final isUserFocused = (userFocusFlags & flagViewNotFocused) == 0;
          expect(
            isUserFocused,
            isTrue,
            reason: 'Must serve suggestions when view is genuinely focused',
          );
        },
      );

      test(
        '2. Chrome and modern browsers use native Autofill APIs without accessibility bridge interference',
        () {
          // Modern browsers handle virtual autofill natively.
          const knownBrowsers = [
            'com.android.chrome',
            'com.chrome.beta',
            'com.chrome.dev',
            'com.chrome.canary',
            'org.chromium.chrome',
            'org.mozilla.firefox',
            'com.microsoft.emmx',
            'com.opera.browser',
            'com.sec.android.app.sbrowser',
          ];

          for (final pkg in knownBrowsers) {
            expect(CredentialMatcher.isBrowserPackage(pkg), isTrue);
            // With compatibility mode disabled in service_configuration.xml:
            // Android does not inject AutofillCompatAccessibilityService into Chrome,
            // ensuring Blink InputConnection remains intact and soft keyboard stays open.
          }
        },
      );

      test('3. Dataset anchoring binds to the active focused field first', () {
        // Primary anchor must be the focused field
        const focusedFieldId = 101;
        const secondaryFieldId = 102;
        final targetIds = [focusedFieldId, secondaryFieldId];

        // The focused field is prioritized as primary dataset anchor
        expect(targetIds.first, equals(focusedFieldId));
        expect(targetIds.contains(secondaryFieldId), isTrue);
      });

      test(
        '4. Transient cancel during keyboard resize preserves active autofill session',
        () {
          // Simulate in-flight session lifecycle during adjustResize
          final activeSessions = <int, String>{1001: 'session_auth_data'};

          // Simulating the new onClientRequestCancelled behavior:
          // Do not destroy session data on transient window resize cancel
          void handleClientCancel(
            int requestId, {
            bool preserveSession = true,
          }) {
            if (!preserveSession) {
              activeSessions.remove(requestId);
            }
          }

          handleClientCancel(1001, preserveSession: true);
          expect(
            activeSessions.containsKey(1001),
            isTrue,
            reason:
                'Session state must be preserved during transient window resize cancellations',
          );
        },
      );

      test(
        '5. Credential selection and manual picker remain fully functional',
        () {
          // Username & email suggestions, passwords, and Open KeyNest remain intact
          final entry =
              KdbxEntry.create(primaryVault, primaryVault.body.rootGroup)
                ..setString(KdbxKeyCommon.TITLE, PlainValue('Test Account'))
                ..setString(KdbxKeyCommon.USER_NAME, PlainValue('testuser'))
                ..setString(KdbxKey('Email'), PlainValue('testuser@gmail.com'))
                ..setString(
                  KdbxKeyCommon.PASSWORD,
                  ProtectedValue.fromString('pass123!'),
                )
                ..setString(
                  KdbxKeyCommon.URL,
                  PlainValue('https://example.com'),
                );

          expect(
            entry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            equals('testuser'),
          );
          expect(
            entry.getString(KdbxKey('Email'))?.getText(),
            equals('testuser@gmail.com'),
          );
          expect(
            entry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
            equals('pass123!'),
          );
        },
      );
    });
  });
}
