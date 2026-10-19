import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/ui/screens/master_password_change.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'util/test_util.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Master Password Change Logic and Security Tests', () {
    late KdbxFormat kdbxFormat;
    late KdbxFile file;
    late KdbxGroup root;
    late KdbxEntry testEntry;
    const oldPassword = 'OldPassword123!';
    const newPassword = 'NewSecurePassword456!';

    setUp(() {
      kdbxFormat = KdbxFormat();
      final creds = Credentials.composite(
        ProtectedValue.fromString(oldPassword),
        null,
      );
      file = kdbxFormat.create(creds, 'TestVault');
      root = file.body.rootGroup;

      testEntry = KdbxEntry.create(file, root);
      root.addEntry(testEntry);
      testEntry.setString(KdbxKeyCommon.TITLE, PlainValue('Banking Login'));
      testEntry.setString(
        KdbxKeyCommon.USER_NAME,
        PlainValue('user@example.com'),
      );
      testEntry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString('secret_bank_pw'),
      );
    });

    test(
      'validateCurrentPassword correctly verifies matching credentials',
      () async {
        final mockBloc = MockKdbxBloc();

        final isValid =
            await MasterPasswordChangeScreen.validateCurrentPassword(
              kdbxBloc: mockBloc,
              file: file,
              currentPassword: oldPassword,
            );

        expect(isValid, isTrue);
      },
    );

    test(
      'validateCurrentPassword rejects incorrect current password',
      () async {
        final mockBloc = MockKdbxBloc();

        final isValid =
            await MasterPasswordChangeScreen.validateCurrentPassword(
              kdbxBloc: mockBloc,
              file: file,
              currentPassword: 'WrongPassword999',
            );

        expect(isValid, isFalse);
      },
    );

    test(
      'updateMasterPassword updates in-memory credentials and preserves all contents',
      () async {
        final mockBloc = MockKdbxBloc();

        when(
          mockBloc.saveFile(
            any,
            updateCredentials: anyNamed('updateCredentials'),
          ),
        ).thenAnswer((inv) async {
          final f = inv.positionalArguments[0] as KdbxFile;
          final newCreds =
              inv.namedArguments[#updateCredentials] as Credentials?;
          if (newCreds != null) {
            f.credentials = newCreds;
          }
          return FileContent(Uint8List(0));
        });

        await MasterPasswordChangeScreen.updateMasterPassword(
          kdbxBloc: mockBloc,
          file: file,
          newPassword: newPassword,
        );

        // Verify in-memory credentials updated
        final newCreds = Credentials.composite(
          ProtectedValue.fromString(newPassword),
          null,
        );
        expect(file.credentials.getHash(), equals(newCreds.getHash()));

        // Verify contents preserved intact
        expect(file.body.rootGroup.entries.length, 1);
        final retrievedEntry = file.body.rootGroup.entries.first;
        expect(
          retrievedEntry.getString(KdbxKeyCommon.TITLE)?.getText(),
          'Banking Login',
        );
        expect(
          retrievedEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'user@example.com',
        );
        expect(
          retrievedEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'secret_bank_pw',
        );

        // Verify validateCurrentPassword now matches newPassword and rejects oldPassword
        final isNewValid =
            await MasterPasswordChangeScreen.validateCurrentPassword(
              kdbxBloc: mockBloc,
              file: file,
              currentPassword: newPassword,
            );
        final isOldValid =
            await MasterPasswordChangeScreen.validateCurrentPassword(
              kdbxBloc: mockBloc,
              file: file,
              currentPassword: oldPassword,
            );

        expect(isNewValid, isTrue);
        expect(isOldValid, isFalse);
      },
    );

    test(
      'KDBX file saved with new password can be decrypted only by new password and rejects old password',
      () async {
        // Save file with old password
        final initialBytes = await file.save();

        // Change credentials on the file and save
        final newCreds = Credentials.composite(
          ProtectedValue.fromString(newPassword),
          null,
        );
        file.credentials = newCreds;
        final updatedBytes = await file.save();

        expect(updatedBytes, isNotEmpty);
        expect(updatedBytes, isNot(equals(initialBytes)));

        // Attempt to read updated bytes with old credentials -> must throw KdbxInvalidKeyException
        final oldCreds = Credentials.composite(
          ProtectedValue.fromString(oldPassword),
          null,
        );
        expect(
          () async => await kdbxFormat.read(updatedBytes, oldCreds),
          throwsA(isA<KdbxInvalidKeyException>()),
        );

        // Attempt to read updated bytes with new credentials -> must succeed
        final reopenedFile = await kdbxFormat.read(updatedBytes, newCreds);
        expect(reopenedFile, isNotNull);
        expect(reopenedFile.body.rootGroup.entries.length, 1);
        final reopenedEntry = reopenedFile.body.rootGroup.entries.first;
        expect(
          reopenedEntry.getString(KdbxKeyCommon.TITLE)?.getText(),
          'Banking Login',
        );
        expect(
          reopenedEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'user@example.com',
        );
        expect(
          reopenedEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'secret_bank_pw',
        );
      },
    );

    test(
      'Composite keyfile preservation: if vault has keyfile, changing password preserves keyfile component',
      () async {
        final mockBloc = MockKdbxBloc();
        final keyFileBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
        final compositeCreds = Credentials.composite(
          ProtectedValue.fromString('OldCompositePass'),
          keyFileBytes,
        );
        final compositeFile = kdbxFormat.create(compositeCreds, 'KeyFileVault');

        when(
          mockBloc.saveFile(
            any,
            updateCredentials: anyNamed('updateCredentials'),
          ),
        ).thenAnswer((inv) async {
          final f = inv.positionalArguments[0] as KdbxFile;
          final newCreds =
              inv.namedArguments[#updateCredentials] as Credentials?;
          if (newCreds != null) {
            f.credentials = newCreds;
          }
          return FileContent(Uint8List(0));
        });

        await MasterPasswordChangeScreen.updateMasterPassword(
          kdbxBloc: mockBloc,
          file: compositeFile,
          newPassword: 'NewCompositePass',
        );

        // Verify that compositeFile.credentials still includes the keyfile
        expect(compositeFile.credentials, isA<KeyFileComposite>());
        final activeComposite = compositeFile.credentials as KeyFileComposite;
        final expectedBinary = (compositeCreds as KeyFileComposite).keyFile!
            .getBinary();
        expect(activeComposite.keyFile?.getBinary(), equals(expectedBinary));
      },
    );

    testWidgets(
      'MasterPasswordChangeScreen shows empty view when no vaults are open',
      (tester) async {
        final mockBloc = MockKdbxBloc();
        when(mockBloc.openedFilesWithSources).thenReturn([]);

        await tester.pumpWidget(
          MaterialApp(
            home: Provider<KdbxBloc>.value(
              value: mockBloc,
              child: const MasterPasswordChangeScreen(),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('No Open Vaults'), findsOneWidget);
        expect(find.text('Open Vault'), findsOneWidget);
      },
    );

    testWidgets(
      'MasterPasswordChangeScreen displays form and validates input when vault is open',
      (tester) async {
        final mockBloc = MockKdbxBloc();
        final source = FakeTestFileSource();
        when(
          mockBloc.openedFilesWithSources,
        ).thenReturn([MapEntry(source, file)]);

        await tester.pumpWidget(
          MaterialApp(
            home: Provider<KdbxBloc>.value(
              value: mockBloc,
              child: const MasterPasswordChangeScreen(),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Update Vault Master Password'), findsOneWidget);
        expect(find.text('TARGET VAULT'), findsOneWidget);
        expect(find.text('TestVault'), findsWidgets);
        expect(find.text('Update Master Password'), findsOneWidget);

        // Scroll and tap submit with empty inputs -> validates current password field
        await tester.ensureVisible(find.text('Update Master Password'));
        await tester.tap(find.text('Update Master Password'));
        await tester.pump();

        expect(
          find.text('Please enter your current master password'),
          findsOneWidget,
        );
      },
    );
  });
}

class FakeTestFileSource extends FileSource {
  FakeTestFileSource()
    : super(
        databaseName: 'TestVault',
        uuid: 'fake-uuid',
      );

  @override
  FileSourceIcon get displayIcon => FileSourceIcon.hdd;

  @override
  String get displayNameFromPath => 'TestVault';

  @override
  String get displayPath => '/storage/TestVault.kdbx';

  @override
  bool get supportsWrite => true;

  @override
  Stream<FileContent> content({bool updateCache = true}) =>
      const Stream.empty();

  @override
  Future<FileContent> contentWrite(
    Uint8List bytes, {
    required Map<String, dynamic>? metadata,
  }) async => FileContent(bytes);

  @override
  FileSource copyWithDatabaseName(String databaseName) => this;

  @override
  Stream<FileContent> load() => const Stream.empty();

  @override
  Future<Map<String, dynamic>?> write(
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async => null;

  @override
  String get typeDebug => 'fake';
}
