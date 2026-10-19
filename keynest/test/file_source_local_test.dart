import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory testTempDir;

  setUpAll(() {
    testTempDir = io.Directory.systemTemp.createTempSync('keynest_test_temp_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async {
            if (methodCall.method == 'getTemporaryDirectory') {
              return testTempDir.path;
            }
            return null;
          },
        );
  });

  tearDownAll(() {
    try {
      testTempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('FileSourceLocal.createFileInNewTempDirectory Tests', () {
    test(
      'Problem 1: Short filename <= 30 chars is preserved without unnecessary modification',
      () async {
        const shortName = 'PersonalVault.kdbx'; // 18 chars
        await FileSourceLocal.createFileInNewTempDirectory(
          shortName,
          (tempFile) async {
            expect(tempFile.basename, equals(shortName));
            expect(tempFile.basename.endsWith('.kdbx'), isTrue);
            expect(tempFile.basename.length, equals(18));
          },
        );
      },
    );

    test(
      'Problem 1: Long filename (>30 chars) shortens name before extension and preserves .kdbx',
      () async {
        const longName = 'MyVeryLongSecureVaultName2026.kdbx'; // 34 chars
        await FileSourceLocal.createFileInNewTempDirectory(
          longName,
          (tempFile) async {
            expect(tempFile.basename.endsWith('.kdbx'), isTrue);
            expect(tempFile.basename.length, equals(30));
            // 30 - 5 = 25 chars of name
            expect(tempFile.basename, equals('MyVeryLongSecureVaultName.kdbx'));
          },
        );
      },
    );

    test(
      'Problem 1: Long filename without extension appends .kdbx and limits to 30 chars',
      () async {
        const longNoExt = 'SuperLongVaultNameWithoutExtensionHere'; // 38 chars
        await FileSourceLocal.createFileInNewTempDirectory(
          longNoExt,
          (tempFile) async {
            expect(tempFile.basename.endsWith('.kdbx'), isTrue);
            expect(tempFile.basename.length, equals(30));
            expect(tempFile.basename, equals('SuperLongVaultNameWithout.kdbx'));
          },
        );
      },
    );

    test('Problem 1: Exactly 30 chars filename is preserved as-is', () async {
      const exact30 = 'ExactlyTwentyFiveChars123.kdbx'; // 30 chars
      await FileSourceLocal.createFileInNewTempDirectory(
        exact30,
        (tempFile) async {
          expect(tempFile.basename, equals(exact30));
          expect(tempFile.basename.length, equals(30));
        },
      );
    });

    test(
      'Problem 2: Temporary folder cleanup errors do not throw unhandled async exceptions or crash',
      () async {
        final result = await FileSourceLocal.createFileInNewTempDirectory(
          'TestVault.kdbx',
          (tempFile) async {
            // Write a dummy file
            await tempFile.writeAsString('test-content');
            expect(tempFile.existsSync(), isTrue);

            // Simulate an external process deleting or locking the directory before finally cleanup
            await tempFile.parent.delete(recursive: true);

            return 'saved-success';
          },
        );

        // The callback's successful result is preserved despite tempDir deletion failure in finally
        expect(result, equals('saved-success'));
        // Wait a microtask turn to ensure any unawaited async errors would have propagated
        await Future<void>.delayed(const Duration(milliseconds: 50));
      },
    );

    test(
      'Problem 2: Callback exceptions properly bubble up and are not swallowed',
      () async {
        expect(
          () async => await FileSourceLocal.createFileInNewTempDirectory(
            'FailingVault.kdbx',
            (tempFile) async {
              throw const io.FileSystemException(
                'Vault save failed due to disk error',
              );
            },
          ),
          throwsA(isA<io.FileSystemException>()),
        );
      },
    );
  });
}
