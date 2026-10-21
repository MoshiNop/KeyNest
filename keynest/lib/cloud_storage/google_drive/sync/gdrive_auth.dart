import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:keynest/cloud_storage/cloud_config_store.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';

final _logger = Logger('gdrive_auth');

const String kGoogleDriveAppDataScope =
    'https://www.googleapis.com/auth/drive.appdata';

const String kGoogleDriveFileScope =
    'https://www.googleapis.com/auth/drive.file';

/// During the migration phase, both drive.file and drive.appdata are requested
/// so that the visible folder can be created/accessed and existing appData vaults
/// can be safely discovered and migrated without losing access.
const List<String> kGoogleDriveScopes = [
  kGoogleDriveFileScope,
  kGoogleDriveAppDataScope,
];

/// Generic Google Auth Exception.
class GoogleDriveAuthException implements Exception {
  GoogleDriveAuthException(this.message, {this.details});
  final String message;
  final dynamic details;

  @override
  String toString() =>
      'GoogleDriveAuthException: $message${details != null ? ' ($details)' : ''}';
}

/// Thrown when refresh token is invalid or revoked.
class GoogleDriveInvalidGrantException extends GoogleDriveAuthException {
  GoogleDriveInvalidGrantException(super.message, {super.details});
}

/// Token response for OAuth token exchange/refresh.
class GoogleTokenResponse {
  GoogleTokenResponse({
    required this.accessToken,
    this.refreshToken,
    required this.expiresAt,
    this.tokenType = 'Bearer',
  });

  factory GoogleTokenResponse.fromJson(Map<String, dynamic> json) {
    DateTime exp;
    if (json.containsKey('expires_at')) {
      exp = DateTime.parse(json['expires_at'] as String);
    } else if (json.containsKey('expires_in')) {
      final seconds = (json['expires_in'] as num).toInt();
      exp = DateTime.now().add(Duration(seconds: seconds));
    } else {
      exp = DateTime.now().add(const Duration(hours: 1));
    }

    return GoogleTokenResponse(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: exp,
      tokenType: json['token_type'] as String? ?? 'Bearer',
    );
  }

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;
  final String tokenType;

  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(seconds: 30)));

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    if (refreshToken != null) 'refresh_token': refreshToken,
    'expires_at': expiresAt.toIso8601String(),
    'token_type': tokenType,
  };
}

/// Token source contract used by GDriveClient.
abstract class GoogleDriveTokenSource {
  Future<String?> getAccessToken({bool forceRefresh = false});
  Future<bool> isSignedIn();
  Future<bool> signIn();
  Future<void> disconnect();
  Future<void> clearCachedAccessToken();
  void resetForNewConfiguration();
  String? get currentAccountEmail;
  String? get currentDisplayName;
}

/// Mobile/Web token source using Google Identity Services (GIS) / google_sign_in 7.x
class GisGoogleTokenSource implements GoogleDriveTokenSource {
  GisGoogleTokenSource({
    required this.env,
    this.helper,
  });

  final Env env;
  final CloudStorageHelperBase? helper;
  final List<String> _scopes = kGoogleDriveScopes;

  static const String _accountStorageKey = 'GoogleDriveAccount';

  String? get _serverClientId {
    final effective = CloudConfigStore.instance.effectiveGoogleWebClientId;
    return effective.isNotEmpty ? effective : null;
  }

  bool _initialized = false;
  GoogleSignInAccount? _currentUser;
  String? _inMemoryAccessToken;
  DateTime? _tokenExpiresAt;
  String? _cachedEmail;
  String? _cachedDisplayName;

  void resetInitialization() {
    _initialized = false;
    _currentUser = null;
    _inMemoryAccessToken = null;
    _tokenExpiresAt = null;
    _cachedEmail = null;
    _cachedDisplayName = null;
  }

  Future<void> _saveAccountMetadata(
    String email,
    String? displayName, {
    String? accessToken,
    DateTime? expiresAt,
  }) async {
    _cachedEmail = email.isNotEmpty ? email : null;
    _cachedDisplayName =
        (displayName != null && displayName.isNotEmpty) ? displayName : null;
    if (accessToken != null && accessToken.isNotEmpty) {
      _inMemoryAccessToken = accessToken;
    }
    if (expiresAt != null) {
      _tokenExpiresAt = expiresAt;
    }
    if (helper == null) {
      return;
    }
    try {
      if (email.isEmpty) {
        await helper!.saveCredentials(_accountStorageKey, '');
      } else {
        final map = <String, dynamic>{
          'email': email,
          'connected_at': DateTime.now().toIso8601String(),
          if (displayName != null && displayName.isNotEmpty)
            'displayName': displayName,
          if (_inMemoryAccessToken != null) 'accessToken': _inMemoryAccessToken,
          if (_tokenExpiresAt != null)
            'expiresAt': _tokenExpiresAt!.toIso8601String(),
        };
        await helper!.saveCredentials(
          _accountStorageKey,
          json.encode(map),
        );
      }
    } catch (e) {
      _logger.warning('Failed to persist Google account metadata: $e');
    }
  }

  Future<Map<String, dynamic>?> _loadAccountMetadata() async {
    if (helper == null) {
      return null;
    }
    try {
      final creds = await helper!.loadCredentials(_accountStorageKey);
      if (creds == null || creds.isEmpty) {
        return null;
      }
      return json.decode(creds) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    try {
      final serverId = _serverClientId;
      await GoogleSignIn.instance.initialize(
        serverClientId: KeyNestPlatform.isAndroid ? serverId : null,
        clientId: (KeyNestPlatform.isIOS || KeyNestPlatform.isMacOS)
            ? serverId
            : null,
      );
      _initialized = true;
    } catch (e) {
      _logger.warning('Failed to initialize GoogleSignIn: $e');
    }
  }

  @override
  Future<bool> isSignedIn() async {
    await _ensureInitialized();
    if (_currentUser != null) {
      return true;
    }

    // Check if we have securely saved account metadata from previous connection
    final saved = await _loadAccountMetadata();
    if (saved == null ||
        saved.isEmpty ||
        (saved['email'] as String?)?.isEmpty == true) {
      // No saved account -> definitively not signed in.
      // Never call attemptLightweightAuthentication() on startup when no account is connected,
      // as on Android Credential Manager this triggers interactive passkey/account-chooser bottom sheet UI!
      return false;
    }

    _cachedEmail = saved['email'] as String?;
    _cachedDisplayName = saved['displayName'] as String?;
    _inMemoryAccessToken ??= saved['accessToken'] as String?;
    if (saved['expiresAt'] != null) {
      _tokenExpiresAt = DateTime.tryParse(saved['expiresAt'] as String);
    }

    return true;
  }

  @override
  Future<bool> signIn() async {
    if (KeyNestPlatform.isAndroid && _serverClientId == null) {
      throw GoogleDriveAuthException(
        'Google Web Client ID is not configured. '
        'Provide KEYNEST_GOOGLE_WEB_CLIENT_ID via cloud_config.json (--dart-define-from-file) '
        'or configure it in KeyNest Cloud Settings.',
      );
    }
    await _ensureInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: _scopes,
      );
      // Authorize scopes explicitly
      var auth = await account.authorizationClient.authorizationForScopes(
        _scopes,
      );
      auth ??= await account.authorizationClient.authorizeScopes(_scopes);
      _currentUser = account;
      _inMemoryAccessToken = auth.accessToken;
      _tokenExpiresAt = DateTime.now().add(const Duration(minutes: 55));
      await _saveAccountMetadata(
        account.email,
        account.displayName,
        accessToken: auth.accessToken,
        expiresAt: _tokenExpiresAt,
      );
      return true;
    } catch (e) {
      _currentUser = null;
      _inMemoryAccessToken = null;
      _tokenExpiresAt = null;
      _logger.warning('Google sign in failed: $e');

      if (e is GoogleSignInException) {
        if (e.code == GoogleSignInExceptionCode.canceled) {
          return false;
        }
        if (e.code == GoogleSignInExceptionCode.clientConfigurationError) {
          throw GoogleDriveAuthException(
            'Google Sign-In configuration error. '
            'Please verify that your Android package name (com.moshinop.keynest) and '
            'SHA-1 signing certificate fingerprint match your Android OAuth Client in the Google Cloud Console.',
            details: e,
          );
        }
        if (e.code == GoogleSignInExceptionCode.providerConfigurationError) {
          throw GoogleDriveAuthException(
            'Google Play Services configuration error. Please ensure Google Play Services is installed and updated on your device.',
            details: e,
          );
        }
      }

      final str = e.toString();
      final msg = str.toLowerCase();

      if (str.contains('ApiException: 10') || str.contains(': 10:')) {
        throw GoogleDriveAuthException(
          'Google Cloud configuration error (Developer Error 10). '
          'The Android package name (com.moshinop.keynest) and signing key SHA-1 fingerprint '
          'must be added to your Google Cloud Console OAuth 2.0 Client credentials.',
          details: e,
        );
      }
      if (str.contains('12500')) {
        throw GoogleDriveAuthException(
          'Google Sign-In error (12500). '
          'The OAuth consent screen may be unconfigured or in testing status without this Google account added as a Test User.',
          details: e,
        );
      }
      if (str.contains('12501')) {
        // User cancelled in older Google Sign In SDKs
        return false;
      }
      if (str.contains('7:') || msg.contains('network_error')) {
        throw GoogleDriveAuthException(
          'Network error: Could not reach Google servers. Please verify your internet connection.',
          details: e,
        );
      }
      if (msg.contains('user cancel') || msg.contains('sign_in_canceled')) {
        return false;
      }

      rethrow;
    }
  }

  @override
  String? get currentAccountEmail => _currentUser?.email ?? _cachedEmail;

  @override
  String? get currentDisplayName =>
      _currentUser?.displayName ?? _cachedDisplayName;

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async {
    await _ensureInitialized();
    final now = DateTime.now();
    final isTokenFresh = _inMemoryAccessToken != null &&
        _tokenExpiresAt != null &&
        now.isBefore(_tokenExpiresAt!);

    if (!forceRefresh && isTokenFresh) {
      return _inMemoryAccessToken;
    }

    if (_currentUser == null) {
      final signedIn = await isSignedIn();
      if (!signedIn) {
        return null;
      }
      if (!forceRefresh &&
          _inMemoryAccessToken != null &&
          (_tokenExpiresAt == null || now.isBefore(_tokenExpiresAt!))) {
        return _inMemoryAccessToken;
      }

      // Attempt silent lightweight authentication only when a token is actually needed and account was saved
      try {
        final user = await GoogleSignIn.instance
            .attemptLightweightAuthentication();
        if (user != null) {
          _currentUser = user;
          _cachedEmail = user.email;
          _cachedDisplayName = user.displayName;
        }
      } catch (e) {
        _logger.fine('Silent token restoration attempt failed: $e');
      }
    }

    if (_currentUser == null) {
      if (_inMemoryAccessToken != null) {
        return _inMemoryAccessToken;
      }
      return null;
    }

    final user = _currentUser!;
    try {
      if (forceRefresh && _inMemoryAccessToken != null) {
        await clearCachedAccessToken();
      }

      final headers = await user.authorizationClient.authorizationHeaders(
        _scopes,
      );
      if (headers == null || !headers.containsKey('Authorization')) {
        // Request authorization for scope
        final clientAuth = await user.authorizationClient.authorizeScopes(
          _scopes,
        );
        _inMemoryAccessToken = clientAuth.accessToken;
        _tokenExpiresAt = DateTime.now().add(const Duration(minutes: 55));
        await _saveAccountMetadata(
          user.email,
          user.displayName,
          accessToken: _inMemoryAccessToken,
          expiresAt: _tokenExpiresAt,
        );
        return clientAuth.accessToken;
      }

      final authHeader = headers['Authorization']!;
      final token = authHeader.replaceFirst(RegExp(r'^Bearer\s+'), '');
      _inMemoryAccessToken = token;
      _tokenExpiresAt = DateTime.now().add(const Duration(minutes: 55));
      await _saveAccountMetadata(
        user.email,
        user.displayName,
        accessToken: _inMemoryAccessToken,
        expiresAt: _tokenExpiresAt,
      );
      return token;
    } catch (e) {
      _logger.warning('Failed to get authorization headers/token: $e');
      if (e.toString().contains('invalid_grant')) {
        await disconnect();
        throw GoogleDriveInvalidGrantException('Session expired or revoked.');
      }
      if (_inMemoryAccessToken != null) {
        return _inMemoryAccessToken;
      }
      return null;
    }
  }

  @override
  Future<void> clearCachedAccessToken() async {
    if (_currentUser != null && _inMemoryAccessToken != null) {
      try {
        await _currentUser!.authorizationClient.clearAuthorizationToken(
          accessToken: _inMemoryAccessToken!,
        );
      } catch (e) {
        _logger.fine('Error clearing auth token: $e');
      }
    }
    _inMemoryAccessToken = null;
    _tokenExpiresAt = null;
  }

  @override
  Future<void> disconnect() async {
    _inMemoryAccessToken = null;
    _tokenExpiresAt = null;
    _currentUser = null;
    _cachedEmail = null;
    _cachedDisplayName = null;
    await _saveAccountMetadata('', null);
    try {
      await GoogleSignIn.instance.disconnect();
    } catch (_) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
  }

  @override
  void resetForNewConfiguration() {
    resetInitialization();
  }
}

/// Desktop (Windows/Linux) PKCE Authorization Code flow with loopback listener
class PkceDesktopGoogleTokenSource implements GoogleDriveTokenSource {
  PkceDesktopGoogleTokenSource({
    required this.env,
    required this.helper,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final Env env;
  final CloudStorageHelperBase helper;
  final http.Client _httpClient;

  static const String _storageKey = 'google_drive_desktop_refresh_token';

  String get _clientId =>
      CloudConfigStore.instance.effectiveGoogleDesktopClientId;

  String get _clientSecret =>
      CloudConfigStore.instance.effectiveGoogleDesktopClientSecret;

  GoogleTokenResponse? _inMemoryToken;
  String? _currentAccountEmail;
  String? _currentDisplayName;

  @override
  String? get currentAccountEmail => _currentAccountEmail;

  @override
  String? get currentDisplayName => _currentDisplayName;

  @override
  Future<bool> isSignedIn() async {
    if (_inMemoryToken != null && !_inMemoryToken!.isExpired) {
      return true;
    }
    final storedRefresh = await _loadStoredRefreshToken();
    if (storedRefresh != null && storedRefresh.isNotEmpty) {
      try {
        final token = await _refreshToken(storedRefresh);
        _inMemoryToken = token;
        return true;
      } on GoogleDriveInvalidGrantException {
        // Refresh token was genuinely revoked or expired
        _logger.warning('Google Drive refresh token revoked or expired.');
        await disconnect();
        return false;
      } catch (e) {
        // Temporary network error or offline on startup!
        // DO NOT mark disconnected. We have a valid stored refresh token.
        _logger.warning(
          'Offline or network error during Google Drive token check: $e',
        );
        return true;
      }
    }
    return false;
  }

  @override
  Future<bool> signIn() async {
    final clientId = _clientId;
    if (clientId.isEmpty) {
      throw GoogleDriveAuthException(
        'Google Desktop Client ID is not configured. '
        'Provide KEYNEST_GOOGLE_DESKTOP_CLIENT_ID via cloud_config.json (--dart-define-from-file) '
        'or configure it in KeyNest Cloud Settings.',
      );
    }

    // 1. Bind loopback server
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final session = GooglePkceSession.create(
      clientId: clientId,
      port: server.port,
    );
    final authUrl = session.authorizeUrl;

    final completer = Completer<String?>();

    // Listen for incoming redirect once
    server.listen((HttpRequest request) async {
      final uri = request.uri;
      final queryParams = uri.queryParameters;

      final incomingState = queryParams['state'];
      final code = queryParams['code'];
      final error = queryParams['error'];

      if (incomingState != session.state) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.html
          ..write(
            '<html><body><h2>Authentication failed: State parameter mismatch.</h2></body></html>',
          );
        await request.response.close();
        if (!completer.isCompleted) {
          completer.complete(null);
        }
        await server.close(force: true);
        return;
      }

      if (error != null) {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(
            '<html><body><h2>Authorization was cancelled. You may close this window.</h2></body></html>',
          );
        await request.response.close();
        if (!completer.isCompleted) {
          completer.complete(null);
        }
        await server.close(force: true);
        return;
      }

      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<html><body><h2>KeyNest Google Drive connection successful! You can close this window.</h2></body></html>',
        );
      await request.response.close();
      if (!completer.isCompleted) {
        completer.complete(code);
      }
      await server.close(force: true);
    });

    try {
      await DialogUtils.openUrl(authUrl.toString());
      final authCode = await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          server.close(force: true);
          return null;
        },
      );

      if (authCode == null) {
        return false;
      }

      // 2. Exchange code for tokens
      final tokens = await _exchangeCode(
        code: authCode,
        codeVerifier: session.codeVerifier,
        redirectUri: session.redirectUri,
      );

      _inMemoryToken = tokens;
      try {
        final profileRes = await _httpClient.get(
          Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
          headers: {'Authorization': 'Bearer ${tokens.accessToken}'},
        );
        if (profileRes.statusCode == 200) {
          final profileData =
              json.decode(profileRes.body) as Map<String, dynamic>;
          _currentAccountEmail = profileData['email'] as String?;
          _currentDisplayName = profileData['name'] as String?;
        }
      } catch (e) {
        _logger.fine('Could not fetch user profile info: $e');
      }

      if (tokens.refreshToken != null) {
        await _saveStoredRefreshToken(tokens.refreshToken!);
      }
      return true;
    } catch (e) {
      await server.close(force: true);
      rethrow;
    }
  }

  Future<GoogleTokenResponse> _exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final clientSecret = _clientSecret;
    final response = await _httpClient.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': _clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'redirect_uri': redirectUri,
        'code_verifier': codeVerifier,
      },
    );

    if (response.statusCode != 200) {
      _logger.warning(
        'Token exchange failed: HTTP ${response.statusCode} - ${response.body}',
      );
      throw GoogleDriveAuthException(
        'Token exchange failed: HTTP ${response.statusCode}',
        details: response.body,
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return GoogleTokenResponse.fromJson(data);
  }

  Future<GoogleTokenResponse> _refreshToken(String refreshToken) async {
    final clientSecret = _clientSecret;
    final response = await _httpClient.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': _clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
      },
    );

    if (response.statusCode != 200) {
      final body = response.body;
      if (body.contains('invalid_grant')) {
        await disconnect();
        throw GoogleDriveInvalidGrantException(
          'Refresh token revoked or expired.',
        );
      }
      throw GoogleDriveAuthException(
        'Token refresh failed: HTTP ${response.statusCode}',
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    if (data['refresh_token'] == null) {
      data['refresh_token'] = refreshToken;
    }
    return GoogleTokenResponse.fromJson(data);
  }

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async {
    if (!forceRefresh && _inMemoryToken != null && !_inMemoryToken!.isExpired) {
      return _inMemoryToken!.accessToken;
    }

    final storedRefresh = await _loadStoredRefreshToken();
    if (storedRefresh == null || storedRefresh.isEmpty) {
      return null;
    }

    final token = await _refreshToken(storedRefresh);
    _inMemoryToken = token;
    return token.accessToken;
  }

  @override
  Future<void> clearCachedAccessToken() async {
    _inMemoryToken = null;
  }

  @override
  Future<void> disconnect() async {
    _inMemoryToken = null;
    _currentAccountEmail = null;
    _currentDisplayName = null;
    final token = await _loadStoredRefreshToken();
    await _saveStoredRefreshToken('');
    if (token != null && token.isNotEmpty) {
      try {
        await _httpClient.post(
          Uri.parse('https://oauth2.googleapis.com/revoke'),
          headers: {'content-type': 'application/x-www-form-urlencoded'},
          body: {'token': token},
        );
      } catch (_) {}
    }
  }

  Future<String?> _loadStoredRefreshToken() async {
    try {
      final creds = await helper.loadCredentials('GoogleDriveDesktop');
      if (creds == null || creds.isEmpty) {
        return null;
      }
      final map = json.decode(creds) as Map<String, dynamic>;
      _currentAccountEmail = map['email'] as String?;
      _currentDisplayName = map['displayName'] as String?;
      return map[_storageKey] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveStoredRefreshToken(String refreshToken) async {
    try {
      if (refreshToken.isEmpty) {
        await helper.saveCredentials('GoogleDriveDesktop', '');
      } else {
        await helper.saveCredentials(
          'GoogleDriveDesktop',
          json.encode({
            _storageKey: refreshToken,
            if (_currentAccountEmail != null) 'email': _currentAccountEmail,
            if (_currentDisplayName != null) 'displayName': _currentDisplayName,
          }),
        );
      }
    } catch (e) {
      _logger.warning('Failed to persist refresh token to secure storage: $e');
    }
  }

  @override
  void resetForNewConfiguration() {
    _inMemoryToken = null;
  }
}

/// Factory helper to build the appropriate token source.
class GoogleDriveAuthService {
  static GoogleDriveTokenSource create({
    required Env env,
    required CloudStorageHelperBase helper,
    http.Client? httpClient,
  }) {
    if (KeyNestPlatform.isWindows || KeyNestPlatform.isLinux) {
      return PkceDesktopGoogleTokenSource(
        env: env,
        helper: helper,
        httpClient: httpClient,
      );
    }
    return GisGoogleTokenSource(env: env, helper: helper);
  }
}

/// Helper container for Google PKCE OAuth session details.
class GooglePkceSession {
  GooglePkceSession({
    required this.clientId,
    required this.redirectUri,
    required this.codeVerifier,
    required this.codeChallenge,
    required this.state,
    required this.authorizeUrl,
  });

  final String clientId;
  final String redirectUri;
  final String codeVerifier;
  final String codeChallenge;
  final String state;
  final Uri authorizeUrl;

  static GooglePkceSession create({
    required String clientId,
    required int port,
  }) {
    final redirectUri = 'http://127.0.0.1:$port';
    final verifier = _generateRandomString(64);
    final challenge = _base64UrlNoPadding(
      sha256.convert(utf8.encode(verifier)).bytes,
    );
    final state = _generateRandomString(32);

    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'scope': kGoogleDriveScopes.join(' '),
      'access_type': 'offline',
      'prompt': 'consent',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
    });

    return GooglePkceSession(
      clientId: clientId,
      redirectUri: redirectUri,
      codeVerifier: verifier,
      codeChallenge: challenge,
      state: state,
      authorizeUrl: authUrl,
    );
  }

  static String _generateRandomString(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  static String _base64UrlNoPadding(List<int> bytes) {
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
