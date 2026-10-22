// ignore_for_file: implementation_imports, invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_auth.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/utils/path_util.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'util/test_util.dart';

class _MockCloudStorageHelper extends Fake implements CloudStorageHelperBase {
  final Map<String, String> _storage = {};

  @override
  final PathUtil pathUtil = TestPathUtil();

  @override
  Future<String?> loadCredentials(String cloudStorageId) async {
    return _storage[cloudStorageId];
  }

  @override
  Future<void> saveCredentials(String cloudStorageId, String data) async {
    if (data.isEmpty) {
      _storage.remove(cloudStorageId);
    } else {
      _storage[cloudStorageId] = data;
    }
  }
}

class _MockGoogleSignInPlatform extends GoogleSignInPlatform
    with MockPlatformInterfaceMixin {
  int clientAuthCalls = 0;
  ClientAuthorizationTokensForScopesParameters? lastParams;
  String? nextAccessTokenToReturn;
  bool attemptLightweightCalled = false;
  bool authenticateCalled = false;

  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    clientAuthCalls++;
    lastParams = params;
    if (nextAccessTokenToReturn != null) {
      return ClientAuthorizationTokenData(accessToken: nextAccessTokenToReturn!);
    }
    return null;
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async => null;

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    attemptLightweightCalled = true;
    return null;
  }

  @override
  Future<AuthenticationResults> authenticate(
    AuthenticateParameters params,
  ) async {
    authenticateCalled = true;
    throw UnimplementedError();
  }

  @override
  Future<void> clearAuthorizationToken(
    ClearAuthorizationTokenParams params,
  ) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  bool supportsAuthenticate() => true;

  @override
  bool authorizationRequiresUserInteraction() => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockCloudStorageHelper helper;
  late _MockGoogleSignInPlatform mockPlatform;
  late GisGoogleTokenSource tokenSource;

  setUp(() {
    helper = _MockCloudStorageHelper();
    mockPlatform = _MockGoogleSignInPlatform();
    GoogleSignInPlatform.instance = mockPlatform;

    tokenSource = GisGoogleTokenSource(
      env: TestEnv(EnvSecrets.nullSecrets),
      helper: helper,
    );
  });

  test('isSignedIn() returns false when no saved metadata exists without platform prompts', () async {
    final signedIn = await tokenSource.isSignedIn();
    expect(signedIn, isFalse);
    expect(mockPlatform.attemptLightweightCalled, isFalse);
    expect(mockPlatform.authenticateCalled, isFalse);
  });

  test('isSignedIn() restores saved account without triggering passkey or platform prompts', () async {
    final savedData = {
      'email': 'user@example.com',
      'displayName': 'Test User',
      'accessToken': 'saved_token_123',
      'expiresAt': DateTime.now().add(const Duration(minutes: 30)).toIso8601String(),
    };
    await helper.saveCredentials('GoogleDriveAccount', json.encode(savedData));

    final signedIn = await tokenSource.isSignedIn();
    expect(signedIn, isTrue);
    expect(tokenSource.currentAccountEmail, 'user@example.com');
    expect(tokenSource.currentDisplayName, 'Test User');
    expect(mockPlatform.attemptLightweightCalled, isFalse);
    expect(mockPlatform.authenticateCalled, isFalse);
  });

  test('getAccessToken() returns fresh in-memory token without calling platform', () async {
    final savedData = {
      'email': 'user@example.com',
      'displayName': 'Test User',
      'accessToken': 'fresh_token_xyz',
      'expiresAt': DateTime.now().add(const Duration(minutes: 40)).toIso8601String(),
    };
    await helper.saveCredentials('GoogleDriveAccount', json.encode(savedData));

    final token = await tokenSource.getAccessToken();
    expect(token, 'fresh_token_xyz');
    expect(mockPlatform.clientAuthCalls, 0);
    expect(mockPlatform.attemptLightweightCalled, isFalse);
  });

  test('getAccessToken() on expired token requests silent authorization with promptIfUnauthorized: false and email', () async {
    final savedData = {
      'email': 'user@example.com',
      'displayName': 'Test User',
      'accessToken': 'old_expired_token',
      'expiresAt': DateTime.now().subtract(const Duration(minutes: 10)).toIso8601String(),
    };
    await helper.saveCredentials('GoogleDriveAccount', json.encode(savedData));

    mockPlatform.nextAccessTokenToReturn = 'silently_refreshed_token_456';

    final token = await tokenSource.getAccessToken();
    expect(token, 'silently_refreshed_token_456');
    expect(mockPlatform.clientAuthCalls, 1);
    expect(mockPlatform.lastParams?.request.email, 'user@example.com');
    expect(mockPlatform.lastParams?.request.promptIfUnauthorized, isFalse);
    expect(mockPlatform.attemptLightweightCalled, isFalse);
  });

  test('getAccessToken() preserves connection and returns fallback/null when silent refresh returns null', () async {
    final savedData = {
      'email': 'user@example.com',
      'displayName': 'Test User',
      'accessToken': 'cached_token_fallback',
      'expiresAt': DateTime.now().subtract(const Duration(minutes: 10)).toIso8601String(),
    };
    await helper.saveCredentials('GoogleDriveAccount', json.encode(savedData));

    mockPlatform.nextAccessTokenToReturn = null; // simulate offline or unprompted null

    final token = await tokenSource.getAccessToken();
    // Returns cached token as best-effort fallback
    expect(token, 'cached_token_fallback');
    // Account remains securely saved and drive stays connected!
    expect(await tokenSource.isSignedIn(), isTrue);
    expect(tokenSource.currentAccountEmail, 'user@example.com');
    expect(mockPlatform.attemptLightweightCalled, isFalse);
  });

  test('explicit disconnect() clears saved metadata and disconnects cleanly', () async {
    final savedData = {
      'email': 'user@example.com',
      'displayName': 'Test User',
      'accessToken': 'token_to_remove',
      'expiresAt': DateTime.now().add(const Duration(minutes: 30)).toIso8601String(),
    };
    await helper.saveCredentials('GoogleDriveAccount', json.encode(savedData));
    expect(await tokenSource.isSignedIn(), isTrue);

    await tokenSource.disconnect();
    expect(await tokenSource.isSignedIn(), isFalse);
    expect(tokenSource.currentAccountEmail, isNull);
    expect(await helper.loadCredentials('GoogleDriveAccount'), isNull);
  });
}
