import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_bloc.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:mockito/mockito.dart';

import 'util/test_util.dart';

class _FakeAnalyticsEvents extends Mock implements AnalyticsEvents {}

class _FakeAnalytics extends Mock implements Analytics {
  @override
  final AnalyticsEvents events = _FakeAnalyticsEvents();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KdbxBloc applySyncedBytes & In-Place Lifecycle Tests', () {
    late KdbxBloc kdbxBloc;
    late KdbxFile kdbxFile;
    late FileSource dummySource;
    late KdbxOpenedFile openedFile;

    setUp(() async {
      final env = await TestUtil.createEnv();
      final appDataBloc = AppDataBloc(env);
      final analytics = _FakeAnalytics();
      final cloudStorageBloc = CloudStorageBloc(env, PathUtils(), analytics);

      kdbxBloc = KdbxBloc(
        env: env,
        appDataBloc: appDataBloc,
        analytics: analytics,
        cloudStorageBloc: cloudStorageBloc,
      );

      kdbxFile = KdbxFormat().create(
        Credentials(ProtectedValue.fromString('password123')),
        'TestVault',
      );
      final initialBytes = await kdbxFile.save();

      dummySource = FileSourceUrl(
        Uri.parse('https://example.com/test.kdbx'),
        uuid: 'vault-uuid-test',
        databaseName: 'TestVault',
      );

      openedFile = await kdbxBloc.registerCreatedKdbxFile(
        fileSource: dummySource,
        kdbxFile: kdbxFile,
        bytes: initialBytes,
      );
    });

    tearDown(() {
      kdbxBloc.dispose();
    });

    test('applySyncedBytes retains live KdbxFile identity and does NOT close dirtyObjectsChanged stream', () async {
      final originalKdbxFile = openedFile.kdbxFile;
      expect(originalKdbxFile.isDirty, isFalse);

      // Create an entry in original file and save
      final entry = KdbxEntry.create(originalKdbxFile, originalKdbxFile.body.rootGroup);
      originalKdbxFile.body.rootGroup.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Initial Title'));
      final savedBytes = await originalKdbxFile.save();

      // Apply synced bytes
      final updatedOpened = await kdbxBloc.applySyncedBytes(openedFile, savedBytes);

      // The live instance MUST NOT be replaced
      expect(identical(updatedOpened.kdbxFile, originalKdbxFile), isTrue);

      // Mutating entry must NOT throw "Bad state: Cannot add new events after calling close"
      expect(() {
        entry.setString(KdbxKeyCommon.TITLE, PlainValue('Updated Title After Sync'));
      }, returnsNormally);

      expect(entry.getString(KdbxKeyCommon.TITLE)?.getText(), 'Updated Title After Sync');
      expect(originalKdbxFile.isDirty, isTrue);

      // fileForKdbxFile must locate the live file without error
      final resolved = kdbxBloc.fileForKdbxFile(originalKdbxFile);
      expect(resolved.fileSource.uuid, dummySource.uuid);
    });

    test('fileForKdbxFile falls back gracefully when matched by rootGroup UUID or single vault', () async {
      // Cloned or separate instance with same rootGroup UUID
      final matchingFile = KdbxFormat().create(
        Credentials(ProtectedValue.fromString('password123')),
        'ClonedVault',
      );
      matchingFile.body.rootGroup.uuid; // access
      // When single vault is open, fileForKdbxFile resolves safely
      final resolved = kdbxBloc.fileForKdbxFile(matchingFile);
      expect(resolved.fileSource.uuid, dummySource.uuid);
    });
  });

  group('Trash & Permanent Deletion Tests', () {
    late KdbxFile kdbxFile;

    setUp(() {
      kdbxFile = KdbxFormat().create(
        Credentials(ProtectedValue.fromString('password123')),
        'TrashTestVault',
      );
    });

    test('bulkDeleteEntries moves active entry to trash, and permanently deletes on 2nd call', () async {
      final entry = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      kdbxFile.body.rootGroup.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Secret 1'));

      expect(KeyNestItemTypeHelper.isEntryInTrash(entry), isFalse);

      // First delete: moves to recycle bin / trash
      await KeyNestItemTypeHelper.bulkDeleteEntries(entries: [entry]);
      expect(KeyNestItemTypeHelper.isEntryInTrash(entry), isTrue);
      expect(kdbxFile.body.rootGroup.getAllEntries(), contains(entry));

      // Second delete on entry in Trash: permanently removes it!
      await KeyNestItemTypeHelper.bulkDeleteEntries(entries: [entry]);
      expect(kdbxFile.body.rootGroup.getAllEntries(), isNot(contains(entry)));
      expect(entry.parent, isNull);
    });

    test('bulkDeleteEntries permanently deletes entry already in Trash in a single call', () async {
      final entry = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      kdbxFile.body.rootGroup.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Secret 2'));

      // Manually move to recycle bin
      kdbxFile.deleteEntry(entry);
      expect(KeyNestItemTypeHelper.isEntryInTrash(entry), isTrue);

      // Single call to bulkDeleteEntries must permanently delete it!
      await KeyNestItemTypeHelper.bulkDeleteEntries(entries: [entry]);
      expect(kdbxFile.body.rootGroup.getAllEntries(), isNot(contains(entry)));
      expect(entry.parent, isNull);
    });

    test('isEntryInTrash detects entries inside Trash-named folder even without recycleBinUUID', () async {
      final trashFolder = kdbxFile.createGroup(parent: kdbxFile.body.rootGroup, name: 'Trash');
      final entry = KdbxEntry.create(kdbxFile, trashFolder);
      trashFolder.addEntry(entry);

      expect(KeyNestItemTypeHelper.isTrashOrRecycleBin(trashFolder), isTrue);
      expect(KeyNestItemTypeHelper.isEntryInTrash(entry), isTrue);

      // Bulk delete removes it permanently
      await KeyNestItemTypeHelper.bulkDeleteEntries(entries: [entry]);
      expect(trashFolder.entries, isEmpty);
      expect(kdbxFile.body.rootGroup.getAllEntries(), isNot(contains(entry)));
    });
  });
}
