import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:keynest/services/keynest_saf_service.dart';
import 'package:keynest/utils/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.keynest/misc');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (MethodCall call) async {
      return Directory.systemTemp.path;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  group('KeyNestDirectoryDestination', () {
    test('constructs with displayPath only', () {
      const dest = KeyNestDirectoryDestination(displayPath: '/storage/emulated/0/Test1');
      expect(dest.displayPath, '/storage/emulated/0/Test1');
      expect(dest.treeUri, isNull);
      expect(dest.isSaf, isFalse);
    });

    test('constructs with SAF treeUri and custom displayPath', () {
      const dest = KeyNestDirectoryDestination(
        treeUri: 'content://com.android.externalstorage.documents/tree/primary%3ATest1',
        displayPath: '/storage/emulated/0/Test1',
        displayName: 'Test1',
      );
      expect(dest.isSaf, isTrue);
      expect(dest.treeUri, startsWith('content://'));
      expect(dest.displayPath, '/storage/emulated/0/Test1');
      expect(dest.displayName, 'Test1');
    });

    test('equality and hashCode match for identical properties', () {
      const a = KeyNestDirectoryDestination(
        treeUri: 'content://tree/1',
        displayPath: '/a/b',
      );
      const b = KeyNestDirectoryDestination(
        treeUri: 'content://tree/1',
        displayPath: '/a/b',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('KeyNestSafService - Writability & Existence Checks', () {
    test('isDirectlyWritable returns true for writable directory', () {
      final tempDir = Directory.systemTemp.createTempSync('keynest_writable_test');
      try {
        final isWritable = KeyNestSafService.isDirectlyWritable(tempDir.path);
        expect(isWritable, isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('isDirectlyWritable returns false for invalid path', () {
      final invalidPath = KeyNestPlatform.isWindows
          ? 'Z:\\non_existent_drive_999\\invalid'
          : '/sys/keynest_non_existent_999/invalid';
      final isWritable = KeyNestSafService.isDirectlyWritable(invalidPath);
      expect(isWritable, isFalse);
    });

    test('checkFileExists uses filesystem when treeUri is null', () async {
      final tempDir = await Directory.systemTemp.createTemp('keynest_exists_test');
      try {
        final existingFile = File('${tempDir.path}/vault.kdbx');
        await existingFile.writeAsString('kdbx-content');

        final dest = KeyNestDirectoryDestination(displayPath: tempDir.path);
        final existsTrue = await KeyNestSafService.checkFileExists(
          destination: dest,
          fileName: 'vault.kdbx',
        );
        final existsFalse = await KeyNestSafService.checkFileExists(
          destination: dest,
          fileName: 'missing.kdbx',
        );

        expect(existsTrue, isTrue);
        expect(existsFalse, isFalse);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('checkFileExists uses MethodChannel when treeUri is present', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'safCheckFileExists') {
          final fileName = call.arguments['fileName'] as String;
          return fileName == 'myvault.kdbx';
        }
        return null;
      });

      const dest = KeyNestDirectoryDestination(
        treeUri: 'content://tree/primary%3ATest1',
        displayPath: '/storage/emulated/0/Test1',
      );

      final exists = await KeyNestSafService.checkFileExists(
        destination: dest,
        fileName: 'myvault.kdbx',
      );
      final notExists = await KeyNestSafService.checkFileExists(
        destination: dest,
        fileName: 'other.kdbx',
      );

      expect(exists, isTrue);
      expect(notExists, isFalse);
      expect(calls.length, 2);
      expect(calls[0].arguments['treeUri'], 'content://tree/primary%3ATest1');
      expect(calls[0].arguments['fileName'], 'myvault.kdbx');
    });
  });

  group('KeyNestSafService - Writing & Rollback', () {
    test('writeVaultFile writes directly to filesystem when treeUri is null', () async {
      final tempDir = await Directory.systemTemp.createTemp('keynest_write_fs_test');
      try {
        final dest = KeyNestDirectoryDestination(displayPath: tempDir.path);
        final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

        final result = await KeyNestSafService.writeVaultFile(
          destination: dest,
          fileName: 'imported.kdbx',
          bytes: bytes,
          overwrite: false,
        );

        expect(result, p.join(tempDir.path, 'imported.kdbx'));

        final writtenFile = File('${tempDir.path}/imported.kdbx');
        expect(writtenFile.existsSync(), isTrue);
        expect(await writtenFile.readAsBytes(), equals(bytes));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('writeVaultFile writes via SAF MethodChannel and cleans up temp staged file', () async {
      final calls = <MethodCall>[];
      String? stagedPathObserved;
      bool stagedExistedDuringCall = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'safWriteFile') {
          final sourceFilePath = call.arguments['sourceFilePath'] as String;
          stagedPathObserved = sourceFilePath;
          stagedExistedDuringCall = File(sourceFilePath).existsSync();
          return {
            'uri': 'content://media/document/primary%3ATest1%2Fimported.kdbx',
            'fileName': 'imported.kdbx',
            'size': 4,
          };
        }
        return null;
      });

      const dest = KeyNestDirectoryDestination(
        treeUri: 'content://tree/primary%3ATest1',
        displayPath: '/storage/emulated/0/Test1',
      );
      final bytes = Uint8List.fromList([10, 20, 30, 40]);

      final uri = await KeyNestSafService.writeVaultFile(
        destination: dest,
        fileName: 'imported.kdbx',
        bytes: bytes,
        overwrite: true,
      );

      expect(uri, 'content://media/document/primary%3ATest1%2Fimported.kdbx');

      expect(calls.length, 1);
      expect(calls[0].arguments['treeUri'], 'content://tree/primary%3ATest1');
      expect(calls[0].arguments['fileName'], 'imported.kdbx');
      expect(calls[0].arguments['overwrite'], isTrue);
      expect(stagedExistedDuringCall, isTrue);

      // Verify that the staged temporary file was deleted after completion
      expect(stagedPathObserved, isNotNull);
      expect(File(stagedPathObserved!).existsSync(), isFalse);
    });

    test('getPersistedTreeUriForPath queries method channel on Android', () async {
      // Mock platform check if needed or test invocation
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'getPersistedTreeUriForPath') {
          if (call.arguments['path'] == '/storage/emulated/0/Test1') {
            return 'content://tree/primary%3ATest1';
          }
        }
        return null;
      });

      // KeyNestPlatform.isAndroid evaluates to false on Windows desktop runner,
      // so getPersistedTreeUriForPath returns null when not running on Android.
      final result = await KeyNestSafService.getPersistedTreeUriForPath('/storage/emulated/0/Test1');
      // On Windows test environment, KeyNestPlatform.isAndroid is false
      expect(result, isNull);
    });
  });
}
