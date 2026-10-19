// ignore_for_file: implementation_imports, invalid_use_of_visible_for_testing_member, invalid_use_of_internal_member

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_deleted_object.dart';
import 'package:kdbx/src/kdbx_object.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_auth.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_client.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_merge_engine.dart';

void main() {
  group('Dropbox PKCE & OAuth Flow Tests', () {
    test(
      'PKCE session generates valid 64-char verifier, S256 challenge, and omits redirect_uri by default',
      () {
        final session = DropboxPkceSession.create(
          appKey: 'test_app_key',
        );

        expect(session.codeVerifier.length, 64);
        expect(session.codeChallenge.isNotEmpty, true);
        expect(session.state.isNotEmpty, true);
        expect(session.redirectUri, isNull);

        final authUri = session.authorizeUrl;
        expect(authUri.host, 'www.dropbox.com');
        expect(authUri.path, '/oauth2/authorize');
        expect(authUri.queryParameters['client_id'], 'test_app_key');
        expect(authUri.queryParameters['response_type'], 'code');
        expect(authUri.queryParameters['token_access_type'], 'offline');
        expect(authUri.queryParameters['code_challenge_method'], 'S256');
        expect(
          authUri.queryParameters['code_challenge'],
          session.codeChallenge,
        );
        expect(authUri.queryParameters['scope'], kDropboxScope);
        expect(authUri.queryParameters['state'], session.state);
        expect(authUri.queryParameters.containsKey('redirect_uri'), isFalse);
      },
    );

    test(
      'PKCE session includes redirect_uri when explicitly provided for loopback',
      () {
        final session = DropboxPkceSession.create(
          appKey: 'test_app_key',
          redirectUri: 'http://127.0.0.1:8080/oauth_callback',
        );

        expect(session.redirectUri, 'http://127.0.0.1:8080/oauth_callback');
        expect(
          session.authorizeUrl.queryParameters['redirect_uri'],
          'http://127.0.0.1:8080/oauth_callback',
        );
      },
    );

    test('Validate redirect accepts matching state and returns code', () {
      final authService = DropboxAuthService();
      final session = DropboxPkceSession.create(
        appKey: 'test_app_key',
        redirectUri: 'http://127.0.0.1:8080/oauth_callback',
      );

      final redirectUri = Uri.parse(
        'http://127.0.0.1:8080/oauth_callback?code=test_auth_code_123&state=${session.state}',
      );

      final code = authService.validateRedirect(
        redirectUri: redirectUri,
        session: session,
      );

      expect(code, 'test_auth_code_123');
    });

    test('Validate redirect aborts on state tampering', () {
      final authService = DropboxAuthService();
      final session = DropboxPkceSession.create(
        appKey: 'test_app_key',
        redirectUri: 'http://127.0.0.1:8080/oauth_callback',
      );

      final tamperedUri = Uri.parse(
        'http://127.0.0.1:8080/oauth_callback?code=test_code&state=fake_state_tampered',
      );

      expect(
        () => authService.validateRedirect(
          redirectUri: tamperedUri,
          session: session,
        ),
        throwsA(isA<DropboxAuthException>()),
      );
    });

    test(
      'Validate redirect returns null cleanly when user cancels (error=access_denied)',
      () {
        final authService = DropboxAuthService();
        final session = DropboxPkceSession.create(
          appKey: 'test_app_key',
          redirectUri: 'http://127.0.0.1:8080/oauth_callback',
        );

        final cancelUri = Uri.parse(
          'http://127.0.0.1:8080/oauth_callback?error=access_denied&error_description=User%20clicked%20Cancel',
        );

        final code = authService.validateRedirect(
          redirectUri: cancelUri,
          session: session,
        );

        expect(code, isNull);
      },
    );

    test(
      'extractCodeOrUrl parses bare codes and validates state against session',
      () {
        final session = DropboxPkceSession.create(appKey: 'test_app_key');

        // 1. Bare code (official Dropbox code-display flow)
        expect(
          DropboxAuthService.extractCodeOrUrl(
            'plain_auth_code_123',
            session: session,
          ),
          'plain_auth_code_123',
        );

        // 2. Callback URL with matching state
        expect(
          DropboxAuthService.extractCodeOrUrl(
            'http://127.0.0.1:8080?code=loopback_code_456&state=${session.state}',
            session: session,
          ),
          'loopback_code_456',
        );

        // 3. Callback URL with tampered state throws exception
        expect(
          () => DropboxAuthService.extractCodeOrUrl(
            'http://127.0.0.1:8080?code=code_789&state=invalid_tampered_state',
            session: session,
          ),
          throwsA(isA<DropboxAuthException>()),
        );

        // 4. Cancellation error throws DropboxAuthException with isCancelled
        expect(
          () => DropboxAuthService.extractCodeOrUrl(
            'http://127.0.0.1:8080?error=access_denied&error_description=User%20denied',
            session: session,
          ),
          throwsA(
            isA<DropboxAuthException>().having(
              (e) => e.isCancelled,
              'isCancelled',
              isTrue,
            ),
          ),
        );
      },
    );

    test(
      'Token exchange omits redirect_uri parameter when session has no redirect_uri',
      () async {
        final session = DropboxPkceSession.create(appKey: 'test_app_key');
        expect(session.redirectUri, isNull);

        http.Request? capturedRequest;
        final mockHttp = MockClient((request) async {
          if (request.url.path == '/oauth2/token') {
            capturedRequest = request;
            return http.Response(
              json.encode({
                'access_token': 'new_access_token_123',
                'refresh_token': 'new_refresh_token_456',
                'token_type': 'bearer',
                'expires_in': 14400,
              }),
              200,
            );
          }
          return http.Response('Not Found', 404);
        });

        final authService = DropboxAuthService(httpClient: mockHttp);
        final tokens = await authService.exchangeCodeForToken(
          code: 'valid_test_code_999',
          session: session,
        );

        expect(tokens.accessToken, 'new_access_token_123');
        expect(tokens.refreshToken, 'new_refresh_token_456');
        expect(capturedRequest, isNotNull);
        expect(capturedRequest!.bodyFields['grant_type'], 'authorization_code');
        expect(capturedRequest!.bodyFields['code'], 'valid_test_code_999');
        expect(capturedRequest!.bodyFields['client_id'], 'test_app_key');
        expect(
          capturedRequest!.bodyFields['code_verifier'],
          session.codeVerifier,
        );
        // redirect_uri MUST NOT be present in body when omitted from authorize request
        expect(
          capturedRequest!.bodyFields.containsKey('redirect_uri'),
          isFalse,
        );
      },
    );

    test(
      'Token exchange includes exact redirect_uri when session configured with redirect',
      () async {
        final session = DropboxPkceSession.create(
          appKey: 'test_app_key',
          redirectUri: 'http://127.0.0.1:8080/callback',
        );

        http.Request? capturedRequest;
        final mockHttp = MockClient((request) async {
          if (request.url.path == '/oauth2/token') {
            capturedRequest = request;
            return http.Response(
              json.encode({
                'access_token': 'access_token_abc',
                'refresh_token': 'refresh_token_xyz',
                'token_type': 'bearer',
                'expires_in': 14400,
              }),
              200,
            );
          }
          return http.Response('Not Found', 404);
        });

        final authService = DropboxAuthService(httpClient: mockHttp);
        await authService.exchangeCodeForToken(
          code: 'loopback_code_111',
          session: session,
        );

        expect(capturedRequest, isNotNull);
        expect(
          capturedRequest!.bodyFields['redirect_uri'],
          'http://127.0.0.1:8080/callback',
        );
      },
    );

    test(
      'captureLoopbackRedirect receives callback on local loopback and completes code',
      () async {
        final authService = DropboxAuthService();
        final session = DropboxPkceSession.create(appKey: 'test_app_key');

        // Bind to an ephemeral port to avoid conflicts
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port = server.port;
        await server.close();

        // Launch listener in background
        final captureFuture = authService.captureLoopbackRedirect(
          port: port,
          session: session,
        );

        // Give server a moment to start listening
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Dispatch simulated browser callback to loopback
        final callbackUri = Uri.parse('http://127.0.0.1:$port/oauth_callback')
            .replace(
              queryParameters: {
                'code': 'ephemeral_loopback_code_777',
                'state': session.state,
              },
            );

        final client = http.Client();
        final res = await client.get(callbackUri);
        expect(res.statusCode, 200);
        expect(res.body, contains('Connected to KeyNest!'));
        client.close();

        final capturedCode = await captureFuture;
        expect(capturedCode, 'ephemeral_loopback_code_777');
      },
    );
  });

  group('Dropbox Client & Token Refresh Tests', () {
    test(
      'Client transparently refreshes expired access token on 401 and retries',
      () async {
        int requestCount = 0;
        int refreshCount = 0;

        final mockHttp = MockClient((request) async {
          if (request.url.path == '/oauth2/token') {
            refreshCount++;
            return http.Response(
              json.encode({
                'access_token': 'new_valid_access_token',
                'token_type': 'bearer',
                'expires_in': 14400,
              }),
              200,
            );
          }

          if (request.url.path == '/2/files/get_metadata') {
            requestCount++;
            final auth =
                request.headers['authorization'] ??
                request.headers['Authorization'];
            if (auth == 'Bearer initial_expired_token') {
              return http.Response('{"error": "invalid_access_token"}', 401);
            }
            if (auth == 'Bearer new_valid_access_token') {
              return http.Response(
                json.encode({
                  'name': 'vault.kdbx',
                  'path_lower': '/vault.kdbx',
                  'rev': 'rev_xyz123',
                  'size': 1024,
                  'server_modified': '2026-10-07T12:00:00Z',
                }),
                200,
              );
            }
          }

          return http.Response('Not found', 404);
        });

        String? storedRefresh = 'valid_refresh_token_abc';
        final authService = DropboxAuthService(httpClient: mockHttp);
        final client = DropboxClient(
          appKey: 'test_key',
          authService: authService,
          httpClient: mockHttp,
          getRefreshToken: () async => storedRefresh,
          saveRefreshToken: (token) async => storedRefresh = token,
          clearCredentials: () async => storedRefresh = null,
        );

        // Set initially expired in-memory token
        client.setInMemoryToken(
          DropboxTokenResponse(
            accessToken: 'initial_expired_token',
            expiresAt: DateTime.now().add(const Duration(minutes: 10)),
          ),
        );

        final metadata = await client.getMetadata('/vault.kdbx');
        expect(metadata, isNotNull);
        expect(metadata!.rev, 'rev_xyz123');
        expect(refreshCount, 1);
        expect(requestCount, 2); // Initial 401 + retry with new token
      },
    );

    test(
      'Client triggers onAuthenticationLost and clearCredentials on invalid_grant',
      () async {
        bool authLostCalled = false;
        String? storedRefresh = 'revoked_refresh_token';

        final mockHttp = MockClient((request) async {
          if (request.url.path == '/oauth2/token') {
            return http.Response(
              json.encode({
                'error': 'invalid_grant',
                'error_description':
                    'The refresh token is invalid or has been revoked.',
              }),
              400,
            );
          }
          return http.Response('Unauthorized', 401);
        });

        final authService = DropboxAuthService(httpClient: mockHttp);
        final client = DropboxClient(
          appKey: 'test_key',
          authService: authService,
          httpClient: mockHttp,
          getRefreshToken: () async => storedRefresh,
          saveRefreshToken: (token) async => storedRefresh = token,
          clearCredentials: () async => storedRefresh = null,
          onAuthenticationLost: () => authLostCalled = true,
        );

        client.setInMemoryToken(
          DropboxTokenResponse(
            accessToken: 'expired_token',
            expiresAt: DateTime.now().add(const Duration(minutes: 5)),
          ),
        );

        expect(
          () => client.getMetadata('/vault.kdbx'),
          throwsA(isA<DropboxInvalidGrantException>()),
        );
        // Wait microtask for callbacks
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(authLostCalled, isTrue);
        expect(storedRefresh, isNull);
      },
    );

    test('Missing App Key throws descriptive exception', () {
      expect(
        () => DropboxPkceSession.create(appKey: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => DropboxPkceSession.create(appKey: '   '),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('KDBX 3-Way Merge Engine Scenarios', () {
    late KdbxFormat kdbxFormat;
    late Credentials testCredentials;

    setUp(() {
      kdbxFormat = KdbxFormat();
      testCredentials = Credentials(
        ProtectedValue.fromString('master_pass_123'),
      );
    });

    KdbxFile createTestFile(String name) {
      return kdbxFormat.create(testCredentials, name);
    }

    KdbxEntry addEntry(
      KdbxFile file,
      String title,
      String user,
      String pass, {
      KdbxUuid? forcedUuid,
      DateTime? modTime,
    }) {
      final entry = KdbxEntry.create(file, file.body.rootGroup);
      if (forcedUuid != null) {
        entry.forceSetUuid(forcedUuid);
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

    test('Case 1: Entry added on each side (both entries preserved)', () {
      final base = createTestFile('Vault');
      final local = createTestFile('Vault');
      final remote = createTestFile('Vault');

      // Sync root UUIDs
      local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
      remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

      addEntry(local, 'Local Entry', 'local_user', 'pass1');
      addEntry(remote, 'Remote Entry', 'remote_user', 'pass2');

      final result = DropboxVaultMergeEngine.merge(
        localFile: local,
        remoteFile: remote,
        baseFile: base,
      );

      expect(result.addedCount, 1);
      final allLocal = local.body.rootGroup.getAllEntries().toList();
      expect(allLocal.length, 2);
      expect(
        allLocal.any(
          (e) => e.getString(KdbxKeyCommon.TITLE)?.getText() == 'Local Entry',
        ),
        isTrue,
      );
      expect(
        allLocal.any(
          (e) => e.getString(KdbxKeyCommon.TITLE)?.getText() == 'Remote Entry',
        ),
        isTrue,
      );
    });

    test(
      'Case 2: Same entry edited on both sides (newer wins, older goes to History)',
      () {
        final base = createTestFile('Vault');
        final local = createTestFile('Vault');
        final remote = createTestFile('Vault');
        local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
        remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

        final entryUuid = KdbxUuid.random();
        final tBase = DateTime.utc(2026, 1, 1);
        final tLocal = DateTime.utc(2026, 1, 2);
        final tRemote = DateTime.utc(2026, 1, 3); // Remote is newer

        addEntry(
          base,
          'Site',
          'user',
          'base_pass',
          forcedUuid: entryUuid,
          modTime: tBase,
        );
        addEntry(
          local,
          'Site',
          'user',
          'local_pass',
          forcedUuid: entryUuid,
          modTime: tLocal,
        );
        addEntry(
          remote,
          'Site',
          'user',
          'remote_pass',
          forcedUuid: entryUuid,
          modTime: tRemote,
        );

        final result = DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: base,
        );

        final mergedEntry = local.body.rootGroup.getAllEntries().firstWhere(
          (e) => e.uuid == entryUuid,
        );
        // Newer (remote) wins
        expect(
          mergedEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'remote_pass',
        );
        expect(result.updatedCount, 1);
        // Older (local) was preserved in history
        expect(mergedEntry.history.isNotEmpty, isTrue);
        expect(
          mergedEntry.history.any(
            (h) =>
                h.getString(KdbxKeyCommon.PASSWORD)?.getText() == 'local_pass',
          ),
          isTrue,
        );
      },
    );

    test(
      'Case 3: Different fields edited on same entry (field-by-field merge preserves both)',
      () {
        final base = createTestFile('Vault');
        final local = createTestFile('Vault');
        final remote = createTestFile('Vault');
        local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
        remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

        final entryUuid = KdbxUuid.random();
        final tBase = DateTime.utc(2026, 1, 1);
        final tLocal = DateTime.utc(2026, 1, 2);
        final tRemote = DateTime.utc(2026, 1, 2);

        // BASE
        addEntry(
          base,
          'MyBank',
          'initial_user',
          'initial_pass',
          forcedUuid: entryUuid,
          modTime: tBase,
        );

        // LOCAL updated ONLY username
        addEntry(
          local,
          'MyBank',
          'new_user_changed_locally',
          'initial_pass',
          forcedUuid: entryUuid,
          modTime: tLocal,
        );

        // REMOTE updated ONLY password
        addEntry(
          remote,
          'MyBank',
          'initial_user',
          'new_pass_changed_remotely',
          forcedUuid: entryUuid,
          modTime: tRemote,
        );

        DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: base,
        );

        final mergedEntry = local.body.rootGroup.getAllEntries().firstWhere(
          (e) => e.uuid == entryUuid,
        );
        // Merged entry has LOCAL's new username AND REMOTE's new password!
        expect(
          mergedEntry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'new_user_changed_locally',
        );
        expect(
          mergedEntry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'new_pass_changed_remotely',
        );
      },
    );

    test(
      'Case 4: Entry deleted locally but edited remotely (kept / restored)',
      () {
        final base = createTestFile('Vault');
        final local = createTestFile('Vault');
        final remote = createTestFile('Vault');
        local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
        remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

        final entryUuid = KdbxUuid.random();
        final tBase = DateTime.utc(2026, 1, 1);
        final tDeleted = DateTime.utc(2026, 1, 2);
        final tEditedRemotely = DateTime.utc(
          2026,
          1,
          3,
        ); // Edited after deletion!

        addEntry(base, 'Item', 'u', 'p', forcedUuid: entryUuid, modTime: tBase);

        // Local deleted the entry at tDeleted
        local.body.deletedObjects.add(
          KdbxDeletedObject.create(local.ctx, entryUuid, tDeleted),
        );

        // Remote modified the entry after tDeleted
        addEntry(
          remote,
          'Item',
          'u_updated',
          'p_updated',
          forcedUuid: entryUuid,
          modTime: tEditedRemotely,
        );

        final result = DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: base,
        );

        // Rule e: Object was edited after deletion -> RESTORED/KEPT
        expect(result.addedCount, 1);
        final entry = local.body.rootGroup.getAllEntries().firstWhere(
          (e) => e.uuid == entryUuid,
        );
        expect(
          entry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'u_updated',
        );
      },
    );

    test('Case 5: Entry deleted remotely and untouched locally (deleted)', () {
      final base = createTestFile('Vault');
      final local = createTestFile('Vault');
      final remote = createTestFile('Vault');
      local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
      remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

      final entryUuid = KdbxUuid.random();
      final tBase = DateTime.utc(2026, 1, 1);
      final tDeleted = DateTime.utc(2026, 1, 3);

      addEntry(
        base,
        'Old Entry',
        'u',
        'p',
        forcedUuid: entryUuid,
        modTime: tBase,
      );
      addEntry(
        local,
        'Old Entry',
        'u',
        'p',
        forcedUuid: entryUuid,
        modTime: tBase,
      );

      // Remote deleted object at tDeleted
      remote.body.deletedObjects.add(
        KdbxDeletedObject.create(remote.ctx, entryUuid, tDeleted),
      );

      final result = DropboxVaultMergeEngine.merge(
        localFile: local,
        remoteFile: remote,
        baseFile: base,
      );

      // Entry should be deleted
      expect(result.deletedCount, 1);
      expect(
        local.body.rootGroup.getAllEntries().any((e) => e.uuid == entryUuid),
        isFalse,
      );
    });

    test(
      'Case 6: Group moved on both sides (newer move wins; orphaned parent goes to root)',
      () {
        final base = createTestFile('Vault');
        final local = createTestFile('Vault');
        final remote = createTestFile('Vault');
        local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
        remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

        final groupUuid = KdbxUuid.random();
        final destFolderUuid = KdbxUuid.random();

        // Create target group in local and remote
        final localFolder = KdbxGroup.create(
          ctx: local.ctx,
          parent: local.body.rootGroup,
          name: 'Archive',
        )..forceSetUuid(destFolderUuid);
        local.body.rootGroup.addGroup(localFolder);

        final remoteFolder = KdbxGroup.create(
          ctx: remote.ctx,
          parent: remote.body.rootGroup,
          name: 'Archive',
        )..forceSetUuid(destFolderUuid);
        remote.body.rootGroup.addGroup(remoteFolder);

        // Create moved group
        final g = KdbxGroup.create(
          ctx: local.ctx,
          parent: local.body.rootGroup,
          name: 'Sub',
        )..forceSetUuid(groupUuid);
        local.body.rootGroup.addGroup(g);
        g.times.locationChanged.set(DateTime.utc(2026, 1, 2));

        // Remote moved group into Archive at newer timestamp
        final gRemote = KdbxGroup.create(
          ctx: remote.ctx,
          parent: remoteFolder,
          name: 'Sub',
        )..forceSetUuid(groupUuid);
        remoteFolder.addGroup(gRemote);
        gRemote.times.locationChanged.set(
          DateTime.utc(2026, 1, 3),
        ); // Newer move

        DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: base,
        );

        final mergedGroup = local.body.rootGroup.getAllGroups().firstWhere(
          (grp) => grp.uuid == groupUuid,
        );
        expect(mergedGroup.parent?.uuid, destFolderUuid);
      },
    );

    test('Case 7: Attachment on a merged entry preserved', () {
      final base = createTestFile('Vault');
      final local = createTestFile('Vault');
      final remote = createTestFile('Vault');
      local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
      remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

      final entryUuid = KdbxUuid.random();
      addEntry(base, 'Doc', 'u', 'p', forcedUuid: entryUuid);
      addEntry(local, 'Doc', 'u', 'p', forcedUuid: entryUuid);
      final rEntry = addEntry(remote, 'Doc', 'u', 'p', forcedUuid: entryUuid);

      // Attach binary to remote entry
      rEntry.createBinary(
        isProtected: false,
        name: 'key.txt',
        bytes: Uint8List.fromList([1, 2, 3, 4, 5]),
      );

      DropboxVaultMergeEngine.merge(
        localFile: local,
        remoteFile: remote,
        baseFile: base,
      );

      final mergedEntry = local.body.rootGroup.getAllEntries().firstWhere(
        (e) => e.uuid == entryUuid,
      );
      expect(mergedEntry.binaryEntries.isNotEmpty, isTrue);
      expect(mergedEntry.binaryEntries.first.key.key, 'key.txt');
    });

    test('Case 8: Root group / credential mismatch refuses to merge', () {
      final local = createTestFile('Local');
      final remote = createTestFile('Remote'); // Different root group UUID!

      expect(
        () => DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: null,
        ),
        throwsA(isA<DropboxMergeCredentialMismatchException>()),
      );
    });

    test(
      'Case 9: Repeated merge is idempotent (running again changes nothing)',
      () {
        final base = createTestFile('Vault');
        final local = createTestFile('Vault');
        final remote = createTestFile('Vault');
        local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
        remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

        addEntry(local, 'E1', 'u1', 'p1');
        addEntry(remote, 'E2', 'u2', 'p2');

        // First merge
        final res1 = DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: base,
        );
        expect(res1.addedCount, 1);

        // Second merge with same remoteFile
        final res2 = DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: base,
        );
        expect(res2.addedCount, 0);
        expect(res2.updatedCount, 0);
        expect(res2.deletedCount, 0);
      },
    );

    test(
      'Case 10: Merge never reduces entry count except by legitimate deletions',
      () {
        final base = createTestFile('Vault');
        final local = createTestFile('Vault');
        final remote = createTestFile('Vault');
        local.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);
        remote.body.rootGroup.forceSetUuid(base.body.rootGroup.uuid);

        for (var i = 0; i < 5; i++) {
          addEntry(local, 'Local $i', 'u$i', 'p$i');
        }
        for (var i = 0; i < 3; i++) {
          addEntry(remote, 'Remote $i', 'ru$i', 'rp$i');
        }

        final res = DropboxVaultMergeEngine.merge(
          localFile: local,
          remoteFile: remote,
          baseFile: base,
        );

        final total = local.body.rootGroup.getAllEntries().length;
        expect(total, 8); // 5 local + 3 remote
        expect(res.addedCount, 3);
        expect(res.deletedCount, 0);
      },
    );
  });
}
