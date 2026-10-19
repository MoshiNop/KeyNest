// ignore_for_file: implementation_imports, invalid_use_of_visible_for_testing_member, invalid_use_of_internal_member

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_auth.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_client.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_engine.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';

void main() {
  group('Google Drive Desktop PKCE Flow Tests', () {
    test('PkceSession generates valid 64-char verifier and S256 challenge', () {
      final session = GooglePkceSession.create(
        clientId: 'test_client_id_123.apps.googleusercontent.com',
        port: 8085,
      );

      expect(session.codeVerifier.length, 64);
      expect(session.codeChallenge.isNotEmpty, true);
      expect(session.state.isNotEmpty, true);
      expect(session.redirectUri, 'http://127.0.0.1:8085');

      final authUri = session.authorizeUrl;
      expect(authUri.host, 'accounts.google.com');
      expect(authUri.path, '/o/oauth2/v2/auth');
      expect(
        authUri.queryParameters['client_id'],
        'test_client_id_123.apps.googleusercontent.com',
      );
      expect(authUri.queryParameters['response_type'], 'code');
      expect(authUri.queryParameters['access_type'], 'offline');
      expect(authUri.queryParameters['prompt'], 'consent');
      expect(authUri.queryParameters['code_challenge_method'], 'S256');
      expect(authUri.queryParameters['code_challenge'], session.codeChallenge);
      expect(
        authUri.queryParameters['scope'],
        contains(kGoogleDriveFileScope),
      );
      expect(
        authUri.queryParameters['scope'],
        contains(kGoogleDriveAppDataScope),
      );
      expect(authUri.queryParameters['redirect_uri'], 'http://127.0.0.1:8085');
      expect(authUri.queryParameters['state'], session.state);
    });
  });

  group('Google Drive Client & Token Refresh Tests', () {
    test('Client queries appDataFolder with trashed=false', () async {
      late Uri capturedUri;
      final mockHttp = MockClient((request) async {
        capturedUri = request.url;
        return http.Response(
          json.encode({
            'files': [
              {
                'id': 'gdrive_file_id_abc',
                'name': 'KeyNest.kdbx',
                'md5Checksum': 'e10adc3949ba59abbe56e057f20f883e',
                'version': '1',
                'modifiedTime': '2026-10-07T12:00:00.000Z',
                'size': '2048',
              },
            ],
          }),
          200,
        );
      });

      final mockTokenSource = _MockGoogleTokenSource('valid_test_token');
      final client = GoogleDriveClient(
        tokenSource: mockTokenSource,
        httpClient: mockHttp,
      );

      final files = await client.findFilesInAppDataFolder('KeyNest.kdbx');
      expect(files.length, 1);
      expect(files.first.id, 'gdrive_file_id_abc');
      expect(files.first.md5Checksum, 'e10adc3949ba59abbe56e057f20f883e');
      expect(files.first.version, 1);

      expect(capturedUri.queryParameters['spaces'], 'appDataFolder');
      expect(
        capturedUri.queryParameters['q'],
        "name = 'KeyNest.kdbx' and trashed = false",
      );
    });

    test(
      'Client transparently refreshes expired access token on 401 and retries',
      () async {
        int requestCount = 0;
        final mockTokenSource = _MockGoogleTokenSource('initial_expired_token')
          ..nextRefreshedToken = 'fresh_refreshed_token';

        final mockHttp = MockClient((request) async {
          requestCount++;
          final authHeader =
              request.headers['Authorization'] ??
              request.headers['authorization'];
          if (authHeader == 'Bearer initial_expired_token') {
            return http.Response(
              '{"error": {"code": 401, "message": "Invalid Credentials"}}',
              401,
            );
          }
          if (authHeader == 'Bearer fresh_refreshed_token') {
            return http.Response(
              json.encode({
                'id': 'file_456',
                'name': 'Vault.kdbx',
                'md5Checksum': 'c4ca4238a0b923820dcc509a6f75849b',
                'version': '2',
              }),
              200,
            );
          }
          return http.Response('Unauthorized', 401);
        });

        final client = GoogleDriveClient(
          tokenSource: mockTokenSource,
          httpClient: mockHttp,
        );

        final meta = await client.getFileMetadata('file_456');
        expect(meta, isNotNull);
        expect(meta!.id, 'file_456');
        expect(meta.md5Checksum, 'c4ca4238a0b923820dcc509a6f75849b');
        expect(mockTokenSource.refreshCount, 1);
        expect(requestCount, 2); // First failed 401, second succeeded 200
      },
    );

    test(
      'Client handles 403 quotaExceeded error with GoogleDriveQuotaException',
      () async {
        final mockTokenSource = _MockGoogleTokenSource('test_token');
        final mockHttp = MockClient((request) async {
          return http.Response(
            json.encode({
              'error': {
                'code': 403,
                'message': 'The user\'s Drive storage quota has been exceeded.',
                'errors': [
                  {'reason': 'quotaExceeded'},
                ],
              },
            }),
            403,
          );
        });

        final client = GoogleDriveClient(
          tokenSource: mockTokenSource,
          httpClient: mockHttp,
        );

        expect(
          () => client.createInitialVault(
            vaultFilename: 'test.kdbx',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
          throwsA(isA<GoogleDriveQuotaException>()),
        );
      },
    );

    test(
      'Duplicate file resolution picks newest file by modifiedTime or version',
      () async {
        final mockHttp = MockClient((request) async {
          return http.Response(
            json.encode({
              'files': [
                {
                  'id': 'file_old',
                  'name': 'KeyNest.kdbx',
                  'md5Checksum': '111',
                  'version': '1',
                  'modifiedTime': '2026-10-05T10:00:00.000Z',
                },
                {
                  'id': 'file_new',
                  'name': 'KeyNest.kdbx',
                  'md5Checksum': '222',
                  'version': '5',
                  'modifiedTime': '2026-10-07T10:00:00.000Z',
                },
              ],
            }),
            200,
          );
        });

        final mockTokenSource = _MockGoogleTokenSource('token');
        final client = GoogleDriveClient(
          tokenSource: mockTokenSource,
          httpClient: mockHttp,
        );

        final files = await client.findFilesInAppDataFolder('KeyNest.kdbx');
        expect(files.length, 2);
        expect(files.first.id, 'file_new'); // Sorted newest first
      },
    );
  });

  group('Google Drive Sync State & Rolling Backups', () {
    late Directory tempDir;
    late GoogleDriveSyncStateStore stateStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('gdrive_state_test_');
      stateStore = GoogleDriveSyncStateStore(
        overrideSyncDir: tempDir,
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Checkpoint and dirty flags update and persist correctly', () async {
      const vaultId = 'test-vault-uuid-123';
      expect(await stateStore.isLocalDirty(vaultId), false);
      expect(await stateStore.getLastSyncedMd5(vaultId), isNull);
      expect(await stateStore.getDriveFileId(vaultId), isNull);

      await stateStore.setDriveFileId(vaultId, 'drive_file_id_999');
      await stateStore.setSyncCheckpoint(
        vaultId: vaultId,
        md5: 'md5_abc',
        version: 3,
      );
      await stateStore.markLocalDirty(vaultId);

      expect(await stateStore.getDriveFileId(vaultId), 'drive_file_id_999');
      expect(await stateStore.getLastSyncedMd5(vaultId), 'md5_abc');
      expect(await stateStore.getLastSyncedVersion(vaultId), 3);
      expect(await stateStore.isLocalDirty(vaultId), true);

      await stateStore.markLocalClean(vaultId);
      expect(await stateStore.isLocalDirty(vaultId), false);
    });

    test('Rolling backups retains only last 5 files', () async {
      const vaultId = 'test-vault-uuid-123';
      final dummyBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

      for (int i = 0; i < 7; i++) {
        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: dummyBytes,
        );
        // Small delay to ensure distinct timestamps
        await Future.delayed(const Duration(milliseconds: 30));
      }

      final backups = await stateStore.listBackups(vaultId);
      expect(backups.length, 5);
    });

    test(
      'ClearSyncState removes metadata and base copies but leaves backups',
      () async {
        const vaultId = 'vault_abc';
        await stateStore.setDriveFileId(vaultId, 'file_123');
        await stateStore.setBaseCopy(vaultId, Uint8List.fromList([1, 2, 3]));
        await stateStore.createBackup(
          vaultId: vaultId,
          currentVaultBytes: Uint8List.fromList([4, 5, 6]),
        );

        expect(await stateStore.hasBaseCopy(vaultId), true);
        expect(await stateStore.getDriveFileId(vaultId), 'file_123');

        await stateStore.clearSyncState();

        expect(await stateStore.getDriveFileId(vaultId), isNull);
        expect(await stateStore.hasBaseCopy(vaultId), false);
      },
    );
  });

  group('Google Drive Sync Decision Table & Merging', () {
    late Directory tempDir;
    late GoogleDriveSyncStateStore stateStore;
    late KdbxFormat kdbxFormat;
    late Credentials testCredentials;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('gdrive_engine_test_');
      stateStore = GoogleDriveSyncStateStore(
        overrideSyncDir: tempDir,
      );
      await stateStore.setKeyNestFolderId('folder_keynest_123');
      kdbxFormat = KdbxFormat();
      testCredentials = Credentials(ProtectedValue.fromString('password123'));
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    KdbxFile createTestFile(String name) {
      return kdbxFormat.create(testCredentials, name);
    }

    KdbxEntry addEntry(
      KdbxFile file,
      String title,
      String user,
      String pass,
    ) {
      final entry = KdbxEntry.create(file, file.body.rootGroup);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue(title));
      entry.setString(KdbxKeyCommon.USER_NAME, PlainValue(user));
      entry.setString(KdbxKeyCommon.PASSWORD, ProtectedValue.fromString(pass));
      file.body.rootGroup.addEntry(entry);
      return entry;
    }

    test('Case 0: Remote does not exist -> Initial upload', () async {
      final localKdbx = createTestFile('My Vault');
      addEntry(localKdbx, 'GitHub', 'dev', 'pass1');
      final localBytes = await localKdbx.save();

      Uint8List? uploadedBytes;
      final mockHttp = MockClient((request) async {
        if (request.url.path == '/drive/v3/files/folder_keynest_123') {
          return http.Response(
            json.encode({
              'id': 'folder_keynest_123',
              'name': 'KeyNest',
              'mimeType': 'application/vnd.google-apps.folder',
              'trashed': false,
            }),
            200,
          );
        }
        if (request.url.path == '/drive/v3/files') {
          // findFilesInFolder or findFilesInAppDataFolder
          return http.Response(json.encode({'files': []}), 200);
        }
        if (request.url.path.contains('/upload/drive/v3/files')) {
          uploadedBytes = request.bodyBytes;
          return http.Response(
            json.encode({
              'id': 'newly_created_id',
              'name': 'test.kdbx',
              'md5Checksum': GoogleDriveClient.computeMd5(localBytes),
              'version': '1',
              'parents': ['folder_keynest_123'],
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final mockTokenSource = _MockGoogleTokenSource('token');
      final client = GoogleDriveClient(
        tokenSource: mockTokenSource,
        httpClient: mockHttp,
      );
      final engine = GoogleDriveSyncEngine(
        client: client,
        stateStore: stateStore,
      );

      final result = await engine.syncVault(
        vaultId: 'vault_case_0',
        vaultFilename: 'test.kdbx',
        getLocalBytes: () async => localBytes,
        saveLocalBytes: (bytes) async {},
        unlockedLocalFile: localKdbx,
        credentials: testCredentials,
      );

      expect(result.status, GoogleDriveSyncStatus.uploaded);
      expect(result.fileId, 'newly_created_id');
      expect(uploadedBytes, isNotNull);
      expect(
        await stateStore.getDriveFileId('vault_case_0'),
        'newly_created_id',
      );
      expect(await stateStore.hasBaseCopy('vault_case_0'), true);
      expect(await stateStore.isVaultMigrated('vault_case_0'), true);
    });

    test('Case 3: Remote unchanged, local clean -> Up to date', () async {
      final localKdbx = createTestFile('My Vault');
      final localBytes = await localKdbx.save();
      final localMd5 = GoogleDriveClient.computeMd5(localBytes);

      const vaultId = 'vault_case_3';
      await stateStore.setDriveFileId(vaultId, 'existing_file_id');
      await stateStore.setVaultMigrated(vaultId, true);
      await stateStore.setSyncCheckpoint(
        vaultId: vaultId,
        md5: localMd5,
        version: 5,
      );
      await stateStore.setBaseCopy(vaultId, localBytes);

      final mockHttp = MockClient((request) async {
        if (request.url.path == '/drive/v3/files/folder_keynest_123') {
          return http.Response(
            json.encode({
              'id': 'folder_keynest_123',
              'name': 'KeyNest',
              'mimeType': 'application/vnd.google-apps.folder',
              'trashed': false,
            }),
            200,
          );
        }
        if (request.url.path == '/drive/v3/files/existing_file_id') {
          return http.Response(
            json.encode({
              'id': 'existing_file_id',
              'name': 'test.kdbx',
              'md5Checksum': localMd5,
              'version': '5',
              'parents': ['folder_keynest_123'],
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final mockTokenSource = _MockGoogleTokenSource('token');
      final client = GoogleDriveClient(
        tokenSource: mockTokenSource,
        httpClient: mockHttp,
      );
      final engine = GoogleDriveSyncEngine(
        client: client,
        stateStore: stateStore,
      );

      final result = await engine.syncVault(
        vaultId: vaultId,
        vaultFilename: 'test.kdbx',
        getLocalBytes: () async => localBytes,
        saveLocalBytes: (bytes) async {},
        unlockedLocalFile: localKdbx,
        credentials: testCredentials,
      );

      expect(result.status, GoogleDriveSyncStatus.upToDate);
    });

    test('Case 2: Local clean, remote modified -> Fast download', () async {
      final initialKdbx = createTestFile('My Vault');
      final initialBytes = await initialKdbx.save();
      final initialMd5 = GoogleDriveClient.computeMd5(initialBytes);

      const vaultId = 'vault_case_2';
      await stateStore.setDriveFileId(vaultId, 'file_id_2');
      await stateStore.setVaultMigrated(vaultId, true);
      await stateStore.setSyncCheckpoint(
        vaultId: vaultId,
        md5: initialMd5,
        version: 1,
      );
      await stateStore.setBaseCopy(vaultId, initialBytes);

      // Remote has new entry
      final remoteKdbx = createTestFile('My Vault');
      addEntry(remoteKdbx, 'RemoteEntry', 'remote_user', 'remote_pass');
      final remoteBytes = await remoteKdbx.save();
      final remoteMd5 = GoogleDriveClient.computeMd5(remoteBytes);

      Uint8List? savedBytes;
      final mockHttp = MockClient((request) async {
        if (request.url.path == '/drive/v3/files/folder_keynest_123') {
          return http.Response(
            json.encode({
              'id': 'folder_keynest_123',
              'name': 'KeyNest',
              'mimeType': 'application/vnd.google-apps.folder',
              'trashed': false,
            }),
            200,
          );
        }
        if (request.url.path == '/drive/v3/files/file_id_2') {
          if (request.url.queryParameters['alt'] == 'media') {
            return http.Response.bytes(remoteBytes, 200);
          }
          return http.Response(
            json.encode({
              'id': 'file_id_2',
              'name': 'test.kdbx',
              'md5Checksum': remoteMd5,
              'version': '2',
              'parents': ['folder_keynest_123'],
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final mockTokenSource = _MockGoogleTokenSource('token');
      final client = GoogleDriveClient(
        tokenSource: mockTokenSource,
        httpClient: mockHttp,
      );
      final engine = GoogleDriveSyncEngine(
        client: client,
        stateStore: stateStore,
      );

      final result = await engine.syncVault(
        vaultId: vaultId,
        vaultFilename: 'test.kdbx',
        getLocalBytes: () async => initialBytes,
        saveLocalBytes: (bytes) async {
          savedBytes = bytes;
        },
        unlockedLocalFile: initialKdbx,
        credentials: testCredentials,
      );

      expect(result.status, GoogleDriveSyncStatus.downloaded);
      expect(savedBytes, isNotNull);
      expect(GoogleDriveClient.computeMd5(savedBytes!), remoteMd5);
      expect(await stateStore.getLastSyncedMd5(vaultId), remoteMd5);
    });

    test('Case 4: Both modified -> In-memory 3-way merge and upload', () async {
      // 1. Common base
      final baseKdbx = createTestFile('Base Vault');
      addEntry(baseKdbx, 'Common', 'user', 'basepass');
      final baseBytes = await baseKdbx.save();
      final baseMd5 = GoogleDriveClient.computeMd5(baseBytes);

      const vaultId = 'vault_case_4';
      await stateStore.setDriveFileId(vaultId, 'conflict_file_id');
      await stateStore.setVaultMigrated(vaultId, true);
      await stateStore.setSyncCheckpoint(
        vaultId: vaultId,
        md5: baseMd5,
        version: 1,
      );
      await stateStore.setBaseCopy(vaultId, baseBytes);

      // 2. Local modifies common entry + adds local entry
      final localKdbx = await kdbxFormat.read(baseBytes, testCredentials);
      final localCommon = localKdbx.body.rootGroup.entries.firstWhere(
        (e) => e.getString(KdbxKeyCommon.TITLE)?.getText() == 'Common',
      );
      localCommon.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString('local_pass_changed'),
      );
      addEntry(localKdbx, 'LocalOnly', 'loc_user', 'loc_pass');
      final localBytes = await localKdbx.save();
      await stateStore.markLocalDirty(vaultId);

      // 3. Remote adds remote entry
      final remoteKdbx = await kdbxFormat.read(baseBytes, testCredentials);
      addEntry(remoteKdbx, 'RemoteOnly', 'rem_user', 'rem_pass');
      final remoteBytes = await remoteKdbx.save();
      final remoteMd5 = GoogleDriveClient.computeMd5(remoteBytes);

      Uint8List? savedLocalBytes;
      Uint8List? uploadedRemoteBytes;

      final mockHttp = MockClient((request) async {
        if (request.url.path == '/drive/v3/files/folder_keynest_123') {
          return http.Response(
            json.encode({
              'id': 'folder_keynest_123',
              'name': 'KeyNest',
              'mimeType': 'application/vnd.google-apps.folder',
              'trashed': false,
            }),
            200,
          );
        }
        if (request.url.path == '/drive/v3/files/conflict_file_id') {
          if (request.url.queryParameters['alt'] == 'media') {
            return http.Response.bytes(remoteBytes, 200);
          }
          return http.Response(
            json.encode({
              'id': 'conflict_file_id',
              'name': 'test.kdbx',
              'md5Checksum': remoteMd5,
              'version': '2',
              'parents': ['folder_keynest_123'],
            }),
            200,
          );
        }
        if (request.url.path.contains(
          '/upload/drive/v3/files/conflict_file_id',
        )) {
          uploadedRemoteBytes = request.bodyBytes;
          final uploadedMd5 = GoogleDriveClient.computeMd5(
            uploadedRemoteBytes!,
          );
          return http.Response(
            json.encode({
              'id': 'conflict_file_id',
              'name': 'test.kdbx',
              'md5Checksum': uploadedMd5,
              'version': '3',
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final mockTokenSource = _MockGoogleTokenSource('token');
      final client = GoogleDriveClient(
        tokenSource: mockTokenSource,
        httpClient: mockHttp,
      );
      final engine = GoogleDriveSyncEngine(
        client: client,
        stateStore: stateStore,
      );

      final result = await engine.syncVault(
        vaultId: vaultId,
        vaultFilename: 'test.kdbx',
        getLocalBytes: () async => localBytes,
        saveLocalBytes: (bytes) async {
          savedLocalBytes = bytes;
        },
        unlockedLocalFile: localKdbx,
        credentials: testCredentials,
      );

      expect(result.status, GoogleDriveSyncStatus.merged);
      expect(savedLocalBytes, isNotNull);
      expect(uploadedRemoteBytes, isNotNull);

      // Validate merged vault contains both LocalOnly and RemoteOnly, plus modified Common
      final mergedKdbx = await kdbxFormat.read(
        savedLocalBytes!,
        testCredentials,
      );
      final titles = mergedKdbx.body.rootGroup.entries
          .map((e) => e.getString(KdbxKeyCommon.TITLE)?.getText())
          .toSet();

      expect(titles.contains('Common'), true);
      expect(titles.contains('LocalOnly'), true);
      expect(titles.contains('RemoteOnly'), true);

      final commonEntry = mergedKdbx.body.rootGroup.entries.firstWhere(
        (e) => e.getString(KdbxKeyCommon.TITLE)?.getText() == 'Common',
      );
      expect(
        commonEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
        'local_pass_changed',
      );
    });

    test('Single-flight locking serializes concurrent sync calls', () async {
      final localKdbx = createTestFile('Lock Test');
      final localBytes = await localKdbx.save();

      await stateStore.setDriveFileId('locked_vault', 'lock_id');
      await stateStore.setVaultMigrated('locked_vault', true);

      int simultaneousCalls = 0;
      int maxSimultaneous = 0;

      final mockHttp = MockClient((request) async {
        simultaneousCalls++;
        if (simultaneousCalls > maxSimultaneous) {
          maxSimultaneous = simultaneousCalls;
        }
        await Future.delayed(const Duration(milliseconds: 50));
        simultaneousCalls--;

        if (request.url.path == '/drive/v3/files/folder_keynest_123') {
          return http.Response(
            json.encode({
              'id': 'folder_keynest_123',
              'name': 'KeyNest',
              'mimeType': 'application/vnd.google-apps.folder',
              'trashed': false,
            }),
            200,
          );
        }
        if (request.url.path == '/drive/v3/files') {
          return http.Response(json.encode({'files': []}), 200);
        }
        return http.Response(
          json.encode({
            'id': 'lock_id',
            'name': 'test.kdbx',
            'md5Checksum': GoogleDriveClient.computeMd5(localBytes),
            'version': '1',
            'parents': ['folder_keynest_123'],
          }),
          200,
        );
      });

      final mockTokenSource = _MockGoogleTokenSource('token');
      final client = GoogleDriveClient(
        tokenSource: mockTokenSource,
        httpClient: mockHttp,
      );
      final engine = GoogleDriveSyncEngine(
        client: client,
        stateStore: stateStore,
      );

      final call1 = engine.syncVault(
        vaultId: 'locked_vault',
        vaultFilename: 'test.kdbx',
        getLocalBytes: () async => localBytes,
        saveLocalBytes: (b) async {},
        unlockedLocalFile: localKdbx,
        credentials: testCredentials,
      );

      final call2 = engine.syncVault(
        vaultId: 'locked_vault',
        vaultFilename: 'test.kdbx',
        getLocalBytes: () async => localBytes,
        saveLocalBytes: (b) async {},
        unlockedLocalFile: localKdbx,
        credentials: testCredentials,
      );

      await Future.wait([call1, call2]);
      expect(maxSimultaneous, 1); // Mutex ensured never > 1 at the same time
    });
  });

  group('Google Drive Visible-Folder Migration Tests', () {
    late Directory tempDir;
    late GoogleDriveSyncStateStore stateStore;
    late KdbxFormat kdbxFormat;
    late Credentials testCredentials;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('gdrive_migration_test_');
      stateStore = GoogleDriveSyncStateStore(
        overrideSyncDir: tempDir,
      );
      kdbxFormat = KdbxFormat();
      testCredentials = Credentials(ProtectedValue.fromString('password123'));
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    KdbxFile createTestFile(String name) {
      return kdbxFormat.create(testCredentials, name);
    }

    test(
      'Folder discovery queries "root" for KeyNest and caches folder ID persistently',
      () async {
        late Uri capturedUri;
        final mockHttp = MockClient((request) async {
          if (request.url.path == '/drive/v3/files' &&
              request.method == 'GET') {
            capturedUri = request.url;
            return http.Response(
              json.encode({
                'files': [
                  {
                    'id': 'discovered_keynest_id',
                    'name': 'KeyNest',
                    'mimeType': 'application/vnd.google-apps.folder',
                    'trashed': false,
                    'parents': ['root'],
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('Not found', 404);
        });

        final mockTokenSource = _MockGoogleTokenSource('token');
        final client = GoogleDriveClient(
          tokenSource: mockTokenSource,
          httpClient: mockHttp,
        );

        final folderId = await client.getOrCreateKeyNestFolder(
          stateStore: stateStore,
        );
        expect(folderId, 'discovered_keynest_id');
        expect(await stateStore.getKeyNestFolderId(), 'discovered_keynest_id');
        expect(capturedUri.queryParameters['q'], contains("'root' in parents"));
        expect(capturedUri.queryParameters['q'], contains("name = 'KeyNest'"));
        expect(
          capturedUri.queryParameters['q'],
          contains("mimeType = 'application/vnd.google-apps.folder'"),
        );
        expect(capturedUri.queryParameters['q'], contains('trashed = false'));
      },
    );

    test(
      'Folder discovery reuses verified cached ID without querying folder search',
      () async {
        await stateStore.setKeyNestFolderId('cached_folder_id');

        bool searched = false;
        final mockHttp = MockClient((request) async {
          if (request.url.path == '/drive/v3/files/cached_folder_id') {
            return http.Response(
              json.encode({
                'id': 'cached_folder_id',
                'name': 'KeyNest',
                'mimeType': 'application/vnd.google-apps.folder',
                'trashed': false,
                'parents': ['root'],
              }),
              200,
            );
          }
          if (request.url.path == '/drive/v3/files') {
            searched = true;
            return http.Response(json.encode({'files': []}), 200);
          }
          return http.Response('Not found', 404);
        });

        final client = GoogleDriveClient(
          tokenSource: _MockGoogleTokenSource('token'),
          httpClient: mockHttp,
        );

        final folderId = await client.getOrCreateKeyNestFolder(
          stateStore: stateStore,
        );
        expect(folderId, 'cached_folder_id');
        expect(searched, isFalse);
      },
    );

    test(
      'Folder discovery invalidates trashed cached folder and creates a fresh one',
      () async {
        await stateStore.setKeyNestFolderId('trashed_folder_id');

        bool searchPerformed = false;
        bool postPerformed = false;
        Map<String, dynamic>? postBody;

        final mockHttp = MockClient((request) async {
          if (request.url.path == '/drive/v3/files/trashed_folder_id') {
            return http.Response(
              json.encode({
                'id': 'trashed_folder_id',
                'name': 'KeyNest',
                'mimeType': 'application/vnd.google-apps.folder',
                'trashed': true,
              }),
              200,
            );
          }
          if (request.url.path == '/drive/v3/files' &&
              request.method == 'GET') {
            searchPerformed = true;
            return http.Response(json.encode({'files': []}), 200);
          }
          if (request.url.path == '/drive/v3/files' &&
              request.method == 'POST') {
            postPerformed = true;
            postBody = json.decode(request.body) as Map<String, dynamic>;
            return http.Response(
              json.encode({
                'id': 'recreated_folder_id',
                'name': 'KeyNest',
                'mimeType': 'application/vnd.google-apps.folder',
                'trashed': false,
                'parents': ['root'],
              }),
              200,
            );
          }
          return http.Response('Not found', 404);
        });

        final client = GoogleDriveClient(
          tokenSource: _MockGoogleTokenSource('token'),
          httpClient: mockHttp,
        );

        final folderId = await client.getOrCreateKeyNestFolder(
          stateStore: stateStore,
        );
        expect(folderId, 'recreated_folder_id');
        expect(searchPerformed, isTrue);
        expect(postPerformed, isTrue);
        expect(postBody?['name'], 'KeyNest');
        expect(postBody?['parents'], ['root']);
        expect(postBody?['mimeType'], 'application/vnd.google-apps.folder');
        expect(await stateStore.getKeyNestFolderId(), 'recreated_folder_id');
      },
    );

    test(
      'Concurrent getOrCreateKeyNestFolder calls are serialized by lock without duplicate creation',
      () async {
        int createPostCount = 0;
        final mockHttp = MockClient((request) async {
          if (request.url.path == '/drive/v3/files/single_created_folder_id') {
            return http.Response(
              json.encode({
                'id': 'single_created_folder_id',
                'name': 'KeyNest',
                'mimeType': 'application/vnd.google-apps.folder',
                'trashed': false,
              }),
              200,
            );
          }
          if (request.url.path == '/drive/v3/files' &&
              request.method == 'GET') {
            return http.Response(json.encode({'files': []}), 200);
          }
          if (request.url.path == '/drive/v3/files' &&
              request.method == 'POST') {
            createPostCount++;
            await Future.delayed(const Duration(milliseconds: 50));
            return http.Response(
              json.encode({
                'id': 'single_created_folder_id',
                'name': 'KeyNest',
                'mimeType': 'application/vnd.google-apps.folder',
                'trashed': false,
                'parents': ['root'],
              }),
              200,
            );
          }
          return http.Response('Not found', 404);
        });

        final client = GoogleDriveClient(
          tokenSource: _MockGoogleTokenSource('token'),
          httpClient: mockHttp,
        );

        final results = await Future.wait([
          client.getOrCreateKeyNestFolder(stateStore: stateStore),
          client.getOrCreateKeyNestFolder(stateStore: stateStore),
        ]);

        expect(results[0], 'single_created_folder_id');
        expect(results[1], 'single_created_folder_id');
        expect(createPostCount, 1);
      },
    );

    test(
      'Initial vault upload sets parents to visible KeyNest folder',
      () async {
        String? uploadedBody;
        final mockHttp = MockClient((request) async {
          if (request.url.path.contains('/upload/drive/v3/files')) {
            uploadedBody = request.body;
            return http.Response(
              json.encode({
                'id': 'new_vault_file_id',
                'name': 'NewVault.kdbx',
                'md5Checksum': '1234567890abcdef',
                'version': '1',
                'parents': ['visible_folder_abc'],
              }),
              200,
            );
          }
          return http.Response('Not found', 404);
        });

        final client = GoogleDriveClient(
          tokenSource: _MockGoogleTokenSource('token'),
          httpClient: mockHttp,
        );

        final meta = await client.createInitialVault(
          vaultFilename: 'NewVault.kdbx',
          bytes: Uint8List.fromList([1, 2, 3, 4]),
          folderId: 'visible_folder_abc',
        );

        expect(meta.id, 'new_vault_file_id');
        expect(uploadedBody, isNotNull);
        expect(uploadedBody, contains('"parents":["visible_folder_abc"]'));
      },
    );

    test(
      'Legacy vault migration: safely copies appDataFolder file to visible folder, creates backup, verifies checksum, updates checkpoints, and preserves legacy file',
      () async {
        final localKdbx = createTestFile('Legacy Migration Test');
        final localBytes = await localKdbx.save();
        final localMd5 = GoogleDriveClient.computeMd5(localBytes);

        const vaultId = 'legacy_vault_id_1';
        const legacyFileId = 'legacy_appdata_123';
        const visibleFolderId = 'keynest_visible_folder';

        await stateStore.setKeyNestFolderId(visibleFolderId);
        await stateStore.setDriveFileId(vaultId, legacyFileId);
        await stateStore.setSyncCheckpoint(
          vaultId: vaultId,
          md5: localMd5,
          version: 2,
        );
        await stateStore.setBaseCopy(vaultId, localBytes);

        bool legacyFileDeleted = false;
        bool copyCalled = false;

        final mockHttp = MockClient((request) async {
          // Verify folder
          if (request.url.path == '/drive/v3/files/$visibleFolderId') {
            return http.Response(
              json.encode({
                'id': visibleFolderId,
                'name': 'KeyNest',
                'mimeType': 'application/vnd.google-apps.folder',
                'trashed': false,
              }),
              200,
            );
          }
          // findFilesInFolder
          if (request.url.path == '/drive/v3/files' &&
              request.method == 'GET') {
            return http.Response(json.encode({'files': []}), 200);
          }
          // Legacy file metadata in appDataFolder
          if (request.url.path == '/drive/v3/files/$legacyFileId' &&
              request.method == 'GET') {
            return http.Response(
              json.encode({
                'id': legacyFileId,
                'name': 'Vault.kdbx',
                'md5Checksum': localMd5,
                'version': '2',
                'parents': ['appDataFolder'],
              }),
              200,
            );
          }
          // Copy to visible folder
          if (request.url.path == '/drive/v3/files/$legacyFileId/copy') {
            copyCalled = true;
            return http.Response(
              json.encode({
                'id': 'migrated_visible_file_id',
                'name': 'Vault.kdbx',
                'md5Checksum': localMd5,
                'version': '3',
                'parents': [visibleFolderId],
              }),
              200,
            );
          }
          // Check for DELETE calls
          if (request.method == 'DELETE') {
            legacyFileDeleted = true;
            return http.Response('', 204);
          }
          return http.Response('Not found: ${request.url.path}', 404);
        });

        final client = GoogleDriveClient(
          tokenSource: _MockGoogleTokenSource('token'),
          httpClient: mockHttp,
        );
        final engine = GoogleDriveSyncEngine(
          client: client,
          stateStore: stateStore,
        );

        final result = await engine.syncVault(
          vaultId: vaultId,
          vaultFilename: 'Vault.kdbx',
          getLocalBytes: () async => localBytes,
          saveLocalBytes: (b) async {},
          unlockedLocalFile: localKdbx,
          credentials: testCredentials,
        );

        expect(result.status, GoogleDriveSyncStatus.migrated);
        expect(result.fileId, 'migrated_visible_file_id');
        expect(copyCalled, isTrue);
        expect(
          legacyFileDeleted,
          isFalse,
          reason:
              'Legacy file in appDataFolder must never be deleted during initial migration',
        );

        // Verify pre-migration backup
        final backups = await stateStore.listBackups(vaultId);
        expect(backups.length, 1);
        expect(backups.first.fileSizeBytes, localBytes.length);

        // Verify stateStore checkpoints and migration mapping
        expect(await stateStore.isVaultMigrated(vaultId), isTrue);
        expect(
          await stateStore.getDriveFileId(vaultId),
          'migrated_visible_file_id',
        );
        expect(await stateStore.getLegacyDriveFileId(vaultId), legacyFileId);
        expect(
          await stateStore.getMigratedFileIdForLegacyId(legacyFileId),
          'migrated_visible_file_id',
        );
        expect(await stateStore.getLastSyncedMd5(vaultId), localMd5);
        expect(await stateStore.getLastSyncedVersion(vaultId), 3);
      },
    );

    test(
      'Resumable/interrupted migration adopts existing file in visible folder without duplicating',
      () async {
        final localKdbx = createTestFile('Resumed Migration Test');
        final localBytes = await localKdbx.save();
        final localMd5 = GoogleDriveClient.computeMd5(localBytes);

        const vaultId = 'resumed_vault_id';
        const visibleFolderId = 'keynest_visible_folder';

        await stateStore.setKeyNestFolderId(visibleFolderId);
        await stateStore.setSyncCheckpoint(
          vaultId: vaultId,
          md5: localMd5,
          version: 5,
        );
        await stateStore.setBaseCopy(vaultId, localBytes);

        bool copyAttempted = false;

        final mockHttp = MockClient((request) async {
          if (request.url.path == '/drive/v3/files/$visibleFolderId') {
            return http.Response(
              json.encode({
                'id': visibleFolderId,
                'name': 'KeyNest',
                'mimeType': 'application/vnd.google-apps.folder',
                'trashed': false,
              }),
              200,
            );
          }
          // findFilesInFolder finds that the file was ALREADY migrated to visible folder
          if (request.url.path == '/drive/v3/files' &&
              request.method == 'GET') {
            return http.Response(
              json.encode({
                'files': [
                  {
                    'id': 'already_migrated_visible_id',
                    'name': 'Vault.kdbx',
                    'md5Checksum': localMd5,
                    'version': '5',
                    'parents': [visibleFolderId],
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path.contains('/copy')) {
            copyAttempted = true;
            return http.Response('Should not copy', 500);
          }
          return http.Response('Not found', 404);
        });

        final client = GoogleDriveClient(
          tokenSource: _MockGoogleTokenSource('token'),
          httpClient: mockHttp,
        );
        final engine = GoogleDriveSyncEngine(
          client: client,
          stateStore: stateStore,
        );

        final result = await engine.syncVault(
          vaultId: vaultId,
          vaultFilename: 'Vault.kdbx',
          getLocalBytes: () async => localBytes,
          saveLocalBytes: (b) async {},
          unlockedLocalFile: localKdbx,
          credentials: testCredentials,
        );

        expect(result.status, GoogleDriveSyncStatus.upToDate);
        expect(copyAttempted, isFalse);
        expect(await stateStore.isVaultMigrated(vaultId), isTrue);
        expect(
          await stateStore.getDriveFileId(vaultId),
          'already_migrated_visible_id',
        );
      },
    );

    test(
      'Stale cache protection during migration: refuses to overwrite newer remote legacy vault',
      () async {
        // 1. Initial base vault
        final baseKdbx = createTestFile('Base Vault');
        final baseBytes = await baseKdbx.save();
        final baseMd5 = GoogleDriveClient.computeMd5(baseBytes);

        // 2. Remote legacy was updated by another device with a new entry
        final remoteKdbx = await kdbxFormat.read(baseBytes, testCredentials);
        final entry = KdbxEntry.create(remoteKdbx, remoteKdbx.body.rootGroup);
        entry.setString(KdbxKeyCommon.TITLE, PlainValue('RemoteNewEntry'));
        remoteKdbx.body.rootGroup.addEntry(entry);
        final remoteBytes = await remoteKdbx.save();
        final remoteMd5 = GoogleDriveClient.computeMd5(remoteBytes);

        const vaultId = 'stale_cache_vault_id';
        const legacyFileId = 'remote_legacy_file_id';
        const visibleFolderId = 'keynest_visible_folder';

        await stateStore.setKeyNestFolderId(visibleFolderId);
        await stateStore.setDriveFileId(vaultId, legacyFileId);
        // Local checkpoint matches old baseMd5 (clean, not dirty, but remote has newer changes)
        await stateStore.setSyncCheckpoint(
          vaultId: vaultId,
          md5: baseMd5,
          version: 1,
        );
        await stateStore.setBaseCopy(vaultId, baseBytes);

        Uint8List? localSavedBytes;

        final mockHttp = MockClient((request) async {
          if (request.url.path == '/drive/v3/files/$visibleFolderId') {
            return http.Response(
              json.encode({
                'id': visibleFolderId,
                'name': 'KeyNest',
                'mimeType': 'application/vnd.google-apps.folder',
                'trashed': false,
              }),
              200,
            );
          }
          if (request.url.path == '/drive/v3/files' &&
              request.method == 'GET') {
            return http.Response(json.encode({'files': []}), 200);
          }
          if (request.url.path == '/drive/v3/files/$legacyFileId' &&
              request.method == 'GET') {
            if (request.url.queryParameters['alt'] == 'media') {
              return http.Response.bytes(remoteBytes, 200);
            }
            return http.Response(
              json.encode({
                'id': legacyFileId,
                'name': 'Vault.kdbx',
                'md5Checksum': remoteMd5,
                'version': '3',
                'parents': ['appDataFolder'],
              }),
              200,
            );
          }
          if (request.url.path == '/drive/v3/files/$legacyFileId/copy') {
            return http.Response(
              json.encode({
                'id': 'migrated_visible_id',
                'name': 'Vault.kdbx',
                'md5Checksum': remoteMd5,
                'version': '4',
                'parents': [visibleFolderId],
              }),
              200,
            );
          }
          if (request.url.path.contains(
            '/upload/drive/v3/files/migrated_visible_id',
          )) {
            return http.Response(
              json.encode({
                'id': 'migrated_visible_id',
                'name': 'Vault.kdbx',
                'md5Checksum': remoteMd5,
                'version': '4',
                'parents': [visibleFolderId],
              }),
              200,
            );
          }
          return http.Response('Not found: ${request.url.path}', 404);
        });

        final client = GoogleDriveClient(
          tokenSource: _MockGoogleTokenSource('token'),
          httpClient: mockHttp,
        );
        final engine = GoogleDriveSyncEngine(
          client: client,
          stateStore: stateStore,
        );

        final result = await engine.syncVault(
          vaultId: vaultId,
          vaultFilename: 'Vault.kdbx',
          getLocalBytes: () async => baseBytes, // Stale local bytes
          saveLocalBytes: (bytes) async {
            localSavedBytes = bytes;
          },
          unlockedLocalFile: baseKdbx,
          credentials: testCredentials,
        );

        expect(result.status, GoogleDriveSyncStatus.migrated);
        expect(localSavedBytes, isNotNull);
        expect(
          GoogleDriveClient.computeMd5(localSavedBytes!),
          remoteMd5,
          reason:
              'Authoritative remote legacy bytes must update local storage to protect against stale cache overwrite',
        );
      },
    );

    test(
      'Conflict handling during migration: returns conflict when both local and legacy remote have unsynced changes without unlocked file',
      () async {
        final baseKdbx = createTestFile('Base Vault');
        final baseBytes = await baseKdbx.save();
        final baseMd5 = GoogleDriveClient.computeMd5(baseBytes);

        const vaultId = 'conflict_vault_id';
        const legacyFileId = 'legacy_conflict_file';
        const visibleFolderId = 'keynest_visible_folder';

        await stateStore.setKeyNestFolderId(visibleFolderId);
        await stateStore.setDriveFileId(vaultId, legacyFileId);
        await stateStore.setSyncCheckpoint(
          vaultId: vaultId,
          md5: baseMd5,
          version: 1,
        );
        await stateStore.setBaseCopy(vaultId, baseBytes);
        await stateStore.markLocalDirty(vaultId); // Local is dirty

        final mockHttp = MockClient((request) async {
          if (request.url.path == '/drive/v3/files/$visibleFolderId') {
            return http.Response(
              json.encode({
                'id': visibleFolderId,
                'name': 'KeyNest',
                'mimeType': 'application/vnd.google-apps.folder',
                'trashed': false,
              }),
              200,
            );
          }
          if (request.url.path == '/drive/v3/files' &&
              request.method == 'GET') {
            return http.Response(json.encode({'files': []}), 200);
          }
          if (request.url.path == '/drive/v3/files/$legacyFileId' &&
              request.method == 'GET') {
            return http.Response(
              json.encode({
                'id': legacyFileId,
                'name': 'Vault.kdbx',
                'md5Checksum': 'different_remote_md5_abc123',
                'version': '2',
                'parents': ['appDataFolder'],
              }),
              200,
            );
          }
          return http.Response('Not found', 404);
        });

        final client = GoogleDriveClient(
          tokenSource: _MockGoogleTokenSource('token'),
          httpClient: mockHttp,
        );
        final engine = GoogleDriveSyncEngine(
          client: client,
          stateStore: stateStore,
        );

        // Synced without unlocked file / credentials
        final result = await engine.syncVault(
          vaultId: vaultId,
          vaultFilename: 'Vault.kdbx',
          getLocalBytes: () async => Uint8List.fromList([9, 9, 9]),
          saveLocalBytes: (b) async {},
          unlockedLocalFile: null,
          credentials: null,
        );

        expect(result.status, GoogleDriveSyncStatus.conflict);
        expect(
          result.message,
          contains('Conflict detected during migration'),
        );
        expect(
          await stateStore.isVaultMigrated(vaultId),
          isFalse,
          reason: 'Must not mark as migrated on conflict',
        );
      },
    );

    test(
      'Persistence: migrated file mapping and legacy ID persist across state store instances',
      () async {
        const vaultId = 'persistence_vault_1';
        const legacyId = 'legacy_file_abc';
        const migratedId = 'migrated_visible_xyz';

        await stateStore.recordLegacyMigration(legacyId, migratedId);
        await stateStore.setLegacyDriveFileId(vaultId, legacyId);
        await stateStore.setDriveFileId(vaultId, migratedId);
        await stateStore.setVaultMigrated(vaultId, true);

        // Fresh stateStore instance pointing to same directory
        final freshStateStore = GoogleDriveSyncStateStore(
          overrideSyncDir: tempDir,
        );

        expect(
          await freshStateStore.getMigratedFileIdForLegacyId(legacyId),
          migratedId,
        );
        expect(await freshStateStore.getLegacyDriveFileId(vaultId), legacyId);
        expect(await freshStateStore.getDriveFileId(vaultId), migratedId);
        expect(await freshStateStore.isVaultMigrated(vaultId), isTrue);
      },
    );
  });
}

class _MockGoogleTokenSource implements GoogleDriveTokenSource {
  _MockGoogleTokenSource(this.currentToken);

  String? currentToken;
  String? nextRefreshedToken;
  int refreshCount = 0;

  @override
  String? get currentAccountEmail => null;

  @override
  String? get currentDisplayName => null;

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async {
    if (forceRefresh) {
      refreshCount++;
      if (nextRefreshedToken != null) {
        currentToken = nextRefreshedToken;
      }
    }
    return currentToken;
  }

  @override
  Future<void> clearCachedAccessToken() async {
    // Only clears memory cache, keeps credentials
  }

  @override
  Future<bool> isSignedIn() async => currentToken != null;

  @override
  Future<bool> signIn() async => true;

  @override
  Future<void> disconnect() async {
    currentToken = null;
  }

  @override
  void resetForNewConfiguration() {
    currentToken = null;
  }
}
