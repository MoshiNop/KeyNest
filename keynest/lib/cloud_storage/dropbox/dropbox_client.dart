import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:keynest/cloud_storage/dropbox/dropbox_auth.dart';
import 'package:logging/logging.dart';

final _logger = Logger('dropbox_client');

/// Exception thrown when a file upload encounters a 409 conflict on Dropbox.
class DropboxConflictException implements Exception {
  DropboxConflictException({this.message = 'Conflict during upload'});
  final String message;

  @override
  String toString() => 'DropboxConflictException: $message';
}

/// Metadata describing a remote file on Dropbox.
class DropboxFileMetadata {
  DropboxFileMetadata({
    required this.name,
    required this.pathLower,
    required this.rev,
    required this.size,
    required this.serverModified,
  });

  final String name;
  final String pathLower;
  final String rev;
  final int size;
  final DateTime serverModified;

  static DropboxFileMetadata fromJson(Map<String, dynamic> json) {
    return DropboxFileMetadata(
      name: json['name'] as String? ?? '',
      pathLower: json['path_lower'] as String? ?? '',
      rev: json['rev'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      serverModified:
          DateTime.tryParse(json['server_modified'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Result of downloading a file from Dropbox.
class DropboxDownloadResult {
  DropboxDownloadResult({
    required this.bytes,
    required this.rev,
    required this.metadata,
  });

  final Uint8List bytes;
  final String rev;
  final DropboxFileMetadata metadata;
}

/// Public API client for interacting with Dropbox over HTTPS.
///
/// Handles raw encrypted byte transfer without ever parsing, decrypting, or logging vault data.
class DropboxClient {
  DropboxClient({
    required this.appKey,
    required DropboxAuthService authService,
    required Future<String?> Function() getRefreshToken,
    required Future<void> Function(String refreshToken) saveRefreshToken,
    required Future<void> Function() clearCredentials,
    void Function()? onAuthenticationLost,
    http.Client? httpClient,
  }) : _authService = authService,
       _getRefreshToken = getRefreshToken,
       _saveRefreshToken = saveRefreshToken,
       _clearCredentials = clearCredentials,
       _onAuthenticationLost = onAuthenticationLost,
       _httpClient = httpClient ?? http.Client();

  final String appKey;
  final DropboxAuthService _authService;
  final Future<String?> Function() _getRefreshToken;
  final Future<void> Function(String refreshToken) _saveRefreshToken;
  final Future<void> Function() _clearCredentials;
  final void Function()? _onAuthenticationLost;
  final http.Client _httpClient;

  String? _inMemoryAccessToken;
  DateTime? _tokenExpiresAt;

  static const _contentEndpointDownload =
      'https://content.dropboxapi.com/2/files/download';
  static const _contentEndpointUpload =
      'https://content.dropboxapi.com/2/files/upload';
  static const _apiEndpointGetMetadata =
      'https://api.dropboxapi.com/2/files/get_metadata';
  static const _apiEndpointRevoke =
      'https://api.dropboxapi.com/2/auth/token/revoke';

  /// Sets active access token directly (e.g. right after OAuth exchange).
  void setInMemoryToken(DropboxTokenResponse tokenResponse) {
    _inMemoryAccessToken = tokenResponse.accessToken;
    _tokenExpiresAt = tokenResponse.expiresAt;
  }

  /// Ensures an active, unexpired in-memory access token is ready.
  Future<String> _ensureValidAccessToken() async {
    final now = DateTime.now();
    if (_inMemoryAccessToken != null &&
        _tokenExpiresAt != null &&
        now.isBefore(_tokenExpiresAt!.subtract(const Duration(seconds: 60)))) {
      return _inMemoryAccessToken!;
    }

    final refreshToken = await _getRefreshToken();
    if (refreshToken == null || refreshToken.trim().isEmpty) {
      _onAuthenticationLost?.call();
      throw DropboxInvalidGrantException(
        'No refresh token available. User must log in.',
      );
    }

    try {
      final tokenResponse = await _authService.refreshAccessToken(
        refreshToken: refreshToken,
        appKey: appKey,
      );
      setInMemoryToken(tokenResponse);
      if (tokenResponse.refreshToken != null &&
          tokenResponse.refreshToken != refreshToken) {
        await _saveRefreshToken(tokenResponse.refreshToken!);
      }
      return _inMemoryAccessToken!;
    } on DropboxInvalidGrantException {
      await _clearCredentials();
      _onAuthenticationLost?.call();
      rethrow;
    }
  }

  /// Executes an HTTP request with automatic 401 refresh-and-retry,
  /// 429 rate-limit handling, and network exception management.
  Future<http.Response> _sendWithAuth(
    Future<http.Response> Function(String token) executeRequest,
  ) async {
    String token = await _ensureValidAccessToken();

    http.Response response;
    try {
      response = await executeRequest(
        token,
      ).timeout(const Duration(seconds: 45));
    } on SocketException catch (e) {
      _logger.warning('Network unreachable during Dropbox call: $e');
      throw const SocketException('No network connection to Dropbox.');
    } on TimeoutException {
      _logger.warning('Timeout during Dropbox call.');
      throw TimeoutException('Connection to Dropbox timed out.');
    }

    // Handle 401 Unauthorized by refreshing token and retrying once
    if (response.statusCode == 401) {
      _logger.info('Received 401 from Dropbox. Attempting token refresh...');
      final refreshToken = await _getRefreshToken();
      if (refreshToken == null) {
        _onAuthenticationLost?.call();
        throw DropboxInvalidGrantException('No refresh token found on 401.');
      }

      try {
        final refreshed = await _authService.refreshAccessToken(
          refreshToken: refreshToken,
          appKey: appKey,
        );
        setInMemoryToken(refreshed);
        token = refreshed.accessToken;
        response = await executeRequest(
          token,
        ).timeout(const Duration(seconds: 45));
      } on DropboxInvalidGrantException {
        await _clearCredentials();
        _onAuthenticationLost?.call();
        rethrow;
      }
    }

    // Handle 429 Rate Limit
    if (response.statusCode == 429) {
      final retryAfterStr = response.headers['retry-after'];
      final retryAfterSec = int.tryParse(retryAfterStr ?? '') ?? 2;
      _logger.warning(
        'Dropbox rate limited (429). Retrying after $retryAfterSec s.',
      );
      if (retryAfterSec <= 10) {
        await Future<void>.delayed(Duration(seconds: retryAfterSec));
        return executeRequest(token).timeout(const Duration(seconds: 45));
      }
      throw HttpException(
        'Dropbox rate limit reached. Retry after $retryAfterSec seconds.',
      );
    }

    return response;
  }

  /// Checks remote metadata for the vault file. Returns `null` if the file doesn't exist.
  Future<DropboxFileMetadata?> getMetadata(String vaultFilename) async {
    final path = _normalizePath(vaultFilename);
    final response = await _sendWithAuth((token) {
      return _httpClient.post(
        Uri.parse(_apiEndpointGetMetadata),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: json.encode({'path': path}),
      );
    });

    if (response.statusCode == 200) {
      final jsonMap = json.decode(response.body) as Map<String, dynamic>;
      return DropboxFileMetadata.fromJson(jsonMap);
    }

    // 409 means path not found (file does not exist remotely yet)
    if (response.statusCode == 409) {
      return null;
    }

    throw HttpException(
      'Failed to get metadata for $vaultFilename: HTTP ${response.statusCode}',
    );
  }

  /// Downloads raw encrypted KDBX bytes and the remote revision identifier.
  Future<DropboxDownloadResult> downloadVault(String vaultFilename) async {
    final path = _normalizePath(vaultFilename);
    final response = await _sendWithAuth((token) {
      return _httpClient.post(
        Uri.parse(_contentEndpointDownload),
        headers: {
          'Authorization': 'Bearer $token',
          'Dropbox-API-Arg': json.encode({'path': path}),
        },
      );
    });

    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to download vault: HTTP ${response.statusCode} (${response.reasonPhrase})',
      );
    }

    final resultHeader = response.headers['dropbox-api-result'];
    if (resultHeader == null) {
      throw const FormatException(
        'Missing Dropbox-API-Result header in download response.',
      );
    }

    final metadataMap = json.decode(resultHeader) as Map<String, dynamic>;
    final metadata = DropboxFileMetadata.fromJson(metadataMap);
    final bytes = response.bodyBytes;

    return DropboxDownloadResult(
      bytes: bytes,
      rev: metadata.rev,
      metadata: metadata,
    );
  }

  /// Uploads raw encrypted KDBX bytes.
  ///
  /// If [expectedRev] is null, uploads with mode 'add'.
  /// Otherwise uploads with mode 'update' against [expectedRev].
  ///
  /// Throws [DropboxConflictException] if a 409 conflict is returned.
  Future<String> uploadVault({
    required String vaultFilename,
    required Uint8List bytes,
    String? expectedRev,
  }) async {
    final path = _normalizePath(vaultFilename);
    final Map<String, dynamic> apiArg = {
      'path': path,
      'autorename': false,
      'mute': true,
    };

    if (expectedRev != null && expectedRev.isNotEmpty) {
      apiArg['mode'] = {
        '.tag': 'update',
        'update': expectedRev,
      };
    } else {
      apiArg['mode'] = 'add';
    }

    final response = await _sendWithAuth((token) {
      return _httpClient.post(
        Uri.parse(_contentEndpointUpload),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/octet-stream',
          'Dropbox-API-Arg': json.encode(apiArg),
        },
        body: bytes,
      );
    });

    if (response.statusCode == 409) {
      _logger.warning('Upload returned 409 conflict for $vaultFilename.');
      throw DropboxConflictException(
        message: 'Remote vault modified since rev $expectedRev',
      );
    }

    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to upload vault: HTTP ${response.statusCode} (${response.reasonPhrase})',
      );
    }

    final resJson = json.decode(response.body) as Map<String, dynamic>;
    final newRev = resJson['rev'] as String? ?? '';
    return newRev;
  }

  static const _apiEndpointDelete =
      'https://api.dropboxapi.com/2/files/delete_v2';

  /// Deletes a file or folder on Dropbox at [pathOrFilename].
  Future<void> deleteFile(String pathOrFilename) async {
    final path = _normalizePath(pathOrFilename);
    final response = await _sendWithAuth((token) {
      return _httpClient.post(
        Uri.parse(_apiEndpointDelete),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: json.encode({'path': path}),
      );
    });

    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to delete Dropbox file $pathOrFilename: HTTP ${response.statusCode}',
      );
    }
  }

  static const _apiEndpointMove = 'https://api.dropboxapi.com/2/files/move_v2';

  /// Moves or renames a file on Dropbox from [fromFilename] to [toFilename].
  Future<DropboxFileMetadata> moveFile({
    required String fromFilename,
    required String toFilename,
  }) async {
    final fromPath = _normalizePath(fromFilename);
    final toPath = _normalizePath(toFilename);
    final response = await _sendWithAuth((token) {
      return _httpClient.post(
        Uri.parse(_apiEndpointMove),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'from_path': fromPath,
          'to_path': toPath,
          'autorename': false,
        }),
      );
    });

    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to rename Dropbox file from $fromFilename to $toFilename: HTTP ${response.statusCode}',
      );
    }

    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    final metadata = jsonMap['metadata'] as Map<String, dynamic>? ?? jsonMap;
    return DropboxFileMetadata.fromJson(metadata);
  }

  /// Revokes remote token and resets in-memory credentials.
  Future<void> revokeToken() async {
    final token = _inMemoryAccessToken;
    _inMemoryAccessToken = null;
    _tokenExpiresAt = null;

    if (token != null && token.isNotEmpty) {
      try {
        await _httpClient.post(
          Uri.parse(_apiEndpointRevoke),
          headers: {'Authorization': 'Bearer $token'},
        );
      } catch (e) {
        _logger.warning('Remote token revoke ignored: $e');
      }
    }
  }

  /// Fetches the current user's Dropbox account information (display name and email).
  Future<Map<String, String>> getCurrentAccount() async {
    final response = await _sendWithAuth((token) {
      return _httpClient.post(
        Uri.parse('https://api.dropboxapi.com/2/users/get_current_account'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
    });

    if (response.statusCode == 200) {
      final jsonMap = json.decode(response.body) as Map<String, dynamic>;
      final email = jsonMap['email'] as String? ?? '';
      final nameMap = jsonMap['name'] as Map<String, dynamic>?;
      final displayName = nameMap?['display_name'] as String? ?? '';
      return {
        'email': email,
        'displayName': displayName,
      };
    }
    throw HttpException(
      'Failed to fetch Dropbox account details: HTTP ${response.statusCode}',
    );
  }

  /// Lists all files in the specified folder (defaults to '/KeyNest').
  /// If the folder does not exist yet (409), returns an empty list.
  Future<List<DropboxFileMetadata>> listFiles({
    String folderPath = '/KeyNest',
  }) async {
    final path = folderPath == '/' ? '' : folderPath;
    final response = await _sendWithAuth((token) {
      return _httpClient.post(
        Uri.parse('https://api.dropboxapi.com/2/files/list_folder'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'path': path,
          'recursive': false,
          'include_deleted': false,
        }),
      );
    });

    if (response.statusCode == 200) {
      final jsonMap = json.decode(response.body) as Map<String, dynamic>;
      final entries = jsonMap['entries'] as List<dynamic>? ?? [];
      return entries
          .where((e) => (e as Map<String, dynamic>)['.tag'] == 'file')
          .map((e) => DropboxFileMetadata.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    // 409 means path not found (e.g. /KeyNest doesn't exist yet)
    if (response.statusCode == 409) {
      return [];
    }

    throw HttpException(
      'Failed to list Dropbox folder $folderPath: HTTP ${response.statusCode}',
    );
  }

  String _normalizePath(String filename) {
    if (filename.startsWith('/')) {
      return filename;
    }
    return '/$filename';
  }
}
