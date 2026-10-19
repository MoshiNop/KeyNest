import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

export 'package:keynest/cloud_storage/cloud_config_store.dart'
    show kDefaultDropboxAppKey;

final _logger = Logger('dropbox_auth');

@NonNls
const kDefaultDropboxRedirectUri = String.fromEnvironment(
  'KEYNEST_DROPBOX_REDIRECT_URI',
  defaultValue: String.fromEnvironment(
    'DROPBOX_REDIRECT_URI',
    defaultValue: '',
  ),
);

@NonNls
const kDropboxScope =
    'files.content.write files.content.read files.metadata.read';

/// Holds the in-flight PKCE session parameters before redirect verification.
class DropboxPkceSession {
  DropboxPkceSession({
    required this.codeVerifier,
    required this.codeChallenge,
    required this.state,
    required this.appKey,
    this.redirectUri,
    required this.authorizeUrl,
  });

  final String codeVerifier;
  final String codeChallenge;
  final String state;
  final String appKey;
  final String? redirectUri;
  final Uri authorizeUrl;

  /// Creates a new PKCE session with a 64-character verifier, S256 challenge, and random state.
  /// If [redirectUri] is null or empty, Dropbox will display the authorization code on screen.
  static DropboxPkceSession create({
    required String appKey,
    String? redirectUri,
  }) {
    if (appKey.trim().isEmpty) {
      throw ArgumentError.value(
        appKey,
        'appKey',
        'Dropbox App Key cannot be empty.',
      );
    }
    final verifier = _generateCodeVerifier();
    final challenge = _computeS256CodeChallenge(verifier);
    final state = _generateRandomState();

    final hasRedirect = redirectUri != null && redirectUri.trim().isNotEmpty;
    final cleanRedirect = hasRedirect ? redirectUri.trim() : null;

    final queryParams = <String, String>{
      'client_id': appKey,
      'response_type': 'code',
      'redirect_uri': ?cleanRedirect,
      'token_access_type': 'offline',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'scope': kDropboxScope,
      'state': state,
    };

    final authorizeUrl = Uri.parse(
      'https://www.dropbox.com/oauth2/authorize',
    ).replace(queryParameters: queryParams);

    return DropboxPkceSession(
      codeVerifier: verifier,
      codeChallenge: challenge,
      state: state,
      appKey: appKey,
      redirectUri: cleanRedirect,
      authorizeUrl: authorizeUrl,
    );
  }

  static String _generateCodeVerifier() {
    // 48 random bytes encoded in base64url produces 64 URL-safe characters.
    final rand = Random.secure();
    final bytes = List<int>.generate(48, (_) => rand.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String _computeS256CodeChallenge(String verifier) {
    final asciiBytes = ascii.encode(verifier);
    final digest = sha256.convert(asciiBytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  static String _generateRandomState() {
    final rand = Random.secure();
    final bytes = List<int>.generate(24, (_) => rand.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

/// Token credentials received from Dropbox OAuth 2.0 flow.
class DropboxTokenResponse {
  DropboxTokenResponse({
    required this.accessToken,
    this.refreshToken,
    required this.expiresAt,
    this.accountId,
    this.scope,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;
  final String? accountId;
  final String? scope;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    if (refreshToken != null) 'refresh_token': refreshToken,
    'expires_at': expiresAt.toIso8601String(),
    if (accountId != null) 'account_id': accountId,
    if (scope != null) 'scope': scope,
  };

  static DropboxTokenResponse fromJson(Map<String, dynamic> json) {
    DateTime expires;
    if (json['expires_at'] != null) {
      expires = DateTime.parse(json['expires_at'] as String);
    } else {
      final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 14400;
      expires = DateTime.now().add(Duration(seconds: expiresIn));
    }
    return DropboxTokenResponse(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: expires,
      accountId: json['account_id'] as String?,
      scope: json['scope'] as String?,
    );
  }
}

/// Thrown when refresh token is invalid or revoked.
class DropboxInvalidGrantException implements Exception {
  DropboxInvalidGrantException(this.message);
  final String message;

  @override
  String toString() => 'DropboxInvalidGrantException: $message';
}

/// Thrown when PKCE state validation fails or user cancels.
class DropboxAuthException implements Exception {
  DropboxAuthException(this.message, {this.isCancelled = false});
  final String message;
  final bool isCancelled;

  @override
  String toString() => 'DropboxAuthException: $message';
}

/// Handles OAuth 2.0 authorization code flow with PKCE and token refreshes.
class DropboxAuthService {
  DropboxAuthService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  /// Parses and validates redirect URI parameters against the active PKCE session.
  ///
  /// Returns the authorization code if valid.
  /// Returns `null` if the user cancelled (redirect contains `error`).
  /// Throws [DropboxAuthException] if state mismatch occurs or unknown error is returned.
  String? validateRedirect({
    required Uri redirectUri,
    required DropboxPkceSession session,
  }) {
    final params = redirectUri.queryParameters;

    // Handle user cancellation / error from Dropbox consent page
    if (params.containsKey('error')) {
      final error = params['error'];
      final errorDescription =
          params['error_description'] ?? 'User cancelled authorization.';
      _logger.info(
        'Dropbox auth cancelled or failed with error: $error ($errorDescription)',
      );
      if (error == 'access_denied') {
        return null;
      }
      throw DropboxAuthException(errorDescription, isCancelled: true);
    }

    // Verify state matches
    final incomingState = params['state'];
    if (incomingState == null || incomingState != session.state) {
      _logger.warning(
        'Dropbox auth state mismatch. Expected ${session.state}, got $incomingState',
      );
      throw DropboxAuthException(
        'OAuth state parameter mismatch. Authorization rejected.',
      );
    }

    final code = params['code'];
    if (code == null || code.trim().isEmpty) {
      throw DropboxAuthException('Missing authorization code in redirect URI.');
    }

    return code.trim();
  }

  /// Extracts the authorization code from either a bare code string or a full redirect URL.
  ///
  /// Throws [DropboxAuthException] if the input URL contains an error like `access_denied`
  /// or if a session is provided and the URL state parameter does not match the session.
  static String extractCodeOrUrl(
    String rawInput, {
    DropboxPkceSession? session,
  }) {
    final trimmed = rawInput.trim();
    if (trimmed.contains('://') ||
        trimmed.contains('code=') ||
        trimmed.contains('error=')) {
      try {
        final uri = Uri.parse(trimmed);
        if (uri.queryParameters.containsKey('error')) {
          final error = uri.queryParameters['error'];
          final desc =
              uri.queryParameters['error_description'] ??
              'User cancelled authorization.';
          throw DropboxAuthException(
            '$error: $desc',
            isCancelled: error == 'access_denied',
          );
        }
        if (session != null && uri.queryParameters.containsKey('state')) {
          final incomingState = uri.queryParameters['state'];
          if (incomingState != null && incomingState != session.state) {
            throw DropboxAuthException(
              'OAuth state mismatch. Verification failed.',
            );
          }
        }
        if (uri.queryParameters.containsKey('code')) {
          return uri.queryParameters['code']!.trim();
        }
      } catch (e) {
        if (e is DropboxAuthException) {
          rethrow;
        }
      }
      final match = RegExp(r'[?&]code=([^&]+)').firstMatch(trimmed);
      if (match != null && match.group(1) != null) {
        return Uri.decodeComponent(match.group(1)!.trim());
      }
    }
    return trimmed;
  }

  /// Captures an incoming OAuth redirect code on a local loopback listener.
  /// Automatically shuts down the server upon receiving the callback, timeout, or error.
  Future<String?> captureLoopbackRedirect({
    required int port,
    required DropboxPkceSession session,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _logger.info(
        'Temporary Dropbox OAuth loopback listener started on port $port',
      );

      final completer = Completer<String?>();

      final sub = server.listen((HttpRequest request) async {
        final uri = request.uri;
        final isError = uri.queryParameters.containsKey('error');
        final errorDesc =
            uri.queryParameters['error_description'] ??
            'Authorization cancelled.';

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write('''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>KeyNest Authorization</title></head>
<body style="font-family:sans-serif;background:#0D1B2A;color:#E0E1DD;text-align:center;padding:50px;">
  <h2>${isError ? 'Authorization Cancelled' : 'Connected to KeyNest!'}</h2>
  <p>${isError ? errorDesc : 'Dropbox has authorized KeyNest. You can close this window and return to the application.'}</p>
</body>
</html>
''');
        await request.response.close();

        try {
          final code = validateRedirect(redirectUri: uri, session: session);
          if (!completer.isCompleted) {
            completer.complete(code);
          }
        } catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
        }
      });

      final timer = Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException('Dropbox OAuth loopback timed out.'),
          );
        }
      });

      final result = await completer.future;
      timer.cancel();
      await sub.cancel();
      return result;
    } catch (e) {
      _logger.warning('Loopback listener failed or timed out: $e');
      return null;
    } finally {
      if (server != null) {
        try {
          await server.close(force: true);
        } catch (_) {}
      }
    }
  }

  /// Exchanges authorization code and code_verifier for access and refresh tokens.
  Future<DropboxTokenResponse> exchangeCodeForToken({
    required String code,
    required DropboxPkceSession session,
  }) async {
    final body = <String, String>{
      'grant_type': 'authorization_code',
      'code': code.trim(),
      'client_id': session.appKey,
      'code_verifier': session.codeVerifier,
      if (session.redirectUri != null && session.redirectUri!.isNotEmpty)
        'redirect_uri': session.redirectUri!,
    };

    final response = await _httpClient.post(
      Uri.parse('https://api.dropboxapi.com/oauth2/token'),
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
      },
      body: body,
    );

    if (response.statusCode != 200) {
      final body = response.body;
      _logger.warning('Token exchange failed with HTTP ${response.statusCode}');
      try {
        final decoded = json.decode(body) as Map<String, dynamic>;
        if (decoded['error'] == 'invalid_grant') {
          throw DropboxInvalidGrantException(
            decoded['error_description'] as String? ??
                'Invalid or expired authorization code.',
          );
        }
      } catch (e) {
        if (e is DropboxInvalidGrantException) {
          rethrow;
        }
      }
      throw DropboxAuthException(
        'Failed to exchange code: HTTP ${response.statusCode}',
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return DropboxTokenResponse.fromJson(data);
  }

  /// Refreshes an expired access token using the stored refresh token.
  Future<DropboxTokenResponse> refreshAccessToken({
    required String refreshToken,
    required String appKey,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('https://api.dropboxapi.com/oauth2/token'),
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
      },
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': appKey,
      },
    );

    if (response.statusCode != 200) {
      final body = response.body;
      _logger.warning('Token refresh failed with HTTP ${response.statusCode}');
      try {
        final decoded = json.decode(body) as Map<String, dynamic>;
        if (decoded['error'] == 'invalid_grant') {
          throw DropboxInvalidGrantException(
            decoded['error_description'] as String? ??
                'Refresh token revoked or invalid.',
          );
        }
      } catch (e) {
        if (e is DropboxInvalidGrantException) {
          rethrow;
        }
      }
      throw DropboxAuthException(
        'Failed to refresh token: HTTP ${response.statusCode}',
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    // Merge previous refresh_token if response did not include a new one
    if (data['refresh_token'] == null) {
      data['refresh_token'] = refreshToken;
    }
    return DropboxTokenResponse.fromJson(data);
  }

  /// Revokes the current access/refresh token on Dropbox server during disconnect.
  Future<void> revokeToken(String accessToken) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('https://api.dropboxapi.com/2/auth/token/revoke'),
        headers: {
          'authorization': 'Bearer $accessToken',
        },
      );
      _logger.info('Token revoke response: ${response.statusCode}');
    } catch (e) {
      _logger.warning('Failed to revoke token on remote: $e');
    }
  }
}
