// ignore_for_file: implementation_imports, invalid_use_of_visible_for_testing_member, invalid_use_of_internal_member, avoid_slow_async_io

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_deleted_object.dart';
import 'package:kdbx/src/kdbx_object.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:keynest/bloc/kdbx/storage_exception.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_auth.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_client.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_merge_engine.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_engine.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_state.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_auth.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_client.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';
import 'package:keynest/cloud_storage/keynest_cloud_sync_manager.dart';
import 'package:keynest/cloud_storage/webdav/webdav_provider.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/services/keynest_import_export_service.dart';
import 'package:keynest/services/keynest_vault_merge_engine.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:mockito/mockito.dart';

import 'util/test_util.dart';
import 'util/test_util.mocks.dart';

class _FakeGoogleTokenSource implements GoogleDriveTokenSource {
  _FakeGoogleTokenSource(this.token);
  String token;

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async => token;

  @override
  Future<bool> isSignedIn() async => true;

  @override
  Future<bool> signIn() async => true;

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> clearCachedAccessToken() async {}

  @override
  void resetForNewConfiguration() {}

  @override
  String? get currentAccountEmail => 'test@example.com';

  @override
  String? get currentDisplayName => 'Test User';
}

class _FakeCloudProvider extends CloudStorageProvider {
  _FakeCloudProvider({required super.helper, required this.remoteBytes});

  Uint8List remoteBytes;
  Map<String, dynamic> remoteMeta = {'etag': 'v1'};
  int loadCalls = 0;

  @override
  String get id => 'FakeCloudProvider';

  @override
  String get displayName => 'Fake Cloud';

  @override
  FileSourceIcon get displayIcon => FileSourceIcon.keyNest;

  @override
  bool get isAuthenticated => true;

  @override
  Future<bool> loadSavedAuth() async => true;

  @override
  Future<bool> startAuth<
    RESULT extends UserAuthenticationPromptResult,
    DATA extends UserAuthenticationPromptData<RESULT>
  >(PromptUserForCode<RESULT, DATA> prompt) async => true;

  @override
  Future<SearchResponse> list({CloudStorageEntity? parent}) async =>
      SearchResponse((b) => b..hasMore = false);

  @override
  Future<FileContent> loadEntity(CloudStorageEntity file) async {
    loadCalls++;
    return FileContent(
      Uint8List.fromList(remoteBytes),
      Map<String, dynamic>.from(remoteMeta),
    );
  }

  @override
  Future<Map<String, dynamic>> saveEntity(
    CloudStorageEntity file,
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async {
    remoteBytes = Uint8List.fromList(bytes);
    remoteMeta = {'etag': 'v2'};
    return Map<String, dynamic>.from(remoteMeta);
  }

  @override
  Future<FileSource> createEntity(
    CloudStorageSelectorSaveResult saveAs,
    Uint8List bytes,
  ) => throw UnimplementedError();

  @override
  Future<void> logout() async {}
}

KdbxFile _createVault(String name, {String password = 'pass'}) {
  return KdbxFormat().create(
    Credentials(ProtectedValue.fromString(password)),
    name,
  );
}

KdbxEntry _addLogin(
  KdbxFile file,
  String title,
  String user,
  String pass, {
  KdbxUuid? uuid,
  DateTime? modTime,
}) {
  final entry = KdbxEntry.create(file, file.body.rootGroup);
  if (uuid != null) {
    entry.forceSetUuid(uuid);
  }
  entry.setString(KdbxKeyCommon.TITLE, PlainValue(title));
  entry.setString(KdbxKeyCommon.USER_NAME, PlainValue(user));
  entry.setString(KdbxKeyCommon.PASSWORD, ProtectedValue.fromString(pass));
  if (modTime != null) {
    entry.times.lastModificationTime.set(modTime);
  }
  file.body.rootGroup.addEntry(entry);
  return entry;
}

DropboxClient _makeTestDropboxClient(http.Client mockHttp) {
  final client = DropboxClient(
    appKey: 'test_app_key',
    authService: DropboxAuthService(httpClient: mockHttp),
    getRefreshToken: () async => null,
    saveRefreshToken: (_) async {},
    clearCredentials: () async {},
    httpClient: mockHttp,
  );
  client.setInMemoryToken(
    DropboxTokenResponse(
      accessToken: 'tok',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    ),
  );
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Section 2 — Cloud Cache & Conflict Semantics (CLOUD-01, CLOUD-02)', () {
    test(
      'FileContentCached serializes full epoch milliseconds and dirty flag',
      () {
        final ts = DateTime.utc(2026, 11, 7, 15, 30, 45, 123);
        final info = FileContentCached(
          metadata: const {'rev': 'rev_abc'},
          cacheDate: ts,
          cacheSize: 4096,
          isDirty: true,
        );
        final roundTrip = FileContentCached.fromJson(
          json.decode(json.encode(info.toJson())) as Map<String, dynamic>,
        );

        expect(roundTrip.cacheDate, equals(ts));
        expect(roundTrip.cacheSize, equals(4096));
        expect(roundTrip.isDirty, isTrue);
        expect(roundTrip.metadata, equals({'rev': 'rev_abc'}));
      },
    );

    test(
      'FileSourceCloudStorage preserves dirty working copy and forceReload bypasses stale cache',
      () async {
        final helper = CloudStorageHelperMock();
        final initialBytes = Uint8List.fromList([1, 2, 3, 4]);
        final dirtyLocalBytes = Uint8List.fromList([9, 9, 9, 9]);
        final updatedRemoteBytes = Uint8List.fromList([7, 7, 7, 7]);
        final provider = _FakeCloudProvider(
          helper: helper,
          remoteBytes: initialBytes,
        );
        final uuid = 'sec2_cloud_cache_${DateTime.now().microsecondsSinceEpoch}';

        final source1 = FileSourceCloudStorage(
          provider: provider,
          fileInfo: const {'id': '/KeyNest/Test.kdbx', 'name': 'Test.kdbx'},
          uuid: uuid,
        );

        // Initial load populates cache cleanly
        final first = await source1.content().last;
        expect(first.content, equals(initialBytes));
        expect(source1.hasUnsavedChanges, isFalse);

        // Local save marks working copy dirty
        await source1.contentWrite(dirtyLocalBytes, metadata: first.metadata);
        expect(source1.hasUnsavedChanges, isTrue);

        // Remote advances independently while local is still dirty
        provider.remoteBytes = updatedRemoteBytes;

        // Re-opening via a new FileSourceCloudStorage instance restores dirty working copy
        final source2 = FileSourceCloudStorage(
          provider: provider,
          fileInfo: const {'id': '/KeyNest/Test.kdbx', 'name': 'Test.kdbx'},
          uuid: uuid,
        );
        final reopened = await source2.content().last;
        expect(reopened.content, equals(dirtyLocalBytes));
        expect(source2.hasUnsavedChanges, isTrue);

        // Explicit forceReload fetches fresh remote bytes without overwriting dirty working copy on disk
        final forced = await source2
            .content(updateCache: false, forceReload: true)
            .last;
        expect(forced.content, equals(updatedRemoteBytes));
        expect(await source2.readWorkingCopyBytes(), equals(dirtyLocalBytes));

        // Uploading working copy clears dirty flag
        await source2.uploadWorkingCopy();
        expect(source2.hasUnsavedChanges, isFalse);
      },
    );

    test(
      'GoogleDriveProvider.saveEntity throws StorageConflictException when remote md5Checksum diverges',
      () async {
        final env = TestEnv(EnvSecrets.nullSecrets);
        final helper = CloudStorageHelperMock();
        final mockHttp = MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/files/file_123')) {
            return http.Response(
              json.encode({
                'id': 'file_123',
                'name': 'Vault.kdbx',
                'md5Checksum': 'remote_changed_md5',
                'version': '9',
              }),
              200,
            );
          }
          return http.Response('Unexpected', 500);
        });

        final provider = GoogleDriveProvider(env: env, helper: helper);
        provider.driveClient = GoogleDriveClient(
          tokenSource: _FakeGoogleTokenSource('token_123'),
          httpClient: mockHttp,
        );

        final entity = CloudStorageEntity(
          (b) => b
            ..id = 'file_123'
            ..name = 'Vault.kdbx'
            ..type = CloudStorageEntityType.file
            ..path = '/KeyNest/Vault.kdbx',
        );

        await expectLater(
          () => provider.saveEntity(
            entity,
            Uint8List.fromList([1, 2, 3]),
            const {'md5Checksum': 'expected_old_md5', 'version': 8},
          ),
          throwsA(isA<StorageConflictException>()),
        );
      },
    );
  });

  group('Section 2 — Dropbox Paths, Pagination & State Store (CLOUD-03..06)', () {
    late io.Directory tempSyncDir;

    setUp(() async {
      tempSyncDir = await io.Directory.systemTemp.createTemp(
        'keynest_sec2_dbx_',
      );
    });

    tearDown(() async {
      if (tempSyncDir.existsSync()) {
        await tempSyncDir.delete(recursive: true);
      }
    });

    test(
      'CloudStorageEntity.fromSimpleFileInfo handles missing id without BuiltValueNullFieldError',
      () {
        final entity = CloudStorageEntity.fromSimpleFileInfo(const {
          'path': '/KeyNest/MyVault.kdbx',
          'name': 'MyVault.kdbx',
        });
        expect(entity.id, equals('/KeyNest/MyVault.kdbx'));
        expect(entity.name, equals('MyVault.kdbx'));
      },
    );

    test(
      'DropboxClient.listFiles follows has_more cursor pagination',
      () async {
        int continueCalls = 0;
        final mockHttp = MockClient((request) async {
          if (request.url.path == '/2/files/list_folder') {
            return http.Response(
              json.encode({
                'entries': [
                  {
                    '.tag': 'file',
                    'id': 'id:1',
                    'name': 'VaultA.kdbx',
                    'path_lower': '/keynest/vaulta.kdbx',
                    'path_display': '/KeyNest/VaultA.kdbx',
                    'rev': '015a1',
                    'size': 100,
                  },
                ],
                'cursor': 'cursor_page_2',
                'has_more': true,
              }),
              200,
            );
          }
          if (request.url.path == '/2/files/list_folder/continue') {
            continueCalls++;
            final body = json.decode(request.body) as Map<String, dynamic>;
            expect(body['cursor'], equals('cursor_page_2'));
            return http.Response(
              json.encode({
                'entries': [
                  {
                    '.tag': 'file',
                    'id': 'id:2',
                    'name': 'VaultB.kdbx',
                    'path_lower': '/keynest/vaultb.kdbx',
                    'path_display': '/KeyNest/VaultB.kdbx',
                    'rev': '015a2',
                    'size': 200,
                  },
                ],
                'cursor': 'cursor_done',
                'has_more': false,
              }),
              200,
            );
          }
          return http.Response('Not found', 404);
        });

        final client = _makeTestDropboxClient(mockHttp);
        final files = await client.listFiles(folderPath: '/KeyNest');
        expect(continueCalls, equals(1));
        expect(files.map((f) => f.name).toList(), ['VaultA.kdbx', 'VaultB.kdbx']);
      },
    );

    test(
      'DropboxProvider preserves email and displayName across token refresh without oauth2.Client',
      () async {
        final savedCredsJson = json.encode({
          'access_token': 'expired_access',
          'refresh_token': 'refresh_xyz',
          'expires_at': DateTime.now()
              .subtract(const Duration(hours: 1))
              .toIso8601String(),
          'email': 'alice@example.com',
          'displayName': 'Alice Vault',
        });

        final env = TestEnv(
          EnvSecretsFake.fromJson(const {'dropboxKey': 'app_key_123'}),
        );
        final pathUtil = TestPathUtil();
        final analytics = MockAnalytics();
        final helper = _InMemoryHelper(
          pathUtil: pathUtil,
          analytics: analytics,
          initial: {'DropboxProvider': savedCredsJson},
        );

        final mockHttp = MockClient((request) async {
          if (request.url.toString() == 'https://api.dropboxapi.com/oauth2/token') {
            return http.Response(
              json.encode({
                'access_token': 'refreshed_access_999',
                'expires_in': 14400,
              }),
              200,
            );
          }
          if (request.url.path == '/2/files/list_folder') {
            return http.Response(
              json.encode({'entries': <dynamic>[], 'has_more': false}),
              200,
            );
          }
          return http.Response('Not Found', 404);
        });

        final provider = DropboxProvider(
          env: env,
          helper: helper,
          httpClient: mockHttp,
        );

        expect(await provider.loadSavedAuth(), isTrue);
        expect(provider.connectedAccountEmail, equals('alice@example.com'));
        expect(provider.connectedDisplayName, equals('Alice Vault'));

        // Trigger token refresh via list()
        await provider.list();

        final updatedRaw = await helper.loadCredentials('DropboxProvider');
        final updatedMap = json.decode(updatedRaw!) as Map<String, dynamic>;
        expect(updatedMap['access_token'], equals('refreshed_access_999'));
        expect(updatedMap['refresh_token'], equals('refresh_xyz'));
        expect(updatedMap['email'], equals('alice@example.com'));
        expect(updatedMap['displayName'], equals('Alice Vault'));
      },
    );

    test(
      'DropboxSyncEngine standardizes to /KeyNest/<name>.kdbx and disambiguates multi-vault collisions',
      () async {
        final stateStore = DropboxSyncStateStore(overrideSyncDir: tempSyncDir);
        final uploadedPaths = <String>[];

        final vault1 = _createVault('Personal');
        final vault1Bytes = await vault1.save();
        final vault2 = _createVault('Personal'); // Different rootGroup.uuid!
        final vault2Bytes = await vault2.save();

        final remoteFiles = <String, Uint8List>{};

        final mockHttp = MockClient((request) async {
          if (request.url.path == '/2/files/get_metadata') {
            final body = json.decode(request.body) as Map<String, dynamic>;
            final reqPath = body['path'] as String;
            final existing = remoteFiles[reqPath];
            if (existing == null) {
              return http.Response(
                json.encode({
                  'error_summary': 'path/not_found/...',
                  'error': {'.tag': 'path', 'path': {'.tag': 'not_found'}},
                }),
                409,
              );
            }
            return http.Response(
              json.encode({
                '.tag': 'file',
                'id': 'id:$reqPath',
                'name': reqPath.split('/').last,
                'path_lower': reqPath.toLowerCase(),
                'path_display': reqPath,
                'rev': '015a0001',
                'size': existing.length,
              }),
              200,
            );
          }
          if (request.url.path == '/2/files/upload') {
            final arg = json.decode(request.headers['Dropbox-API-Arg']!)
                as Map<String, dynamic>;
            final destPath = arg['path'] as String;
            uploadedPaths.add(destPath);
            remoteFiles[destPath] = request.bodyBytes;
            return http.Response(
              json.encode({
                '.tag': 'file',
                'id': 'id:$destPath',
                'name': destPath.split('/').last,
                'path_lower': destPath.toLowerCase(),
                'path_display': destPath,
                'rev': '015a0002',
                'size': request.bodyBytes.length,
              }),
              200,
            );
          }
          return http.Response('Unexpected', 500);
        });

        final engine = DropboxSyncEngine(
          client: _makeTestDropboxClient(mockHttp),
          stateStore: stateStore,
        );

        // Vault 1 claims /KeyNest/Personal.kdbx
        final res1 = await engine.syncVault(
          vaultId: 'vault1111aaaa',
          vaultFilename: 'Personal.kdbx',
          getLocalBytes: () async => vault1Bytes,
          saveLocalBytes: (_) async {},
          unlockedLocalFile: vault1,
          credentials: vault1.credentials,
        );
        expect(res1.status, equals(SyncStatus.uploaded));

        // Vault 2 has the same filename ('Personal.kdbx') -> must disambiguate instead of colliding!
        final res2 = await engine.syncVault(
          vaultId: 'vault2222bbbb',
          vaultFilename: 'Personal.kdbx',
          getLocalBytes: () async => vault2Bytes,
          saveLocalBytes: (_) async {},
          unlockedLocalFile: vault2,
          credentials: vault2.credentials,
        );
        expect(res2.status, equals(SyncStatus.uploaded));
        expect(uploadedPaths.first, equals('/KeyNest/Personal.kdbx'));
        expect(uploadedPaths.last, startsWith('/KeyNest/Personal_'));
        expect(uploadedPaths.last, isNot(equals('/KeyNest/Personal.kdbx')));
      },
    );

    test(
      'Concurrent state store writes do not corrupt metadata.json and SyncManager normalizes stale syncing status',
      () async {
        final dStore = DropboxSyncStateStore(overrideSyncDir: tempSyncDir);
        final gDir = io.Directory('${tempSyncDir.path}_gdrive');
        final gStore = GoogleDriveSyncStateStore(overrideSyncDir: gDir);

        try {
          await Future.wait([
            for (int i = 0; i < 15; i++) dStore.markLocalDirty('vault_$i'),
            for (int i = 0; i < 15; i++)
              dStore.setRemotePath('vault_$i', '/KeyNest/Vault_$i.kdbx'),
            for (int i = 0; i < 15; i++) gStore.markLocalDirty('vault_$i'),
          ]);

          for (int i = 0; i < 15; i++) {
            expect(await dStore.isLocalDirty('vault_$i'), isTrue);
            expect(
              await dStore.getRemotePath('vault_$i'),
              equals('/KeyNest/Vault_$i.kdbx'),
            );
            expect(await gStore.isLocalDirty('vault_$i'), isTrue);
          }

          final prefsFile = io.File('${tempSyncDir.path}/sync_prefs.json');
          await prefsFile.writeAsString(
            json.encode({
              'selections': {
                'DropboxProvider': {'v1': true},
              },
              'lastSync': {
                'DropboxProvider': {
                  'v1': {
                    'status': 'syncing',
                    'message': 'Synchronizing...',
                  },
                },
              },
            }),
          );

          KeyNestCloudSyncManager.instance.resetForTesting();
          await KeyNestCloudSyncManager.instance.load(fileOverride: prefsFile);
          final info = KeyNestCloudSyncManager.instance.getVaultSyncInfo(
            'DropboxProvider',
            'v1',
          );
          expect(info.status, equals(KeyNestSyncStatus.idle));
        } finally {
          KeyNestCloudSyncManager.instance.resetForTesting();
          if (gDir.existsSync()) {
            await gDir.delete(recursive: true);
          }
        }
      },
    );
  });

  group('Section 2 — WebDAV, Drive Query Escaping & Loopback OAuth (CLOUD-07, OAUTH-02)', () {
    test(
      'WebDavProvider.validateSecureWebDavUrl rejects cleartext remote HTTP and allows HTTPS / loopback',
      () {
        expect(
          () => WebDavProvider.validateSecureWebDavUrl(
            'http://cloud.example.com/remote.php/webdav',
          ),
          throwsArgumentError,
        );
        expect(
          () => WebDavProvider.validateSecureWebDavUrl(
            'https://cloud.example.com/remote.php/webdav',
          ),
          returnsNormally,
        );
        expect(
          () => WebDavProvider.validateSecureWebDavUrl(
            'http://127.0.0.1:8080/webdav',
          ),
          returnsNormally,
        );
        expect(
          () => WebDavProvider.validateSecureWebDavUrl(
            'http://localhost:5005/webdav',
          ),
          returnsNormally,
        );
      },
    );

    test(
      'GoogleDriveClient escapes apostrophes in filenames and paginates nextPageToken',
      () async {
        final capturedQueries = <String>[];
        int callCount = 0;
        final mockHttp = MockClient((request) async {
          callCount++;
          capturedQueries.add(request.url.queryParameters['q'] ?? '');
          if (callCount == 1) {
            return http.Response(
              json.encode({
                'nextPageToken': 'token_page_2',
                'files': [
                  {'id': 'f1', 'name': "John's Vault.kdbx", 'version': '1'},
                ],
              }),
              200,
            );
          }
          expect(request.url.queryParameters['pageToken'], 'token_page_2');
          return http.Response(
            json.encode({
              'files': [
                {'id': 'f2', 'name': "John's Vault.kdbx", 'version': '2'},
              ],
            }),
            200,
          );
        });

        final client = GoogleDriveClient(
          tokenSource: _FakeGoogleTokenSource('tok'),
          httpClient: mockHttp,
        );

        final results = await client.findFilesInAppDataFolder(
          "John's Vault.kdbx",
        );
        expect(results.length, equals(2));
        expect(
          capturedQueries.first,
          equals(r"name = 'John\'s Vault.kdbx' and trashed = false"),
        );
      },
    );

    test(
      'DropboxAuthService.captureLoopbackRedirect ignores /favicon.ico and HTML-escapes error_description',
      () async {
        final prevHttpOverrides = io.HttpOverrides.current;
        io.HttpOverrides.global = null;
        final authService = DropboxAuthService();
        // Pick an available ephemeral loopback port
        final probe = await io.ServerSocket.bind(
          io.InternetAddress.loopbackIPv4,
          0,
        );
        final port = probe.port;
        await probe.close();

        final session = DropboxPkceSession.create(
          appKey: 'app_key',
          redirectUri: 'http://127.0.0.1:$port',
        );

        final captureFuture = authService.captureLoopbackRedirect(
          port: port,
          session: session,
          timeout: const Duration(seconds: 5),
        );
        // Yield briefly so HttpServer.bind completes inside captureLoopbackRedirect
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final rawHttp = io.HttpClient();
        try {
          // 1. Browser /favicon.ico request must return 204 and NOT fail OAuth
          final favReq = await rawHttp.getUrl(
            Uri.parse('http://127.0.0.1:$port/favicon.ico'),
          );
          final favRes = await favReq.close();
          expect(favRes.statusCode, equals(io.HttpStatus.noContent));
          await favRes.drain<void>();

          // 2. OAuth error with XSS payload in error_description must be HTML-escaped
          final errReq = await rawHttp.getUrl(
            Uri.parse(
              'http://127.0.0.1:$port/?error=invalid_request&error_description=%3Cscript%3Ealert(1)%3C%2Fscript%3E',
            ),
          );
          final errRes = await errReq.close();
          final htmlBody = await utf8.decoder.bind(errRes).join();
          expect(htmlBody.contains('<script>'), isFalse);
          expect(htmlBody.contains('&lt;script&gt;alert(1)&lt;'), isTrue);
          expect(await captureFuture, isNull);
        } finally {
          rawHttp.close(force: true);
          io.HttpOverrides.global = prevHttpOverrides;
        }
      },
    );
  });

  group('Section 2 — KDBX Merge Engines & Retry Isolation (MERGE-01, MERGE-02)', () {
    late io.Directory tempDir;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('keynest_sec2_merge_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'MERGE-01: Legitimate local deletion of the sole entry succeeds with 0 entries (no DropboxMergeValidationException)',
      () {
        final base = _createVault('Vault');
        final local = _createVault('Vault');
        final remote = _createVault('Vault');
        local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
        remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

        final entryUuid = KdbxUuid.random();
        final tCreated = DateTime.utc(2026, 1, 1);
        final tDeleted = DateTime.utc(2026, 1, 5);

        _addLogin(base, 'TempSite', 'u', 'p', uuid: entryUuid, modTime: tCreated);
        _addLogin(
          remote,
          'TempSite',
          'u',
          'p',
          uuid: entryUuid,
          modTime: tCreated,
        );

        // Local permanently deleted the entry at tDeleted (leaving local with 0 active entries)
        local.body.deletedObjects.add(
          KdbxDeletedObject.create(local.ctx, entryUuid, tDeleted),
        );

        final res = DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: base,
        );

        expect(local.body.rootGroup.getAllEntries(), isEmpty);
        expect(res.addedCount, equals(0));
      },
    );

    test(
      'MERGE-02: 3-way merge propagates customIcons and removes deleted custom fields & binary attachments',
      () {
        final base = _createVault('Vault');
        final local = _createVault('Vault');
        final remote = _createVault('Vault');
        local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
        remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

        final sharedUuid = KdbxUuid.random();
        final tBase = DateTime.utc(2026, 2, 1);
        final tRemote = DateTime.utc(2026, 2, 2);

        final bEntry = _addLogin(
          base,
          'Corp',
          'u',
          'p',
          uuid: sharedUuid,
          modTime: tBase,
        );
        bEntry.setString(KdbxKey('LegacyPin'), ProtectedValue.fromString('1234'));
        bEntry.createBinary(
          isProtected: false,
          name: 'old_cert.pem',
          bytes: Uint8List.fromList([1, 2, 3]),
        );

        final lEntry = _addLogin(
          local,
          'Corp',
          'u',
          'p',
          uuid: sharedUuid,
          modTime: tBase,
        );
        lEntry.setString(KdbxKey('LegacyPin'), ProtectedValue.fromString('1234'));
        lEntry.createBinary(
          isProtected: false,
          name: 'old_cert.pem',
          bytes: Uint8List.fromList([1, 2, 3]),
        );

        // Remote deleted 'LegacyPin' and 'old_cert.pem', and added a new entry with a customIcon
        final rEntry = _addLogin(
          remote,
          'Corp',
          'u',
          'p',
          uuid: sharedUuid,
          modTime: tRemote,
        );
        expect(rEntry.getString(KdbxKey('LegacyPin')), isNull);

        final iconUuid = KdbxUuid.random();
        final customIcon = KdbxCustomIcon(
          uuid: iconUuid,
          data: Uint8List.fromList([137, 80, 78, 71]),
        );
        remote.body.meta.addCustomIcon(customIcon);
        final iconEntry = _addLogin(remote, 'Iconic', 'user2', 'pass2');
        iconEntry.customIcon = customIcon;

        DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: base,
        );

        final mergedShared = local.body.rootGroup.getAllEntries().firstWhere(
          (e) => e.uuid == sharedUuid,
        );
        expect(mergedShared.getString(KdbxKey('LegacyPin')), isNull);
        expect(mergedShared.binaryEntries, isEmpty);

        expect(local.body.meta.customIcons.containsKey(iconUuid), isTrue);
        final mergedIconEntry = local.body.rootGroup.getAllEntries().firstWhere(
          (e) => e.getString(KdbxKeyCommon.TITLE)?.getText() == 'Iconic',
        );
        expect(mergedIconEntry.customIcon?.uuid, equals(iconUuid));
      },
    );

    test(
      'MERGE-02: KeyNestVaultMergeEngine preserves distinct notes sharing the same title',
      () async {
        final dest = _createVault('Dest');
        final src = _createVault('Src');

        final n1 = KdbxEntry.create(dest, dest.body.rootGroup);
        n1.setString(KdbxKeyCommon.TITLE, PlainValue('Shopping List'));
        n1.setString(KdbxKey('Notes'), PlainValue('Milk, Eggs, Bread'));
        n1.setString(
          KdbxKey(KeyNestItemTypeHelper.itemTypeKey),
          PlainValue(KeyNestItemType.note.name),
        );
        dest.body.rootGroup.addEntry(n1);

        final n2 = KdbxEntry.create(src, src.body.rootGroup);
        n2.setString(KdbxKeyCommon.TITLE, PlainValue('Shopping List'));
        n2.setString(KdbxKey('Notes'), PlainValue('Laptop stand, USB-C cable'));
        n2.setString(
          KdbxKey(KeyNestItemTypeHelper.itemTypeKey),
          PlainValue(KeyNestItemType.note.name),
        );
        src.body.rootGroup.addEntry(n2);

        final mockBloc = MockKdbxBloc();
        when(
          mockBloc.saveFile(any),
        ).thenAnswer((_) async => FileContent(Uint8List(0)));

        final res = await KeyNestVaultMergeEngine.mergeVaults(
          sourceVaults: [src],
          destinationVault: dest,
          kdbxBloc: mockBloc,
          duplicateStrategy: VaultMergeDuplicateStrategy.smartMerge,
        );

        expect(res.success, isTrue);
        expect(res.newEntriesAdded, equals(1));
        expect(dest.body.rootGroup.getAllEntries().length, equals(2));
      },
    );

    test(
      'MERGE-02: KeyNestImportExportService.importKdbxBytes skips trashed source entries and never resurrects target Recycle Bin items',
      () async {
        final target = _createVault('Target', password: 'pw');
        final source = _createVault('Source', password: 'pw');

        // Create Recycle Bin in target with a trashed entry sharing UUID with an active entry in source
        final targetRecycleBin = KdbxGroup.create(
          ctx: target.ctx,
          parent: target.body.rootGroup,
          name: 'Recycle Bin',
        );
        target.body.rootGroup.addGroup(targetRecycleBin);
        target.body.meta.recycleBinEnabled.set(true);
        target.body.meta.recycleBinUUID.set(targetRecycleBin.uuid);

        final trashedTargetUuid = KdbxUuid.random();
        final trashedInTarget = KdbxEntry.create(target, targetRecycleBin)
          ..forceSetUuid(trashedTargetUuid);
        trashedInTarget.setString(KdbxKeyCommon.TITLE, PlainValue('Old Login'));
        trashedInTarget.setString(KdbxKeyCommon.USER_NAME, PlainValue('bob'));
        trashedInTarget.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('old_pw'),
        );
        targetRecycleBin.addEntry(trashedInTarget);

        // Source has active 'Old Login' with same UUID + a trashed entry in source's Recycle Bin
        _addLogin(
          source,
          'Old Login',
          'bob',
          'fresh_pw',
          uuid: trashedTargetUuid,
        );

        final srcRecycleBin = KdbxGroup.create(
          ctx: source.ctx,
          parent: source.body.rootGroup,
          name: 'Recycle Bin',
        );
        source.body.rootGroup.addGroup(srcRecycleBin);
        source.body.meta.recycleBinEnabled.set(true);
        source.body.meta.recycleBinUUID.set(srcRecycleBin.uuid);
        final trashedInSrc = KdbxEntry.create(source, srcRecycleBin);
        trashedInSrc.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Deleted In Src'),
        );
        srcRecycleBin.addEntry(trashedInSrc);

        final srcBytes = await source.save();
        final mockBloc = MockKdbxBloc();
        when(mockBloc.kdbxFormat).thenReturn(KdbxFormat());
        when(
          mockBloc.saveFile(any),
        ).thenAnswer((_) async => FileContent(Uint8List(0)));

        final res = await KeyNestImportExportService.importKdbxBytes(
          kdbxBloc: mockBloc,
          targetFile: target,
          bytes: srcBytes,
          password: 'pw',
        );

        expect(res.success, isTrue);
        final activeEntries = KeyNestImportExportService.getExportableEntries(
          target,
        );
        expect(activeEntries.length, equals(1));
        expect(
          activeEntries.first.getString(KdbxKeyCommon.TITLE)?.getText(),
          equals('Old Login'),
        );
        expect(
          activeEntries.any(
            (e) =>
                e.getString(KdbxKeyCommon.TITLE)?.getText() == 'Deleted In Src',
          ),
          isFalse,
        );
        // Target Recycle Bin item was untouched (not overwritten in-place inside Recycle Bin)
        expect(
          trashedInTarget.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          equals('old_pw'),
        );
      },
    );

    test(
      'MERGE-02: DropboxSyncEngine 409 upload failure does not mutate unlockedLocalFile or saveLocalBytes prematurely',
      () async {
        final stateStore = DropboxSyncStateStore(overrideSyncDir: tempDir);
        final base = _createVault('Vault');
        final local = _createVault('Vault');
        final remote = _createVault('Vault');
        local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
        remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

        _addLogin(local, 'LocalOnly', 'lu', 'lp');
        _addLogin(remote, 'RemoteOnly', 'ru', 'rp');

        final localBytes = await local.save();
        final remoteBytes = await remote.save();

        // Seed stateStore so both sides appear modified relative to prior rev
        await stateStore.setRemotePath('v_conflict', '/KeyNest/Vault.kdbx');
        await stateStore.setLastSyncedRev('v_conflict', '015a_old');
        await stateStore.setBaseCopy('v_conflict', await base.save());
        await stateStore.markLocalDirty('v_conflict');

        bool saveLocalCalled = false;
        final mockHttp = MockClient((request) async {
          if (request.url.path == '/2/files/get_metadata') {
            return http.Response(
              json.encode({
                '.tag': 'file',
                'id': 'id:1',
                'name': 'Vault.kdbx',
                'path_lower': '/keynest/vault.kdbx',
                'path_display': '/KeyNest/Vault.kdbx',
                'rev': '015a_remote',
                'size': remoteBytes.length,
              }),
              200,
            );
          }
          if (request.url.path == '/2/files/download') {
            return http.Response.bytes(
              remoteBytes,
              200,
              headers: {
                'dropbox-api-result': json.encode({
                  '.tag': 'file',
                  'id': 'id:1',
                  'name': 'Vault.kdbx',
                  'path_lower': '/keynest/vault.kdbx',
                  'path_display': '/KeyNest/Vault.kdbx',
                  'rev': '015a_remote',
                  'size': remoteBytes.length,
                }),
              },
            );
          }
          if (request.url.path == '/2/files/upload') {
            // Simulate persistent 409 conflict on every upload attempt
            return http.Response(
              json.encode({
                'error_summary': 'path/conflict/file/...',
                'error': {
                  '.tag': 'path',
                  'reason': {'.tag': 'conflict'},
                },
              }),
              409,
            );
          }
          return http.Response('Unexpected', 500);
        });

        final engine = DropboxSyncEngine(
          client: _makeTestDropboxClient(mockHttp),
          stateStore: stateStore,
        );

        final res = await engine.syncVault(
          vaultId: 'v_conflict',
          vaultFilename: 'Vault.kdbx',
          getLocalBytes: () async => localBytes,
          saveLocalBytes: (_) async {
            saveLocalCalled = true;
          },
          unlockedLocalFile: local,
          credentials: local.credentials,
        );

        expect(res.status, equals(SyncStatus.conflict));
        expect(saveLocalCalled, isFalse);
        // Live in-memory local vault was NOT mutated with un-uploaded remote entries!
        expect(local.body.rootGroup.getAllEntries().length, equals(1));
        expect(
          local.body.rootGroup
              .getAllEntries()
              .first
              .getString(KdbxKeyCommon.TITLE)
              ?.getText(),
          equals('LocalOnly'),
        );
      },
    );
  });
}

class _InMemoryHelper implements CloudStorageHelperBase {
  _InMemoryHelper({
    required this.pathUtil,
    required this.analytics,
    Map<String, String?>? initial,
  }) : _map = Map<String, String?>.from(initial ?? const {});

  @override
  final TestPathUtil pathUtil;

  @override
  final MockAnalytics analytics;

  final Map<String, String?> _map;

  @override
  Future<String?> loadCredentials(String cloudStorageId) async =>
      _map[cloudStorageId];

  @override
  Future<void> saveCredentials(String cloudStorageId, String data) async {
    if (data.isEmpty) {
      _map.remove(cloudStorageId);
    } else {
      _map[cloudStorageId] = data;
    }
  }
}
