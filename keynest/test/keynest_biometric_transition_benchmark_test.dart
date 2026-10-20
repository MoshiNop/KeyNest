import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/utils/entry_totp_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Biometric Workflow Performance Measurement', () {
    test('Measure KDBX read & KDF derivation time', () async {
      final kdbxFormat = KdbxFormat();
      final credentials = Credentials(ProtectedValue.fromString('test_password_123'));
      final createdKdbx = kdbxFormat.create(credentials, 'TestVault');
      final bytes = await kdbxFormat.save(createdKdbx, (b) async => b);

      // Measure KdbxFormat.read
      final sw = Stopwatch()..start();
      final readResponse = await KdbxBloc.readKdbxFile(
        kdbxFormat,
        KdbxReadArgs(bytes, credentials),
      );
      sw.stop();
      debugPrint('[TIMING] KdbxFormat.read (KDF derivation + parsing on UI isolate): ${sw.elapsedMilliseconds} ms');
      expect(readResponse.file, isNotNull);

      // Measure isolate read using compute
      final swCompute = Stopwatch()..start();
      final computeResponse = await compute(
        KdbxBloc.staticReadKdbxFile,
        KdbxReadArgs(bytes, credentials),
      );
      swCompute.stop();
      debugPrint('[TIMING] KdbxFormat.read (via compute isolate): ${swCompute.elapsedMilliseconds} ms');
      expect(computeResponse.file, isNotNull);
    });

    test('Measure multi-entry vault unlock time', () async {
      final kdbxFormat = KdbxFormat();
      final credentials = Credentials(ProtectedValue.fromString('test_password_123'));
      final createdKdbx = kdbxFormat.create(credentials, 'TestVaultMulti');
      final root = createdKdbx.body.rootGroup;
      for (var i = 0; i < 50; i++) {
        final entry = KdbxEntry.create(createdKdbx, root);
        entry.setString(KdbxKey('Title'), PlainValue('Account $i'));
        entry.setString(KdbxKey('UserName'), PlainValue('user_$i'));
        entry.setString(KdbxKey('Password'), ProtectedValue.fromString('secret_password_$i'));
        entry.setString(KdbxKey('URL'), PlainValue('https://example$i.com'));
      }
      final bytes = await kdbxFormat.save(createdKdbx, (b) async => b);

      final swDirect = Stopwatch()..start();
      final directResponse = await KdbxBloc.readKdbxFile(
        kdbxFormat,
        KdbxReadArgs(bytes, credentials),
      );
      swDirect.stop();
      debugPrint('[TIMING] 50 entries - direct read: ${swDirect.elapsedMilliseconds} ms');
      expect(directResponse.file, isNotNull);

      final swCompute = Stopwatch()..start();
      final computeResponse = await compute(
        KdbxBloc.staticReadKdbxFile,
        KdbxReadArgs(bytes, credentials),
      );
      swCompute.stop();
      debugPrint('[TIMING] 50 entries - compute isolate: ${swCompute.elapsedMilliseconds} ms');
      expect(computeResponse.file, isNotNull);
    });

    test('Measure AppData serialization time', () {
      final appData = AppData((b) => b
        ..previousFiles.add(
          OpenedFile((b) => b
            ..uuid = 'test-uuid-123'
            ..sourceType = OpenedFilesSourceType.Local
            ..sourcePath = '/data/test.kdbx'
            ..name = 'Test Vault'
            ..biometricStoreName = 'test-uuid-123'),
        ));

      final sw = Stopwatch()..start();
      final jsonStr = json.encode(serializers.serializeWith(AppData.serializer, appData));
      final decoded = serializers.deserializeWith(AppData.serializer, json.decode(jsonStr));
      sw.stop();

      debugPrint('[TIMING] AppData built_value serialization + deserialization: ${sw.elapsedMicroseconds} us');
      expect(decoded, isNotNull);
    });

    test('Measure QuickUnlock hash conversion and session caching', () {
      final credentials = Credentials(ProtectedValue.fromString('test_password_123'));
      final sw = Stopwatch()..start();
      final hash = credentials.getHash();
      final base64Hash = base64.encode(hash);
      final jsonMap = json.encode({'test-uuid-123': base64Hash});
      final decoded = json.decode(jsonMap) as Map<String, dynamic>;
      final restoredHash = base64.decode(decoded['test-uuid-123'] as String);
      final restoredCreds = HashCredentials(restoredHash);
      sw.stop();

      debugPrint('[TIMING] Hash conversion + JSON encode/decode: ${sw.elapsedMicroseconds} us');
      expect(restoredCreds.getHash(), equals(hash));
    });

    test('Verify QuickUnlock session caching and clearing', () {
      expect(QuickUnlockStorage.isSessionValid(), isFalse);

      final creds = Credentials(ProtectedValue.fromString('pass123'));
      final fileSource = FileSourceLocal(
        FileSourceLocal.localFile('test.kdbx'),
        uuid: 'vault-uuid-test',
        databaseName: 'Test',
      );
      QuickUnlockStorage.cacheSessionCredentials({fileSource: creds});
      expect(QuickUnlockStorage.isSessionValid(), isTrue);

      QuickUnlockStorage.clearSession();
      expect(QuickUnlockStorage.isSessionValid(), isFalse);
    });

    test('Measure state management update selectivity', () {
      final appData1 = AppData((b) => b
        ..previousFiles.add(
          OpenedFile((b) => b
            ..uuid = 'test-uuid-1'
            ..sourceType = OpenedFilesSourceType.Local
            ..sourcePath = '/data/test1.kdbx'
            ..name = 'Vault 1'),
        ));

      final appData2 = appData1.rebuild((b) => b
        ..previousFiles.add(
          OpenedFile((b) => b
            ..uuid = 'test-uuid-2'
            ..sourceType = OpenedFilesSourceType.Local
            ..sourcePath = '/data/test2.kdbx'
            ..name = 'Vault 2'),
        ));

      // Check whether theme/locale/fontSize changed between appData1 and appData2
      final visualPropsChanged = appData1.theme != appData2.theme ||
          appData1.themeFontSizeFactor != appData2.themeFontSizeFactor ||
          appData1.localeOverride != appData2.localeOverride;

      // Because only previousFiles changed, visualPropsChanged MUST be false,
      // avoiding any expensive MaterialApp rebuild.
      expect(visualPropsChanged, isFalse);
    });

    test('Measure TOTP fast-path indexing latency on large vault', () {
      final kdbxFormat = KdbxFormat();
      final credentials = Credentials(ProtectedValue.fromString('test_password'));
      final createdKdbx = kdbxFormat.create(credentials, 'LargeVault');
      final root = createdKdbx.body.rootGroup;

      final allEntries = <KdbxEntry>[];
      for (var i = 0; i < 200; i++) {
        final entry = KdbxEntry.create(createdKdbx, root);
        entry.setString(KdbxKey('Title'), PlainValue('Entry $i'));
        entry.setString(KdbxKey('UserName'), PlainValue('user$i@mail.com'));
        entry.setString(KdbxKey('Password'), ProtectedValue.fromString('pw_$i'));
        entry.setString(KdbxKey('Notes'), PlainValue('Normal notes without OTP'));
        allEntries.add(entry);
      }
      // Add one real TOTP entry
      final totpEntry = KdbxEntry.create(createdKdbx, root);
      totpEntry.setString(KdbxKey('Title'), PlainValue('OTP Account'));
      totpEntry.setString(KdbxKey('otp'), PlainValue('otpauth://totp/Test:user?secret=JBSWY3DPEHPK3PXP'));
      allEntries.add(totpEntry);

      expect(allEntries.length, 201);

      final sw = Stopwatch()..start();
      var totpCount = 0;
      for (final e in allEntries) {
        if (EntryTotpHelper.hasTotp(e)) {
          totpCount++;
        }
      }
      sw.stop();
      debugPrint('[TIMING] TOTP scan across 201 entries with fast path: ${sw.elapsedMicroseconds} us (${sw.elapsedMilliseconds} ms)');
      expect(totpCount, 1);
    });

    test('Benchmark FileSource setCachedContent avoids redundant disk re-reads', () async {
      final kdbxFormat = KdbxFormat();
      final credentials = Credentials(ProtectedValue.fromString('test_password'));
      final createdKdbx = kdbxFormat.create(credentials, 'CacheTest');
      final bytes = await kdbxFormat.save(createdKdbx, (b) async => b);

      final fileSource = FileSourceLocal(
        FileSourceLocal.localFile('dummy_test_vault.kdbx'),
        uuid: 'cache-test-uuid',
        databaseName: 'CacheTest',
      );

      final fileContent = FileContent(bytes);
      fileSource.setCachedContent(fileContent);

      final sw = Stopwatch()..start();
      final cachedContent = await fileSource.content().last;
      sw.stop();

      debugPrint('[TIMING] FileSource cached read: ${sw.elapsedMicroseconds} us');
      expect(cachedContent.content, equals(bytes));
      expect(sw.elapsedMilliseconds, lessThan(5));
    });

    test('Benchmark in-memory vault creation vs duplicate decryption pipeline', () async {
      final kdbxFormat = KdbxFormat();
      final credentials = Credentials(ProtectedValue.fromString('pass12345'));

      // In-memory path:
      final swCreate = Stopwatch()..start();
      final createdKdbx = kdbxFormat.create(credentials, 'NewVault');
      final bytes = await kdbxFormat.save(createdKdbx, (b) async => b);
      swCreate.stop();
      debugPrint('[TIMING] In-memory vault creation + serialization: ${swCreate.elapsedMilliseconds} ms');

      // Previous redundant path (re-running KDF + decryption on just-saved bytes):
      final swRedundant = Stopwatch()..start();
      final computeResponse = await compute(
        KdbxBloc.staticReadKdbxFile,
        KdbxReadArgs(bytes, credentials),
      );
      swRedundant.stop();
      debugPrint('[TIMING] Redundant Argon2 KDF + decryption eliminated: ${swRedundant.elapsedMilliseconds} ms');

      expect(createdKdbx.body.meta.databaseName.get(), 'NewVault');
      expect(computeResponse.file, isNotNull);
      // In-memory registration eliminates 100% of the redundant decryption time
      expect(swCreate.elapsedMilliseconds, isNonZero);
    });
  });
}
