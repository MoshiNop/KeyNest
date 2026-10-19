// ignore_for_file: implementation_imports
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_header.dart';
import 'package:kdbx/src/kdbx_object.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/services/keynest_vault_merge_engine.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:mockito/mockito.dart';

import 'util/test_util.mocks.dart';

void main() {
  late MockKdbxBloc mockBloc;

  setUp(() {
    mockBloc = MockKdbxBloc();
    when(
      mockBloc.saveFile(any),
    ).thenAnswer((_) async => FileContent(Uint8List(0)));
  });

  KdbxFile createTestVault(String name) {
    final creds = Credentials.composite(
      ProtectedValue.fromString('pass123'),
      null,
    );
    return KdbxFormat().create(creds, name);
  }

  group('Problem 1: Deterministic Identity-Based Vault Merge Matching', () {
    test(
      'Priority 1: Matches by valid Unique ID (UUID) and updates modified entry via smartMerge',
      () async {
        final srcVault = createTestVault('SourceVault');
        final destVault = createTestVault('DestVault');

        final sharedUuid = KdbxUuid.random();

        // Destination entry (older)
        final destEntry = KdbxEntry.create(destVault, destVault.body.rootGroup);
        destVault.body.rootGroup.addEntry(destEntry);
        destEntry.forceSetUuid(sharedUuid);
        destEntry.setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'));
        destEntry.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('dev@test.com'),
        );
        destEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('OldPassword1'),
        );
        destEntry.times.lastModificationTime.set(DateTime.utc(2025, 1, 1));

        // Source entry (newer modified password)
        final srcEntry = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
        srcVault.body.rootGroup.addEntry(srcEntry);
        srcEntry.forceSetUuid(sharedUuid);
        srcEntry.setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'));
        srcEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue('dev@test.com'));
        srcEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('NewPassword2'),
        );
        srcEntry.times.lastModificationTime.set(DateTime.utc(2025, 6, 1));

        final result = await KeyNestVaultMergeEngine.mergeVaults(
          sourceVaults: [srcVault],
          destinationVault: destVault,
          kdbxBloc: mockBloc,
          duplicateStrategy: VaultMergeDuplicateStrategy.smartMerge,
        );

        expect(result.success, isTrue);
        expect(result.entriesUpdated, equals(1));
        expect(result.newEntriesAdded, equals(0));

        // Verify destination entry was updated with newer password
        expect(destVault.body.rootGroup.entries.length, equals(1));
        final updatedDest = destVault.body.rootGroup.entries.first;
        expect(
          updatedDest.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          equals('NewPassword2'),
        );
        expect(updatedDest.uuid, equals(sharedUuid));

        // Verify old password was archived to history
        expect(updatedDest.history.length, equals(1));
        expect(
          updatedDest.history.first
              .getString(KdbxKeyCommon.PASSWORD)
              ?.getText(),
          equals('OldPassword1'),
        );
      },
    );

    test(
      'Priority 2: Matches Logins by Normalized Identity (Title, Username, Domain/URL)',
      () async {
        final srcVault = createTestVault('SourceVault');
        final destVault = createTestVault('DestVault');

        // Different UUIDs, but same normalized identity
        final destEntry = KdbxEntry.create(destVault, destVault.body.rootGroup);
        destVault.body.rootGroup.addEntry(destEntry);
        destEntry.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('  Google Account  '),
        );
        destEntry.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('user@gmail.com'),
        );
        destEntry.setString(KdbxKeyCommon.URL, PlainValue('http://google.com'));
        destEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('OldPass'),
        );
        destEntry.times.lastModificationTime.set(DateTime.utc(2025, 2, 1));

        final srcEntry = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
        srcVault.body.rootGroup.addEntry(srcEntry);
        srcEntry.setString(KdbxKeyCommon.TITLE, PlainValue('google account'));
        srcEntry.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('  user@gmail.com  '),
        );
        srcEntry.setString(
          KdbxKeyCommon.URL,
          PlainValue('https://www.google.com/login/'),
        );
        srcEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('UpdatedPass'),
        );
        srcEntry.times.lastModificationTime.set(DateTime.utc(2025, 8, 1));

        final result = await KeyNestVaultMergeEngine.mergeVaults(
          sourceVaults: [srcVault],
          destinationVault: destVault,
          kdbxBloc: mockBloc,
          duplicateStrategy: VaultMergeDuplicateStrategy.smartMerge,
        );

        expect(result.success, isTrue);
        expect(result.entriesUpdated, equals(1));
        expect(result.newEntriesAdded, equals(0));
        expect(destVault.body.rootGroup.entries.length, equals(1));
        expect(
          destVault.body.rootGroup.entries.first
              .getString(KdbxKeyCommon.PASSWORD)
              ?.getText(),
          equals('UpdatedPass'),
        );
      },
    );

    test(
      'Priority 2: Matches Payment Cards by Title and Card Number (ignoring spaces/hyphens)',
      () async {
        final srcVault = createTestVault('SourceVault');
        final destVault = createTestVault('DestVault');

        final destCard = KdbxEntry.create(destVault, destVault.body.rootGroup);
        destVault.body.rootGroup.addEntry(destCard);
        KeyNestItemTypeHelper.setItemType(destCard, KeyNestItemType.card);
        destCard.setString(KdbxKeyCommon.TITLE, PlainValue('Chase Visa'));
        destCard.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('4111 2222 3333 4444'),
        );
        destCard.setString(KdbxKey('CVV'), ProtectedValue.fromString('123'));
        destCard.times.lastModificationTime.set(DateTime.utc(2025, 1, 1));

        final srcCard = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
        srcVault.body.rootGroup.addEntry(srcCard);
        KeyNestItemTypeHelper.setItemType(srcCard, KeyNestItemType.card);
        srcCard.setString(KdbxKeyCommon.TITLE, PlainValue('Chase Visa'));
        srcCard.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('4111-2222-3333-4444'),
        );
        srcCard.setString(
          KdbxKey('CVV'),
          ProtectedValue.fromString('999'),
        ); // Updated CVV
        srcCard.times.lastModificationTime.set(DateTime.utc(2025, 7, 1));

        final result = await KeyNestVaultMergeEngine.mergeVaults(
          sourceVaults: [srcVault],
          destinationVault: destVault,
          kdbxBloc: mockBloc,
        );

        expect(result.entriesUpdated, equals(1));
        expect(destVault.body.rootGroup.entries.length, equals(1));
        expect(destCard.getString(KdbxKey('CVV'))?.getText(), equals('999'));
      },
    );

    test('Priority 2: Matches Records by Title and Record Type', () async {
      final srcVault = createTestVault('SourceVault');
      final destVault = createTestVault('DestVault');

      final destRecord = KdbxEntry.create(destVault, destVault.body.rootGroup);
      destVault.body.rootGroup.addEntry(destRecord);
      KeyNestItemTypeHelper.setItemType(destRecord, KeyNestItemType.record);
      destRecord.setString(KdbxKey('RecordType'), PlainValue('Wi-Fi Password'));
      destRecord.setString(KdbxKeyCommon.TITLE, PlainValue('Home Office'));
      destRecord.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString('OldWifiKey'),
      );
      destRecord.times.lastModificationTime.set(DateTime.utc(2025, 1, 1));

      final srcRecord = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
      srcVault.body.rootGroup.addEntry(srcRecord);
      KeyNestItemTypeHelper.setItemType(srcRecord, KeyNestItemType.record);
      srcRecord.setString(KdbxKey('RecordType'), PlainValue('Wi-Fi Password'));
      srcRecord.setString(KdbxKeyCommon.TITLE, PlainValue('Home Office'));
      srcRecord.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString('NewWifiKey'),
      );
      srcRecord.times.lastModificationTime.set(DateTime.utc(2025, 9, 1));

      final result = await KeyNestVaultMergeEngine.mergeVaults(
        sourceVaults: [srcVault],
        destinationVault: destVault,
        kdbxBloc: mockBloc,
      );

      expect(result.entriesUpdated, equals(1));
      expect(
        destRecord.getString(KdbxKeyCommon.PASSWORD)?.getText(),
        equals('NewWifiKey'),
      );
    });

    test(
      'Priority 3: Fallback Complete Duplicate matches identical items with incomplete identity fields',
      () async {
        final srcVault = createTestVault('SourceVault');
        final destVault = createTestVault('DestVault');

        // Login missing username and URL (incomplete identity fields), but otherwise identical
        final destEntry = KdbxEntry.create(destVault, destVault.body.rootGroup);
        destVault.body.rootGroup.addEntry(destEntry);
        destEntry.setString(KdbxKeyCommon.TITLE, PlainValue('Offline Key'));
        destEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('secret123'),
        );

        final srcEntry = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
        srcVault.body.rootGroup.addEntry(srcEntry);
        srcEntry.setString(KdbxKeyCommon.TITLE, PlainValue('Offline Key'));
        srcEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('secret123'),
        );

        final result = await KeyNestVaultMergeEngine.mergeVaults(
          sourceVaults: [srcVault],
          destinationVault: destVault,
          kdbxBloc: mockBloc,
          duplicateStrategy: VaultMergeDuplicateStrategy.smartMerge,
        );

        // Identical complete duplicate is safely skipped
        expect(result.duplicatesSkipped, equals(1));
        expect(result.newEntriesAdded, equals(0));
        expect(destVault.body.rootGroup.entries.length, equals(1));
      },
    );

    test(
      'Conservatively handles incomplete identity fields and prevents matching unrelated entries',
      () async {
        final srcVault = createTestVault('SourceVault');
        final destVault = createTestVault('DestVault');

        // Unrelated entries that share only a generic Title "Personal" but different/missing identity
        final destEntry = KdbxEntry.create(destVault, destVault.body.rootGroup);
        destVault.body.rootGroup.addEntry(destEntry);
        destEntry.setString(KdbxKeyCommon.TITLE, PlainValue('Personal'));
        destEntry.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('alice@site.com'),
        );
        destEntry.setString(KdbxKeyCommon.URL, PlainValue('https://site.com'));

        // Source has same title "Personal", but NO username and NO URL (incomplete identity fields) and different password
        final srcEntry = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
        srcVault.body.rootGroup.addEntry(srcEntry);
        srcEntry.setString(KdbxKeyCommon.TITLE, PlainValue('Personal'));
        srcEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('differentPass'),
        );

        final result = await KeyNestVaultMergeEngine.mergeVaults(
          sourceVaults: [srcVault],
          destinationVault: destVault,
          kdbxBloc: mockBloc,
        );

        // Must NOT match: treated as new separate entry
        expect(result.newEntriesAdded, equals(1));
        expect(result.entriesUpdated, equals(0));
        expect(destVault.body.rootGroup.entries.length, equals(2));
      },
    );

    test(
      'Excludes Recycle Bin and trashed entries from matching and updates',
      () async {
        final srcVault = createTestVault('SourceVault');
        final destVault = createTestVault('DestVault');

        // Create Recycle Bin in destination
        final recycleBin = destVault.getRecycleBinOrCreate();

        // Trashed entry in destination
        final trashedDest = KdbxEntry.create(destVault, recycleBin);
        recycleBin.addEntry(trashedDest);
        trashedDest.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Deleted Account'),
        );
        trashedDest.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('user@deleted.com'),
        );
        trashedDest.setString(
          KdbxKeyCommon.URL,
          PlainValue('https://deleted.com'),
        );

        // Active source entry with same credentials
        final activeSrc = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
        srcVault.body.rootGroup.addEntry(activeSrc);
        activeSrc.setString(KdbxKeyCommon.TITLE, PlainValue('Deleted Account'));
        activeSrc.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('user@deleted.com'),
        );
        activeSrc.setString(
          KdbxKeyCommon.URL,
          PlainValue('https://deleted.com'),
        );

        final result = await KeyNestVaultMergeEngine.mergeVaults(
          sourceVaults: [srcVault],
          destinationVault: destVault,
          kdbxBloc: mockBloc,
        );

        // Trashed entry must NOT be matched or updated; source is created as new active entry
        expect(result.newEntriesAdded, equals(1));
        expect(result.entriesUpdated, equals(0));

        // Trashed item remains untouched in recycle bin
        expect(recycleBin.entries.length, equals(1));
        // New active item added to root group
        expect(destVault.body.rootGroup.entries.length, equals(1));
      },
    );
  });

  group('Problem 2: Merged Title Stored as PlainValue', () {
    test(
      'Stores (Merged) title suffix as PlainValue, not ProtectedValue',
      () async {
        final srcVault = createTestVault('SourceVault');
        final destVault = createTestVault('DestVault');

        final destEntry = KdbxEntry.create(destVault, destVault.body.rootGroup);
        destVault.body.rootGroup.addEntry(destEntry);
        destEntry.setString(KdbxKeyCommon.TITLE, PlainValue('My Bank'));
        destEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue('user1'));
        destEntry.setString(KdbxKeyCommon.URL, PlainValue('https://bank.com'));
        destEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('Secret1'),
        );

        final srcEntry = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
        srcVault.body.rootGroup.addEntry(srcEntry);
        srcEntry.setString(KdbxKeyCommon.TITLE, PlainValue('My Bank'));
        srcEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue('user1'));
        srcEntry.setString(KdbxKeyCommon.URL, PlainValue('https://bank.com'));
        srcEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('Secret2'),
        );

        // Run merge with keepAllDuplicate strategy
        final result = await KeyNestVaultMergeEngine.mergeVaults(
          sourceVaults: [srcVault],
          destinationVault: destVault,
          kdbxBloc: mockBloc,
          duplicateStrategy: VaultMergeDuplicateStrategy.keepAllDuplicate,
        );

        expect(result.success, isTrue);
        expect(result.newEntriesAdded, equals(1));

        expect(destVault.body.rootGroup.entries.length, equals(2));
        final mergedEntry = destVault.body.rootGroup.entries.last;

        final titleValue = mergedEntry.getString(KdbxKeyCommon.TITLE);
        expect(titleValue, isNotNull);
        expect(titleValue!.getText(), equals('My Bank (Merged)'));
        // Must be PlainValue, NOT ProtectedValue!
        expect(titleValue, isA<PlainValue>());
        expect(titleValue, isNot(isA<ProtectedValue>()));

        // Other fields maintain their original protection status
        final passwordValue = mergedEntry.getString(KdbxKeyCommon.PASSWORD);
        expect(passwordValue, isA<ProtectedValue>());
      },
    );

    test('Appends (Merged) suffix exactly once if already suffixed', () async {
      final srcVault = createTestVault('SourceVault');
      final destVault = createTestVault('DestVault');

      final destEntry = KdbxEntry.create(destVault, destVault.body.rootGroup);
      destVault.body.rootGroup.addEntry(destEntry);
      destEntry.setString(KdbxKeyCommon.TITLE, PlainValue('My Bank (Merged)'));
      destEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue('user1'));

      final srcEntry = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
      srcVault.body.rootGroup.addEntry(srcEntry);
      srcEntry.setString(KdbxKeyCommon.TITLE, PlainValue('My Bank (Merged)'));
      srcEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue('user1'));

      final result = await KeyNestVaultMergeEngine.mergeVaults(
        sourceVaults: [srcVault],
        destinationVault: destVault,
        kdbxBloc: mockBloc,
        duplicateStrategy: VaultMergeDuplicateStrategy.keepAllDuplicate,
      );

      expect(result.success, isTrue);
      final mergedEntry = destVault.body.rootGroup.entries.last;
      expect(
        mergedEntry.getString(KdbxKeyCommon.TITLE)?.getText(),
        equals('My Bank (Merged)'),
      );
      expect(mergedEntry.getString(KdbxKeyCommon.TITLE), isA<PlainValue>());
    });
  });

  group('KDBX 3.1 and KDBX 4.x Compatibility', () {
    test('Merge works with KDBX 3.1 and persists correctly', () async {
      final creds = Credentials.composite(
        ProtectedValue.fromString('pass123'),
        null,
      );
      final srcVault = KdbxFormat().create(
        creds,
        'Source3',
        header: KdbxHeader.createV3(),
      );
      final destVault = KdbxFormat().create(
        creds,
        'Dest3',
        header: KdbxHeader.createV3(),
      );
      expect(destVault.header.version.major, equals(3));

      final sharedUuid = KdbxUuid.random();
      final destEntry = KdbxEntry.create(destVault, destVault.body.rootGroup);
      destVault.body.rootGroup.addEntry(destEntry);
      destEntry.forceSetUuid(sharedUuid);
      destEntry.setString(KdbxKeyCommon.TITLE, PlainValue('Test Service'));
      destEntry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString('PassOld'),
      );
      destEntry.times.lastModificationTime.set(DateTime.utc(2025, 1, 1));

      final srcEntry = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
      srcVault.body.rootGroup.addEntry(srcEntry);
      srcEntry.forceSetUuid(sharedUuid);
      srcEntry.setString(KdbxKeyCommon.TITLE, PlainValue('Test Service'));
      srcEntry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString('PassNew'),
      );
      srcEntry.times.lastModificationTime.set(DateTime.utc(2025, 2, 1));

      final result = await KeyNestVaultMergeEngine.mergeVaults(
        sourceVaults: [srcVault],
        destinationVault: destVault,
        kdbxBloc: mockBloc,
        duplicateStrategy: VaultMergeDuplicateStrategy.smartMerge,
      );

      expect(result.success, isTrue);
      expect(result.entriesUpdated, equals(1));

      // Test cryptographic round-trip save and read
      final savedBytes = await destVault.save();
      final reloaded = await KdbxFormat().read(savedBytes, creds);
      final entry = reloaded.body.rootGroup.getAllEntries().first;
      expect(
        entry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
        equals('PassNew'),
      );
    });

    test(
      'Merge works with upgraded KDBX 4.x vault and preserves non-protected merged title',
      () async {
        final creds = Credentials.composite(
          ProtectedValue.fromString('pass123'),
          null,
        );
        final srcVault = KdbxFormat().create(creds, 'Source4');
        final destVault = KdbxFormat().create(creds, 'Dest4');
        destVault.upgrade(4);
        expect(destVault.header.version.major, equals(4));

        final destEntry = KdbxEntry.create(destVault, destVault.body.rootGroup);
        destVault.body.rootGroup.addEntry(destEntry);
        destEntry.setString(KdbxKeyCommon.TITLE, PlainValue('Work VPN'));
        destEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue('employee'));
        destEntry.setString(KdbxKeyCommon.URL, PlainValue('vpn.work.internal'));

        final srcEntry = KdbxEntry.create(srcVault, srcVault.body.rootGroup);
        srcVault.body.rootGroup.addEntry(srcEntry);
        srcEntry.setString(KdbxKeyCommon.TITLE, PlainValue('Work VPN'));
        srcEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue('employee'));
        srcEntry.setString(KdbxKeyCommon.URL, PlainValue('vpn.work.internal'));

        final result = await KeyNestVaultMergeEngine.mergeVaults(
          sourceVaults: [srcVault],
          destinationVault: destVault,
          kdbxBloc: mockBloc,
          duplicateStrategy: VaultMergeDuplicateStrategy.keepAllDuplicate,
        );

        expect(result.success, isTrue);
        expect(result.newEntriesAdded, equals(1));

        // Round-trip save and read in KDBX 4
        final savedBytes = await destVault.save();
        final reloaded = await KdbxFormat().read(savedBytes, creds);
        expect(reloaded.header.version.major, equals(4));

        final mergedEntry = reloaded.body.rootGroup.getAllEntries().firstWhere(
          (e) =>
              e.getString(KdbxKeyCommon.TITLE)?.getText() ==
              'Work VPN (Merged)',
        );
        final titleVal = mergedEntry.getString(KdbxKeyCommon.TITLE);
        expect(titleVal, isA<PlainValue>());
        expect(titleVal, isNot(isA<ProtectedValue>()));
      },
    );
  });
}
