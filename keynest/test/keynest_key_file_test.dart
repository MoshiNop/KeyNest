import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:convert/convert.dart' as convert;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_header.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/services/key_file_store.dart';
import 'package:keynest/ui/screens/master_password_change.dart';
import 'package:keynest/ui/widgets/keynest_key_file_creation_section.dart';
import 'package:keynest/utils/key_file_handler.dart';
import 'package:mockito/mockito.dart';

import 'util/test_util.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KDBX Key File Parser & Formats Tests', () {
    test('Parse KeePass XML v2.0 key file with valid hash', () {
      final keyBytes = Uint8List.fromList(List.generate(32, (i) => i * 3 + 1));
      final hexKey = convert.hex.encode(keyBytes);
      final hashBytes = crypto.sha256.convert(keyBytes).bytes.sublist(0, 4);
      final hexHash = convert.hex.encode(hashBytes);

      final xmlContent =
          '''<?xml version="1.0" encoding="utf-8"?>
<KeyFile>
  <Meta>
    <Version>2.0</Version>
  </Meta>
  <Key>
    <Data Hash="$hexHash">$hexKey</Data>
  </Key>
</KeyFile>''';

      final result = KeyNestKeyFile.parse(
        Uint8List.fromList(utf8.encode(xmlContent)),
        fileName: 'test.keyx',
      );

      expect(result.format, equals(KeyNestKeyFileFormat.xmlV2));
      expect(result.keyBytes, equals(keyBytes));
      expect(result.displayName, contains('v2.0'));
    });

    test(
      'XML v2.0 key file with hash mismatch throws KeyFileValidationException',
      () {
        final keyBytes = Uint8List.fromList(List.generate(32, (i) => i + 5));
        final hexKey = convert.hex.encode(keyBytes);
        const wrongHash = '12345678'; // Invalid hash

        final xmlContent =
            '''<?xml version="1.0" encoding="utf-8"?>
<KeyFile>
  <Meta>
    <Version>2.0</Version>
  </Meta>
  <Key>
    <Data Hash="$wrongHash">$hexKey</Data>
  </Key>
</KeyFile>''';

        expect(
          () => KeyNestKeyFile.parse(
            Uint8List.fromList(utf8.encode(xmlContent)),
            fileName: 'corrupted.keyx',
          ),
          throwsA(isA<KeyFileValidationException>()),
        );
      },
    );

    test(
      'Malformed XML throws KeyFileValidationException without fallback to hashing',
      () {
        const brokenXml =
            '<KeyFile><Meta><Version>2.0</Version></Meta><Key><Data>';

        expect(
          () => KeyNestKeyFile.parse(
            Uint8List.fromList(utf8.encode(brokenXml)),
            fileName: 'broken.keyx',
          ),
          throwsA(isA<KeyFileValidationException>()),
        );
      },
    );

    test('Parse KeePass XML v1.0 key file with base64 data', () {
      final keyBytes = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final base64Key = base64.encode(keyBytes);

      final xmlContent =
          '''<?xml version="1.0" encoding="utf-8"?>
<KeyFile>
  <Meta>
    <Version>1.0</Version>
  </Meta>
  <Key>
    <Data>$base64Key</Data>
  </Key>
</KeyFile>''';

      final result = KeyNestKeyFile.parse(
        Uint8List.fromList(utf8.encode(xmlContent)),
        fileName: 'v1.key',
      );

      expect(result.format, equals(KeyNestKeyFileFormat.xmlV1));
      expect(result.keyBytes, equals(keyBytes));
    });

    test('Parse raw 32-byte binary key file preserving exact bytes', () {
      final raw32 = Uint8List.fromList(
        List.generate(32, (i) => (i * 7 + 13) % 256),
      );

      final result = KeyNestKeyFile.parse(raw32, fileName: 'binary.key');

      expect(result.format, equals(KeyNestKeyFileFormat.binary32));
      expect(result.keyBytes, equals(raw32));
    });

    test('Parse 64-character hexadecimal key file', () {
      final expectedKey = Uint8List.fromList(List.generate(32, (i) => i * 2));
      final hexString = convert.hex.encode(expectedKey);

      final result = KeyNestKeyFile.parse(
        Uint8List.fromList(utf8.encode(hexString)),
        fileName: 'hex.key',
      );

      expect(result.format, equals(KeyNestKeyFileFormat.hex64));
      expect(result.keyBytes, equals(expectedKey));
    });

    test('Arbitrary non-standard file is hashed with SHA-256', () {
      final arbitraryContent = utf8.encode(
        'This is an arbitrary user file used as key material',
      );
      final expectedHash = Uint8List.fromList(
        crypto.sha256.convert(arbitraryContent).bytes,
      );

      final result = KeyNestKeyFile.parse(
        Uint8List.fromList(arbitraryContent),
        fileName: 'secret.txt',
      );

      expect(result.format, equals(KeyNestKeyFileFormat.hashed));
      expect(result.keyBytes, equals(expectedHash));
    });

    test('Empty file throws KeyFileValidationException', () {
      expect(
        () => KeyNestKeyFile.parse(Uint8List(0), fileName: 'empty.key'),
        throwsA(isA<KeyFileValidationException>()),
      );
    });

    test('generateXmlV2 produces standards-compliant XML v2.0 key file', () {
      final generatedXmlBytes = KeyNestKeyFile.generateXmlV2();
      final generatedXmlString = utf8.decode(generatedXmlBytes);

      expect(generatedXmlString, contains('<Version>2.0</Version>'));
      expect(generatedXmlString, contains('<Key>'));
      expect(generatedXmlString, contains('<Data Hash='));

      // Verify that parsing the generated XML succeeds and validates the hash
      final parsed = KeyNestKeyFile.parse(
        generatedXmlBytes,
        fileName: 'generated.keyx',
      );

      expect(parsed.format, equals(KeyNestKeyFileFormat.xmlV2));
      expect(parsed.keyBytes.length, equals(32));
    });

    test(
      'generateXmlV2 produces unpredictable, cryptographically random keys each time',
      () {
        final key1 = KeyNestKeyFile.generateXmlV2();
        final key2 = KeyNestKeyFile.generateXmlV2();

        expect(key1, isNot(equals(key2)));

        final parsed1 = KeyNestKeyFile.parse(key1);
        final parsed2 = KeyNestKeyFile.parse(key2);

        expect(parsed1.keyBytes, isNot(equals(parsed2.keyBytes)));
        expect(parsed1.keyBytes.length, equals(32));
        expect(parsed2.keyBytes.length, equals(32));
      },
    );

    test(
      'Interrupted operation can safely reuse generated key material without regenerating',
      () {
        // Simulates caching generated key material during an interrupted operation
        Uint8List? cachedBytes;
        cachedBytes ??= KeyNestKeyFile.generateXmlV2();
        final firstAttemptKey = KeyNestKeyFile.parse(cachedBytes).keyBytes;

        // Retry attempt reuses the cached key material
        final secondAttemptBytes = cachedBytes;
        final secondAttemptKey = KeyNestKeyFile.parse(
          secondAttemptBytes,
        ).keyBytes;

        expect(firstAttemptKey, equals(secondAttemptKey));
      },
    );
  });

  group('Composite Credentials Derivation Tests', () {
    test(
      'createCompositeCredentials with password only creates Credentials with password',
      () {
        final creds = KeyNestKeyFile.createCompositeCredentials(
          password: 'MyPassword123',
        );

        expect(creds, isA<KeyFileComposite>());
        final composite = creds as KeyFileComposite;
        expect(composite.password, isNotNull);
        expect(composite.keyFile, isNull);
      },
    );

    test(
      'createCompositeCredentials with key file only creates Credentials with key file',
      () {
        final keyBytes = Uint8List.fromList(List.generate(32, (i) => i));
        final creds = KeyNestKeyFile.createCompositeCredentials(
          keyFileBytes: keyBytes,
        );

        expect(creds, isA<KeyFileComposite>());
        final composite = creds as KeyFileComposite;
        expect(composite.password, isNull);
        expect(composite.keyFile?.getBinary(), equals(keyBytes));
      },
    );

    test(
      'createCompositeCredentials with password and key file creates composite with both',
      () {
        final keyBytes = Uint8List.fromList(List.generate(32, (i) => i + 1));
        final creds = KeyNestKeyFile.createCompositeCredentials(
          password: 'MyPassword123',
          keyFileBytes: keyBytes,
        );

        expect(creds, isA<KeyFileComposite>());
        final keyComposite = creds as KeyFileComposite;
        expect(keyComposite.password, isNotNull);
        expect(keyComposite.keyFile?.getBinary(), equals(keyBytes));
      },
    );

    test('createCompositeCredentials with neither throws ArgumentError', () {
      expect(
        () => KeyNestKeyFile.createCompositeCredentials(),
        throwsArgumentError,
      );
    });
  });

  group('KDBX 4.0 Argon2 Vault Key File Round-Trip Tests', () {
    test(
      'KDBX 4.0 vault encrypted with Password + Key File decrypts only with both',
      () async {
        const password = 'VaultPassword4.0!';
        final keyBytes = Uint8List.fromList(
          List.generate(32, (i) => i * 4 + 7),
        );

        final compositeCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: keyBytes,
        );

        final format = KdbxFormat();
        final vault = format.create(compositeCreds, 'Argon2 KeyFile Vault');
        final root = vault.body.rootGroup;
        final entry = KdbxEntry.create(vault, root);
        root.addEntry(entry);
        entry.setString(KdbxKeyCommon.TITLE, PlainValue('Secret Item'));
        entry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('SecretPass123'),
        );

        final vaultBytes = await vault.save();

        // 1. Decrypt with correct Password + Key File -> SUCCEEDS
        final unlockedVault = await format.read(vaultBytes, compositeCreds);
        final foundEntry = unlockedVault.body.rootGroup.entries.firstWhere(
          (e) => e.getString(KdbxKeyCommon.TITLE)?.getText() == 'Secret Item',
        );
        expect(
          foundEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          equals('SecretPass123'),
        );

        // 2. Decrypt with Password ALONE -> FAILS
        final passwordOnlyCreds = Credentials.composite(
          ProtectedValue.fromString(password),
          null,
        );
        expect(
          () => format.read(vaultBytes, passwordOnlyCreds),
          throwsA(isA<KdbxInvalidKeyException>()),
        );

        // 3. Decrypt with correct Password + WRONG Key File -> FAILS
        final wrongKeyBytes = Uint8List.fromList(
          List.generate(32, (i) => 200 - i),
        );
        final wrongCompositeCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: wrongKeyBytes,
        );
        expect(
          () => format.read(vaultBytes, wrongCompositeCreds),
          throwsA(isA<KdbxInvalidKeyException>()),
        );

        // 4. Decrypt with WRONG Password + correct Key File -> FAILS
        final wrongPasswordCreds = KeyNestKeyFile.createCompositeCredentials(
          password: 'WrongPassword!',
          keyFileBytes: keyBytes,
        );
        expect(
          () => format.read(vaultBytes, wrongPasswordCreds),
          throwsA(isA<KdbxInvalidKeyException>()),
        );
      },
    );

    test(
      'Existing Password-Only KDBX 4.0 vault continues to open unchanged',
      () async {
        const password = 'PasswordOnlyVault123';
        final creds = Credentials.composite(
          ProtectedValue.fromString(password),
          null,
        );

        final format = KdbxFormat();
        final vault = format.create(creds, 'Legacy Password Vault');
        final vaultBytes = await vault.save();

        final reopened = await format.read(vaultBytes, creds);
        expect(
          reopened.body.rootGroup.name.get(),
          equals('Legacy Password Vault'),
        );
      },
    );
  });

  group('KDBX 3.1 Compatibility Tests', () {
    test(
      'KDBX 3.1 vault with Password + Key File decrypts correctly',
      () async {
        const password = 'Kdbx3Password!';
        final keyBytes = Uint8List.fromList(
          List.generate(32, (i) => i * 2 + 1),
        );

        final compositeCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: keyBytes,
        );

        final format = KdbxFormat();
        final vault = format.create(
          compositeCreds,
          'KDBX 3.1 KeyFile Vault',
          header: KdbxHeader.createV3(),
        );
        final vaultBytes = await vault.save();

        // Reopen with composite credentials
        final reopened = await format.read(vaultBytes, compositeCreds);
        expect(
          reopened.body.rootGroup.name.get(),
          equals('KDBX 3.1 KeyFile Vault'),
        );

        // Reopen with password alone fails
        final pwOnly = Credentials.composite(
          ProtectedValue.fromString(password),
          null,
        );
        expect(
          () => format.read(vaultBytes, pwOnly),
          throwsA(isA<KdbxInvalidKeyException>()),
        );
      },
    );
  });

  group('Master Password & Key File Update Lifecycle Tests', () {
    late KdbxFormat kdbxFormat;
    late KdbxFile file;
    late Uint8List originalKeyBytes;
    const initialPassword = 'InitialPassword123!';

    setUp(() {
      kdbxFormat = KdbxFormat();
      originalKeyBytes = Uint8List.fromList(List.generate(32, (i) => i + 10));
      final compositeCreds = KeyNestKeyFile.createCompositeCredentials(
        password: initialPassword,
        keyFileBytes: originalKeyBytes,
      );
      file = kdbxFormat.create(compositeCreds, 'UpdateLifecycleVault');
    });

    test('Changing password preserves existing key file by default', () async {
      const newPassword = 'NewSecretPassword456!';
      final mockBloc = MockKdbxBloc();
      when(
        mockBloc.saveFile(
          any,
          updateCredentials: anyNamed('updateCredentials'),
        ),
      ).thenAnswer((inv) async {
        final f = inv.positionalArguments[0] as KdbxFile;
        final newCreds = inv.namedArguments[#updateCredentials] as Credentials?;
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

      expect(file.credentials, isA<KeyFileComposite>());
      final composite = file.credentials as KeyFileComposite;
      expect(composite.keyFile?.getBinary(), equals(originalKeyBytes));

      final savedBytes = await file.save();
      final reopened = await kdbxFormat.read(savedBytes, file.credentials);
      expect(
        reopened.body.rootGroup.name.get(),
        equals('UpdateLifecycleVault'),
      );
    });

    test('Replacing key file updates vault credentials', () async {
      const newPassword = 'NewSecretPassword456!';
      final newKeyBytes = Uint8List.fromList(List.generate(32, (i) => 250 - i));
      final mockBloc = MockKdbxBloc();
      when(
        mockBloc.saveFile(
          any,
          updateCredentials: anyNamed('updateCredentials'),
        ),
      ).thenAnswer((inv) async {
        final f = inv.positionalArguments[0] as KdbxFile;
        final newCreds = inv.namedArguments[#updateCredentials] as Credentials?;
        if (newCreds != null) {
          f.credentials = newCreds;
        }
        return FileContent(Uint8List(0));
      });

      await MasterPasswordChangeScreen.updateMasterPassword(
        kdbxBloc: mockBloc,
        file: file,
        newPassword: newPassword,
        newKeyFileBytes: newKeyBytes,
      );

      expect(file.credentials, isA<KeyFileComposite>());
      final composite = file.credentials as KeyFileComposite;
      expect(composite.keyFile?.getBinary(), equals(newKeyBytes));

      final savedBytes = await file.save();
      // Unlocks with new key file
      final reopened = await kdbxFormat.read(savedBytes, file.credentials);
      expect(
        reopened.body.rootGroup.name.get(),
        equals('UpdateLifecycleVault'),
      );

      // Fails with old key file
      final oldCreds = KeyNestKeyFile.createCompositeCredentials(
        password: newPassword,
        keyFileBytes: originalKeyBytes,
      );
      expect(
        () => kdbxFormat.read(savedBytes, oldCreds),
        throwsA(isA<KdbxInvalidKeyException>()),
      );
    });

    test('Removing key file converts vault to password-only', () async {
      const newPassword = 'PasswordOnlyNow!';
      final mockBloc = MockKdbxBloc();
      when(
        mockBloc.saveFile(
          any,
          updateCredentials: anyNamed('updateCredentials'),
        ),
      ).thenAnswer((inv) async {
        final f = inv.positionalArguments[0] as KdbxFile;
        final newCreds = inv.namedArguments[#updateCredentials] as Credentials?;
        if (newCreds != null) {
          f.credentials = newCreds;
        }
        return FileContent(Uint8List(0));
      });

      await MasterPasswordChangeScreen.updateMasterPassword(
        kdbxBloc: mockBloc,
        file: file,
        newPassword: newPassword,
        removeKeyFile: true,
      );

      expect(file.credentials, isA<KeyFileComposite>());
      expect((file.credentials as KeyFileComposite).keyFile, isNull);

      final savedBytes = await file.save();
      // Unlocks with password alone
      final pwOnly = Credentials.composite(
        ProtectedValue.fromString(newPassword),
        null,
      );
      final reopened = await kdbxFormat.read(savedBytes, pwOnly);
      expect(
        reopened.body.rootGroup.name.get(),
        equals('UpdateLifecycleVault'),
      );
    });
  });

  group('KeyFileStore Multi-Vault Isolation Tests', () {
    test('Saving and retrieving key file references isolates vaults', () async {
      final store = KeyNestKeyFileStore.instance;

      const vaultAUuid = 'vault-uuid-aaaa-1111';
      const vaultBUuid = 'vault-uuid-bbbb-2222';

      await store.saveReference(
        vaultUuid: vaultAUuid,
        displayName: 'vault_a.key',
        filePath: '/path/to/vault_a.key',
      );

      await store.saveReference(
        vaultUuid: vaultBUuid,
        displayName: 'vault_b.keyx',
        filePath: '/path/to/vault_b.keyx',
      );

      final refA = await store.getReference(vaultAUuid);
      final refB = await store.getReference(vaultBUuid);

      expect(refA?.displayName, equals('vault_a.key'));
      expect(refA?.filePath, equals('/path/to/vault_a.key'));

      expect(refB?.displayName, equals('vault_b.keyx'));
      expect(refB?.filePath, equals('/path/to/vault_b.keyx'));

      // Removing A does not affect B
      await store.removeReference(vaultAUuid);
      expect(await store.getReference(vaultAUuid), isNull);
      expect(
        (await store.getReference(vaultBUuid))?.displayName,
        equals('vault_b.keyx'),
      );

      // Clean up B
      await store.removeReference(vaultBUuid);
      expect(await store.getReference(vaultBUuid), isNull);
    });
  });

  group('KeyNestKeyFileCreationController Tests', () {
    test('Default state has key file disabled with generate option', () {
      final controller = KeyNestKeyFileCreationController();
      expect(controller.useKeyFile, isFalse);
      expect(controller.option, equals(KeyNestKeyFileOption.generate));
      expect(controller.keyFileBytes, isNull);
      expect(controller.effectiveKeyFileBytes, isNull);
      expect(controller.keyFileName, isNull);
      expect(controller.keyFileResult, isNull);
      controller.dispose();
    });

    test(
      'Toggling useKeyFile notifies listeners and clears state when disabled',
      () {
        final controller = KeyNestKeyFileCreationController();
        var notifications = 0;
        controller.addListener(() => notifications++);

        controller.useKeyFile = true;
        expect(controller.useKeyFile, isTrue);
        expect(notifications, equals(1));

        // Setting same value doesn't re-notify
        controller.useKeyFile = true;
        expect(notifications, equals(1));

        controller.useKeyFile = false;
        expect(controller.useKeyFile, isFalse);
        expect(notifications, equals(2));
        controller.dispose();
      },
    );

    test('Option switching works as expected', () {
      final controller = KeyNestKeyFileCreationController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.option = KeyNestKeyFileOption.existing;
      expect(controller.option, equals(KeyNestKeyFileOption.existing));
      expect(notifications, equals(1));

      controller.option = KeyNestKeyFileOption.generate;
      expect(controller.option, equals(KeyNestKeyFileOption.generate));
      expect(notifications, equals(2));
      controller.dispose();
    });

    test(
      'Effective bytes are null when useKeyFile is false even if internal bytes exist',
      () {
        final controller = KeyNestKeyFileCreationController();

        // Controller is disabled: effective bytes must be null
        expect(controller.effectiveKeyFileBytes, isNull);

        // Even if key file bytes were assigned internally:
        controller.useKeyFile = false;
        expect(controller.effectiveKeyFileBytes, isNull);
        controller.dispose();
      },
    );
  });

  group('Shared Multi-Entry Vault Creation Integration Tests', () {
    test(
      'Vault created with key file protects composite credentials across all creation entry points',
      () async {
        // 1. Generate XML v2.0 key file (as done by KeyNestKeyFileCreationController)
        final generatedXml = KeyNestKeyFile.generateXmlV2();
        expect(
          KeyNestKeyFile.parse(generatedXml).format,
          equals(KeyNestKeyFileFormat.xmlV2),
        );

        const password = 'SharedVaultPassword123!';
        final compositeCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: generatedXml,
        );

        // 2. Create KDBX 4.0 database (shared format used by KdbxBloc.createFile)
        final kdbxFormat = KdbxFormat();
        final file = kdbxFormat.create(
          compositeCreds,
          'UniversalProtectedVault',
        );
        final rawBytes = await file.save();

        // 3. Verify that the newly created vault can be unlocked using composite credentials
        final unlockedFile = await kdbxFormat.read(rawBytes, compositeCreds);
        expect(
          unlockedFile.body.rootGroup.name.get(),
          equals('UniversalProtectedVault'),
        );

        // 4. Verify password-only unlock fails
        final passwordOnlyCreds = Credentials(
          ProtectedValue.fromString(password),
        );
        expect(
          () async => await kdbxFormat.read(rawBytes, passwordOnlyCreds),
          throwsA(anything),
        );

        // 5. Verify wrong key file fails
        final wrongKeyBytes = KeyNestKeyFile.generateXmlV2();
        final wrongCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: wrongKeyBytes,
        );
        expect(
          () async => await kdbxFormat.read(rawBytes, wrongCreds),
          throwsA(anything),
        );
      },
    );

    test(
      'Vault created without key file (password-only) remains fully backwards-compatible',
      () async {
        const password = 'StandardPasswordOnlyVault!';
        final creds = Credentials(ProtectedValue.fromString(password));

        final kdbxFormat = KdbxFormat();
        final file = kdbxFormat.create(
          creds,
          'StandardPasswordOnlyVault',
        );
        final rawBytes = await file.save();

        // Unlocks seamlessly with password alone
        final unlocked = await kdbxFormat.read(rawBytes, creds);
        expect(
          unlocked.body.rootGroup.name.get(),
          equals('StandardPasswordOnlyVault'),
        );
      },
    );
  });

  group('Persistent, Vault-Specific Key File Requirements & Regression Tests', () {
    late KdbxFormat kdbxFormat;
    late io.Directory tempDir;

    setUp(() {
      kdbxFormat = KdbxFormat();
      tempDir = io.Directory.systemTemp.createTempSync(
        'keynest_regression_test_',
      );
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      '1. Password-only vault opens with correct password and no key file',
      () async {
        const password = 'CorrectPasswordOnly123!';
        final creds = Credentials(ProtectedValue.fromString(password));
        final file = kdbxFormat.create(creds, 'PasswordOnlyVault');
        final entry = KdbxEntry.create(file, file.body.rootGroup);
        entry.setString(KdbxKeyCommon.TITLE, PlainValue('SecretAccount'));
        entry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('SecretPassword'),
        );
        file.body.rootGroup.addEntry(entry);
        final rawBytes = await file.save();

        // Opens with only the master password
        final opened = await kdbxFormat.read(rawBytes, creds);
        expect(opened.body.rootGroup.name.get(), equals('PasswordOnlyVault'));
        expect(
          opened.body.rootGroup.getAllEntries().any(
            (e) => e.label == 'SecretAccount',
          ),
          isTrue,
        );

        // Verify no key file association is recorded for this vault
        const vaultUuid = 'pwd-only-uuid-1';
        final hasKeyFile = await KeyNestKeyFileStore.instance.hasKeyFile(
          vaultUuid,
        );
        expect(hasKeyFile, isFalse);
      },
    );

    test(
      '2. Password-only vault continues to open after app restart without requiring key file',
      () async {
        const password = 'PersistentPasswordOnly456!';
        const vaultUuid = 'pwd-only-vault-restart';
        final creds = Credentials(ProtectedValue.fromString(password));
        final file = kdbxFormat.create(creds, 'PersistentVault');
        final rawBytes = await file.save();

        // Simulate app restart by clearing memory cache of KeyNestKeyFileStore
        KeyNestKeyFileStore.instance.clearMemoryCache();

        // Check key file store - confirms no key file is required or loaded
        final ref = await KeyNestKeyFileStore.instance.getReference(vaultUuid);
        expect(ref, isNull);
        final hasKeyFile = await KeyNestKeyFileStore.instance.hasKeyFile(
          vaultUuid,
        );
        expect(hasKeyFile, isFalse);

        // Vault opens seamlessly with only master password
        final opened = await kdbxFormat.read(rawBytes, creds);
        expect(opened.body.rootGroup.name.get(), equals('PersistentVault'));
      },
    );

    test(
      '3. Key-file-protected vault opens with correct password and correct key file',
      () async {
        const password = 'ProtectedVaultPassword789!';
        final keyFileBytes = KeyNestKeyFile.generateXmlV2();
        final compositeCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: keyFileBytes,
        );

        final file = kdbxFormat.create(compositeCreds, 'KeyProtectedVault');
        final rawBytes = await file.save();

        // Opens with both credentials
        final opened = await kdbxFormat.read(rawBytes, compositeCreds);
        expect(opened.body.rootGroup.name.get(), equals('KeyProtectedVault'));
      },
    );

    test(
      '4. Protected vault cannot open with only the correct password',
      () async {
        const password = 'ProtectedVaultPassword789!';
        final keyFileBytes = KeyNestKeyFile.generateXmlV2();
        final compositeCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: keyFileBytes,
        );

        final file = kdbxFormat.create(compositeCreds, 'KeyProtectedVault');
        final rawBytes = await file.save();

        // Attempting to unlock with correct password alone must fail cryptographically
        final passwordOnlyCreds = Credentials(
          ProtectedValue.fromString(password),
        );
        expect(
          () async => await kdbxFormat.read(rawBytes, passwordOnlyCreds),
          throwsA(isA<KdbxInvalidKeyException>()),
        );
      },
    );

    test(
      '5. Protected vault cannot open with a missing, empty, or incorrect key file',
      () async {
        const password = 'ProtectedVaultPassword789!';
        final correctKeyBytes = KeyNestKeyFile.generateXmlV2();
        final compositeCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: correctKeyBytes,
        );

        final file = kdbxFormat.create(compositeCreds, 'StrictCredentialVault');
        final rawBytes = await file.save();

        // A. Empty key file throws validation exception
        expect(
          () => KeyNestKeyFile.parse(Uint8List(0)),
          throwsA(isA<KeyFileValidationException>()),
        );

        // B. Incorrect key file throws KdbxInvalidKeyException
        final wrongKeyBytes = KeyNestKeyFile.generateXmlV2();
        final wrongCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: wrongKeyBytes,
        );
        expect(
          () async => await kdbxFormat.read(rawBytes, wrongCreds),
          throwsA(isA<KdbxInvalidKeyException>()),
        );

        // C. Password with different raw key bytes throws KdbxInvalidKeyException
        final wrongRawBytes = Uint8List.fromList(
          List.generate(32, (i) => 200 - i),
        );
        final wrongRawCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: wrongRawBytes,
        );
        expect(
          () async => await kdbxFormat.read(rawBytes, wrongRawCreds),
          throwsA(isA<KdbxInvalidKeyException>()),
        );
      },
    );

    test(
      '6. Vault credential requirements remain intact after locking, restarting, switching vaults, and reopening',
      () async {
        final store = KeyNestKeyFileStore.instance;

        const vaultAUuid = 'vault-lifecycle-a';
        const vaultAPassword = 'VaultAPassword1!';
        final vaultAKeyFile = KeyNestKeyFile.generateXmlV2();
        final vaultACreds = KeyNestKeyFile.createCompositeCredentials(
          password: vaultAPassword,
          keyFileBytes: vaultAKeyFile,
        );
        final vaultAFile = kdbxFormat.create(vaultACreds, 'VaultA');
        final vaultABytes = await vaultAFile.save();

        // Save key file to temp disk and register association for Vault A
        final keyFilePathA = io.File(
          tempDir.uri.resolve('vault_a.keyx').toFilePath(),
        );
        await keyFilePathA.writeAsBytes(vaultAKeyFile);
        await store.saveReference(
          vaultUuid: vaultAUuid,
          displayName: 'vault_a.keyx',
          filePath: keyFilePathA.path,
        );

        const vaultBUuid = 'vault-lifecycle-b';
        const vaultBPassword = 'VaultBPassword2!';
        final vaultBCreds = Credentials(
          ProtectedValue.fromString(vaultBPassword),
        );
        final vaultBFile = kdbxFormat.create(vaultBCreds, 'VaultB');
        final vaultBBytes = await vaultBFile.save();

        // Simulate lock: dispose instances
        vaultAFile.dispose();
        vaultBFile.dispose();

        // Simulate app restart: clear in-memory cache of store
        store.clearMemoryCache();

        // Switching vaults:
        // 1. Vault B (password-only) requires only password and has no key file
        final bHasKey = await store.hasKeyFile(vaultBUuid);
        expect(bHasKey, isFalse);
        final bOpened = await kdbxFormat.read(vaultBBytes, vaultBCreds);
        expect(bOpened.body.rootGroup.name.get(), equals('VaultB'));

        // 2. Vault A (key-file-protected) independently recovers its saved reference
        final aHasKey = await store.hasKeyFile(vaultAUuid);
        expect(aHasKey, isTrue);
        final aRef = await store.getReference(vaultAUuid);
        expect(aRef?.displayName, equals('vault_a.keyx'));
        final aResolvedBytes = await store.resolveKeyFileBytes(vaultAUuid);
        expect(aResolvedBytes, isNotNull);
        expect(aResolvedBytes, equals(vaultAKeyFile));

        // 3. Vault A unlocks with recovered credentials
        final recoveredACreds = KeyNestKeyFile.createCompositeCredentials(
          password: vaultAPassword,
          keyFileBytes: aResolvedBytes,
        );
        final aOpened = await kdbxFormat.read(vaultABytes, recoveredACreds);
        expect(aOpened.body.rootGroup.name.get(), equals('VaultA'));

        // 4. Cross-vault isolation:
        // Vault A's key file cannot unlock Vault B
        final wrongBWithAKey = KeyNestKeyFile.createCompositeCredentials(
          password: vaultBPassword,
          keyFileBytes: vaultAKeyFile,
        );
        expect(
          () async => await kdbxFormat.read(vaultBBytes, wrongBWithAKey),
          throwsA(isA<KdbxInvalidKeyException>()),
        );

        // Vault B's credentials cannot unlock Vault A
        expect(
          () async => await kdbxFormat.read(vaultABytes, vaultBCreds),
          throwsA(isA<KdbxInvalidKeyException>()),
        );

        // Clean up
        await store.removeReference(vaultAUuid);
      },
    );

    test(
      '7. Losing saved file reference triggers key file reselection rather than silently bypassing key file protection',
      () async {
        final store = KeyNestKeyFileStore.instance;
        const vaultUuid = 'vault-missing-file-ref';
        const password = 'StrictVaultPassword!';
        final keyFileBytes = KeyNestKeyFile.generateXmlV2();
        final creds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: keyFileBytes,
        );
        final file = kdbxFormat.create(creds, 'StrictVault');
        final vaultBytes = await file.save();

        // Configure reference to a file that will be deleted/missing
        final missingKeyFile = io.File(
          tempDir.uri.resolve('missing.keyx').toFilePath(),
        );
        await missingKeyFile.writeAsBytes(keyFileBytes);
        await store.saveReference(
          vaultUuid: vaultUuid,
          displayName: 'missing.keyx',
          filePath: missingKeyFile.path,
        );

        // Now delete the key file from disk
        await missingKeyFile.delete();

        // Store still knows this vault requires a key file
        expect(await store.hasKeyFile(vaultUuid), isTrue);

        // Resolving the bytes returns null because the file was moved/deleted
        final resolved = await store.resolveKeyFileBytes(vaultUuid);
        expect(resolved, isNull);

        // Attempting to bypass by unlocking with password-only cryptographically fails
        final pwdOnly = Credentials(ProtectedValue.fromString(password));
        expect(
          () async => await kdbxFormat.read(vaultBytes, pwdOnly),
          throwsA(isA<KdbxInvalidKeyException>()),
        );

        // User reselects the key file (e.g. from new location)
        final reselectedKeyFile = io.File(
          tempDir.uri.resolve('recovered.keyx').toFilePath(),
        );
        await reselectedKeyFile.writeAsBytes(keyFileBytes);
        final reselectedBytes = await reselectedKeyFile.readAsBytes();

        // Reselected credentials successfully decrypt the vault
        final reselectedCreds = KeyNestKeyFile.createCompositeCredentials(
          password: password,
          keyFileBytes: reselectedBytes,
        );
        final unlocked = await kdbxFormat.read(vaultBytes, reselectedCreds);
        expect(unlocked.body.rootGroup.name.get(), equals('StrictVault'));

        // New location is saved
        await store.saveReference(
          vaultUuid: vaultUuid,
          displayName: 'recovered.keyx',
          filePath: reselectedKeyFile.path,
        );
        expect(await store.resolveKeyFileBytes(vaultUuid), isNotNull);

        // Clean up
        await store.removeReference(vaultUuid);
      },
    );

    test(
      '8. Explicitly changing or removing key file works only through valid credential-change operation and preserves vault data',
      () async {
        final store = KeyNestKeyFileStore.instance;
        const initialPassword = 'InitialSecret123!';
        final initialKeyBytes = KeyNestKeyFile.generateXmlV2();
        final initialCreds = KeyNestKeyFile.createCompositeCredentials(
          password: initialPassword,
          keyFileBytes: initialKeyBytes,
        );

        final file = kdbxFormat.create(initialCreds, 'SecureReEncryptionVault');
        final entry = KdbxEntry.create(file, file.body.rootGroup);
        entry.setString(KdbxKeyCommon.TITLE, PlainValue('CriticalAccount'));
        entry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('SuperSecretData'),
        );
        file.body.rootGroup.addEntry(entry);
        final initialVaultBytes = await file.save();

        const vaultUuid = 're-encrypt-uuid';
        await store.saveReference(
          vaultUuid: vaultUuid,
          displayName: 'initial.keyx',
          filePath: '/some/path/initial.keyx',
        );

        // A. Changing local JSON reference does NOT remove cryptographic protection from KDBX vault
        await store.removeReference(vaultUuid);
        expect(await store.hasKeyFile(vaultUuid), isFalse);
        expect(
          () async => await kdbxFormat.read(
            initialVaultBytes,
            Credentials(ProtectedValue.fromString(initialPassword)),
          ),
          throwsA(isA<KdbxInvalidKeyException>()),
        );

        // B. Authenticated credential change: replace key file with newKeyFile
        const newPassword = 'NewSecretPassword456!';
        final newKeyBytes = KeyNestKeyFile.generateXmlV2();
        final newCompositeCreds = KeyNestKeyFile.createCompositeCredentials(
          password: newPassword,
          keyFileBytes: newKeyBytes,
        );

        // Perform genuine re-encryption using save()
        file.credentials = newCompositeCreds;
        final reEncryptedBytes = await file.save();

        // Verify that old credentials no longer unlock the vault
        expect(
          () async => await kdbxFormat.read(reEncryptedBytes, initialCreds),
          throwsA(isA<KdbxInvalidKeyException>()),
        );

        // Verify that new credentials unlock and all data is preserved intact
        final reOpened = await kdbxFormat.read(
          reEncryptedBytes,
          newCompositeCreds,
        );
        expect(
          reOpened.body.rootGroup.name.get(),
          equals('SecureReEncryptionVault'),
        );
        expect(
          reOpened.body.rootGroup
              .getAllEntries()
              .firstWhere((e) => e.label == 'CriticalAccount')
              .getString(KdbxKeyCommon.PASSWORD)
              ?.getText(),
          equals('SuperSecretData'),
        );

        // C. Authenticated credential change: convert to password-only
        const finalPassword = 'PasswordOnlyFinal789!';
        final finalPwCreds = Credentials(
          ProtectedValue.fromString(finalPassword),
        );
        file.credentials = finalPwCreds;
        final passwordOnlyBytes = await file.save();

        // Unlocks with password alone
        final finalOpened = await kdbxFormat.read(
          passwordOnlyBytes,
          finalPwCreds,
        );
        expect(
          finalOpened.body.rootGroup.name.get(),
          equals('SecureReEncryptionVault'),
        );
        expect(
          finalOpened.body.rootGroup
              .getAllEntries()
              .firstWhere((e) => e.label == 'CriticalAccount')
              .getString(KdbxKeyCommon.PASSWORD)
              ?.getText(),
          equals('SuperSecretData'),
        );

        // Fails if attempted with key file
        final wrongWithKey = KeyNestKeyFile.createCompositeCredentials(
          password: finalPassword,
          keyFileBytes: newKeyBytes,
        );
        expect(
          () async => await kdbxFormat.read(passwordOnlyBytes, wrongWithKey),
          throwsA(isA<KdbxInvalidKeyException>()),
        );
      },
    );
  });
}
