import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_auth.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

final _logger = Logger('gdrive_client');

/// Represents metadata for a file in Google Drive.
class GoogleDriveFileMetadata {
  GoogleDriveFileMetadata({
    required this.id,
    required this.name,
    this.version,
    this.md5Checksum,
    this.modifiedTime,
    this.sizeBytes,
    this.trashed,
    this.parents,
    this.mimeType,
  });

  factory GoogleDriveFileMetadata.fromJson(Map<String, dynamic> json) {
    int? ver;
    final v = json['version'];
    if (v is int) {
      ver = v;
    } else if (v is String) {
      ver = int.tryParse(v);
    }

    int? size;
    final s = json['size'];
    if (s is int) {
      size = s;
    } else if (s is String) {
      size = int.tryParse(s);
    }

    DateTime? mod;
    final m = json['modifiedTime'];
    if (m is String) {
      mod = DateTime.tryParse(m);
    }

    bool? trashed;
    final t = json['trashed'];
    if (t is bool) {
      trashed = t;
    } else if (t is String) {
      trashed = t.toLowerCase() == 'true';
    }

    List<String>? parents;
    final p = json['parents'];
    if (p is List) {
      parents = p.map((e) => e.toString()).toList();
    }

    return GoogleDriveFileMetadata(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      version: ver,
      md5Checksum: json['md5Checksum'] as String?,
      modifiedTime: mod,
      sizeBytes: size,
      trashed: trashed,
      parents: parents,
      mimeType: json['mimeType'] as String?,
    );
  }

  final String id;
  final String name;
  final int? version;
  final String? md5Checksum;
  final DateTime? modifiedTime;
  final int? sizeBytes;
  final bool? trashed;
  final List<String>? parents;
  final String? mimeType;
}

/// Represents a single file revision in Google Drive.
class GoogleDriveRevision {
  GoogleDriveRevision({
    required this.id,
    this.modifiedTime,
    this.md5Checksum,
    this.sizeBytes,
  });

  factory GoogleDriveRevision.fromJson(Map<String, dynamic> json) {
    int? size;
    final s = json['size'];
    if (s is int) {
      size = s;
    } else if (s is String) {
      size = int.tryParse(s);
    }

    DateTime? mod;
    final m = json['modifiedTime'];
    if (m is String) {
      mod = DateTime.tryParse(m);
    }

    return GoogleDriveRevision(
      id: json['id'] as String,
      modifiedTime: mod,
      md5Checksum: json['md5Checksum'] as String?,
      sizeBytes: size,
    );
  }

  final String id;
  final DateTime? modifiedTime;
  final String? md5Checksum;
  final int? sizeBytes;
}

/// Base Google Drive Client Exception.
class GoogleDriveClientException implements Exception {
  GoogleDriveClientException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'GoogleDriveClientException: $message${statusCode != null ? ' (HTTP $statusCode)' : ''}';
}

/// Thrown when file is missing (HTTP 404).
class GoogleDriveFileNotFoundException extends GoogleDriveClientException {
  GoogleDriveFileNotFoundException(super.message, {super.statusCode = 404});
}

/// Thrown when Drive quota is exceeded.
class GoogleDriveQuotaExceededException extends GoogleDriveClientException {
  GoogleDriveQuotaExceededException(super.message, {super.statusCode = 403});
}

typedef GoogleDriveQuotaException = GoogleDriveQuotaExceededException;

/// HTTP Client wrapper for Google Drive REST API v3
class GoogleDriveClient {
  GoogleDriveClient({
    required this.tokenSource,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final GoogleDriveTokenSource tokenSource;
  final http.Client _httpClient;

  static const String _apiBase = 'https://www.googleapis.com/drive/v3';
  static const String _uploadBase =
      'https://www.googleapis.com/upload/drive/v3';

  /// Performs an HTTP request with automatic 401 retry, 429/5xx exponential backoff, and quota checks.
  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function(String token) sendFn, {
    int maxRetries = 3,
  }) async {
    int attempt = 0;
    while (true) {
      attempt++;
      final token = await tokenSource.getAccessToken();
      if (token == null) {
        throw GoogleDriveClientException('Not signed in to Google Drive');
      }

      http.Response response;
      try {
        response = await sendFn(token);
      } on SocketException {
        rethrow;
      } on http.ClientException {
        rethrow;
      } catch (e) {
        if (attempt >= maxRetries) {
          rethrow;
        }
        await Future<void>.delayed(
          Duration(milliseconds: 500 * (1 << attempt)),
        );
        continue;
      }

      // 401 Unauthorized -> Refresh token and retry once
      if (response.statusCode == 401) {
        _logger.info('Received 401 Unauthorized. Refreshing access token...');
        await tokenSource.clearCachedAccessToken();
        final refreshedToken = await tokenSource.getAccessToken(
          forceRefresh: true,
        );
        if (refreshedToken == null) {
          throw GoogleDriveInvalidGrantException(
            'Failed to refresh Google Drive token.',
          );
        }
        return await sendFn(refreshedToken);
      }

      // 403 Quota or Rate Limit
      if (response.statusCode == 403) {
        final body = response.body;
        if (body.contains('storageQuotaExceeded') ||
            body.contains('quotaExceeded')) {
          throw GoogleDriveQuotaExceededException(
            'Google Drive storage quota exceeded. Please free up space in your Google account.',
          );
        }
        if (body.contains('rateLimitExceeded') ||
            body.contains('userRateLimitExceeded')) {
          if (attempt >= maxRetries) {
            throw GoogleDriveClientException(
              'Rate limit exceeded: ${response.statusCode}',
            );
          }
          final retryAfterSec = _parseRetryAfter(response);
          final delayMs = retryAfterSec != null
              ? retryAfterSec * 1000
              : (1000 * (1 << attempt) + Random().nextInt(500));
          await Future<void>.delayed(Duration(milliseconds: delayMs));
          continue;
        }
      }

      // 429 Too Many Requests
      if (response.statusCode == 429) {
        if (attempt >= maxRetries) {
          throw GoogleDriveClientException(
            'Too many requests: ${response.statusCode}',
          );
        }
        final retryAfterSec = _parseRetryAfter(response);
        final delayMs = retryAfterSec != null
            ? retryAfterSec * 1000
            : (1000 * (1 << attempt) + Random().nextInt(500));
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        continue;
      }

      // 5xx Server Error
      if (response.statusCode >= 500 && response.statusCode < 600) {
        if (attempt >= maxRetries) {
          throw GoogleDriveClientException(
            'Server error: HTTP ${response.statusCode}',
          );
        }
        final delayMs = 1000 * (1 << attempt) + Random().nextInt(500);
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        continue;
      }

      return response;
    }
  }

  int? _parseRetryAfter(http.Response response) {
    final header = response.headers['retry-after'];
    if (header != null) {
      return int.tryParse(header);
    }
    return null;
  }

  // API Methods
  /// Finds files matching [vaultFilename] in the appDataFolder.
  /// If multiple matches exist, returns them sorted newest first.
  Future<List<GoogleDriveFileMetadata>> findFilesInAppDataFolder(
    String vaultFilename,
  ) async {
    final query = "name = '$vaultFilename' and trashed = false";
    final url = Uri.parse('$_apiBase/files').replace(
      queryParameters: {
        'spaces': 'appDataFolder',
        'q': query,
        'fields': 'files(id,name,version,md5Checksum,modifiedTime,size)',
      },
    );

    final response = await _sendWithRetry((token) {
      return _httpClient.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
        },
      );
    });

    if (response.statusCode != 200) {
      throw GoogleDriveClientException(
        'Failed to search appDataFolder: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final rawFiles = data['files'] as List<dynamic>? ?? [];

    final list = rawFiles
        .map((f) => GoogleDriveFileMetadata.fromJson(f as Map<String, dynamic>))
        .toList();

    // Sort newest modifiedTime first
    list.sort((a, b) {
      final tA = a.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tB = b.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
      return tB.compareTo(tA);
    });

    return list;
  }

  static const String keyNestFolderName = 'KeyNest';
  static const String folderMimeType = 'application/vnd.google-apps.folder';

  final Lock _folderLock = Lock();

  /// Reliably discovers or creates the regular visible 'KeyNest' folder in the user's Google Drive root.
  /// Prevents duplicate folder creation during concurrent requests and caches the resolved folder ID.
  Future<String> getOrCreateKeyNestFolder({
    GoogleDriveSyncStateStore? stateStore,
  }) async {
    return await _folderLock.synchronized(() async {
      // 1. Check local persistent cache
      if (stateStore != null) {
        final cachedFolderId = await stateStore.getKeyNestFolderId();
        if (cachedFolderId != null && cachedFolderId.isNotEmpty) {
          try {
            final meta = await getFileMetadata(cachedFolderId);
            if (meta != null && meta.trashed != true) {
              return cachedFolderId;
            }
          } catch (e) {
            _logger.warning('Failed to verify cached KeyNest folder: $e');
          }
          await stateStore.setKeyNestFolderId(null);
        }
      }

      // 2. Query Drive root for an existing KeyNest folder
      final query =
          "name = '$keyNestFolderName' and mimeType = '$folderMimeType' and 'root' in parents and trashed = false";
      final url = Uri.parse('$_apiBase/files').replace(
        queryParameters: {
          'q': query,
          'fields':
              'files(id,name,version,md5Checksum,modifiedTime,size,trashed,parents,createdTime)',
        },
      );

      final response = await _sendWithRetry((token) {
        return _httpClient.get(
          url,
          headers: {'Authorization': 'Bearer $token'},
        );
      });

      if (response.statusCode != 200) {
        throw GoogleDriveClientException(
          'Failed to search for KeyNest folder: HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final rawFiles = data['files'] as List<dynamic>? ?? [];

      if (rawFiles.isNotEmpty) {
        final existingFolder = GoogleDriveFileMetadata.fromJson(
          rawFiles.first as Map<String, dynamic>,
        );
        if (rawFiles.length > 1) {
          _logger.warning(
            'Found multiple KeyNest folders (${rawFiles.length}). Using ${existingFolder.id}.',
          );
        }
        if (stateStore != null) {
          await stateStore.setKeyNestFolderId(existingFolder.id);
        }
        return existingFolder.id;
      }

      // 3. Folder does not exist, create it in Drive root
      _logger.info(
        'KeyNest visible folder not found in Drive root. Creating folder...',
      );
      final createUrl = Uri.parse('$_apiBase/files').replace(
        queryParameters: {
          'fields':
              'id,name,version,md5Checksum,modifiedTime,size,trashed,parents',
        },
      );

      final bodyJson = json.encode({
        'name': keyNestFolderName,
        'mimeType': folderMimeType,
        'parents': ['root'],
      });

      final createResponse = await _sendWithRetry((token) {
        return _httpClient.post(
          createUrl,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=UTF-8',
          },
          body: bodyJson,
        );
      });

      if (createResponse.statusCode != 200 &&
          createResponse.statusCode != 201) {
        throw GoogleDriveClientException(
          'Failed to create KeyNest folder: HTTP ${createResponse.statusCode}',
          statusCode: createResponse.statusCode,
        );
      }

      final createdData =
          json.decode(createResponse.body) as Map<String, dynamic>;
      final createdFolder = GoogleDriveFileMetadata.fromJson(createdData);
      _logger.info('Created KeyNest folder with ID: ${createdFolder.id}');

      if (stateStore != null) {
        await stateStore.setKeyNestFolderId(createdFolder.id);
      }
      return createdFolder.id;
    });
  }

  /// Finds files matching [vaultFilename] (or all files if null) in [folderId].
  /// Results are sorted newest modifiedTime first.
  Future<List<GoogleDriveFileMetadata>> findFilesInFolder(
    String folderId, [
    String? vaultFilename,
  ]) async {
    final query = vaultFilename != null
        ? "name = '$vaultFilename' and '$folderId' in parents and trashed = false"
        : "'$folderId' in parents and trashed = false";

    final url = Uri.parse('$_apiBase/files').replace(
      queryParameters: {
        'q': query,
        'fields':
            'files(id,name,version,md5Checksum,modifiedTime,size,trashed,parents)',
      },
    );

    final response = await _sendWithRetry((token) {
      return _httpClient.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );
    });

    if (response.statusCode != 200) {
      throw GoogleDriveClientException(
        'Failed to search files in folder $folderId: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final rawFiles = data['files'] as List<dynamic>? ?? [];

    final list = rawFiles
        .map((f) => GoogleDriveFileMetadata.fromJson(f as Map<String, dynamic>))
        .toList();

    list.sort((a, b) {
      final tA = a.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tB = b.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
      return tB.compareTo(tA);
    });

    return list;
  }

  /// Copies an existing file directly into [destinationFolderId].
  /// Useful for copying files between spaces/folders within Google Drive.
  Future<GoogleDriveFileMetadata> copyFile({
    required String fileId,
    required String destinationFolderId,
    String? newName,
  }) async {
    final url = Uri.parse('$_apiBase/files/$fileId/copy').replace(
      queryParameters: {
        'fields':
            'id,name,version,md5Checksum,modifiedTime,size,trashed,parents',
      },
    );

    final bodyMap = <String, dynamic>{
      'parents': [destinationFolderId],
    };
    if (newName != null) {
      bodyMap['name'] = newName;
    }
    final bodyJson = json.encode(bodyMap);

    final response = await _sendWithRetry((token) {
      return _httpClient.post(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: bodyJson,
      );
    });

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw GoogleDriveClientException(
        'Failed to copy file $fileId to folder $destinationFolderId: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return GoogleDriveFileMetadata.fromJson(data);
  }

  /// Safely renames an existing Drive file [fileId] to [newName] without changing its ID or parents.
  Future<GoogleDriveFileMetadata> renameFile({
    required String fileId,
    required String newName,
  }) async {
    final url = Uri.parse('$_apiBase/files/$fileId').replace(
      queryParameters: {
        'fields':
            'id,name,version,md5Checksum,modifiedTime,size,trashed,parents,mimeType',
      },
    );

    final bodyJson = json.encode({'name': newName});

    final response = await _sendWithRetry((token) {
      return _httpClient.patch(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: bodyJson,
      );
    });

    if (response.statusCode != 200) {
      throw GoogleDriveClientException(
        'Failed to rename Drive file $fileId to $newName: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return GoogleDriveFileMetadata.fromJson(data);
  }

  /// Gets metadata for file [fileId].
  Future<GoogleDriveFileMetadata?> getFileMetadata(String fileId) async {
    final url = Uri.parse('$_apiBase/files/$fileId').replace(
      queryParameters: {
        'fields':
            'id,name,version,md5Checksum,modifiedTime,size,trashed,parents,mimeType',
      },
    );

    final response = await _sendWithRetry((token) {
      return _httpClient.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
        },
      );
    });

    if (response.statusCode == 404) {
      return null;
    }

    if (response.statusCode != 200) {
      throw GoogleDriveClientException(
        'Failed to fetch file metadata: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return GoogleDriveFileMetadata.fromJson(data);
  }

  /// Permanently deletes file [fileId] from Google Drive.
  Future<void> deleteFile(String fileId) async {
    final url = Uri.parse('$_apiBase/files/$fileId');
    final response = await _sendWithRetry((token) {
      return _httpClient.delete(
        url,
        headers: {
          'Authorization': 'Bearer $token',
        },
      );
    });

    if (response.statusCode == 404) {
      throw GoogleDriveFileNotFoundException('Remote file not found ($fileId)');
    }

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw GoogleDriveClientException(
        'Failed to delete file ($fileId): HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
  }

  /// Downloads raw bytes of file [fileId].
  Future<Uint8List> downloadFile(String fileId) async {
    final url = Uri.parse('$_apiBase/files/$fileId').replace(
      queryParameters: {
        'alt': 'media',
      },
    );

    final response = await _sendWithRetry((token) {
      return _httpClient.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
        },
      );
    });

    if (response.statusCode == 404) {
      throw GoogleDriveFileNotFoundException('Remote file not found ($fileId)');
    }

    if (response.statusCode != 200) {
      throw GoogleDriveClientException(
        'Failed to download file: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    return response.bodyBytes;
  }

  /// First upload: creates file in [folderId] (defaults to appDataFolder if null) using multipart upload.
  Future<GoogleDriveFileMetadata> createInitialVault({
    required String vaultFilename,
    required Uint8List bytes,
    String? folderId,
  }) async {
    final parentFolder = folderId ?? 'appDataFolder';
    final boundary =
        '----KeyNestDriveBoundary${DateTime.now().millisecondsSinceEpoch}';
    final metadataJson = json.encode({
      'name': vaultFilename,
      'parents': [parentFolder],
    });

    final delimiter = '--$boundary\r\n';
    final closeDelimiter = '\r\n--$boundary--';

    final bodyBytes = BytesBuilder();
    // Part 1: Metadata
    bodyBytes.add(utf8.encode(delimiter));
    bodyBytes.add(
      utf8.encode('Content-Type: application/json; charset=UTF-8\r\n\r\n'),
    );
    bodyBytes.add(utf8.encode(metadataJson));
    bodyBytes.add(utf8.encode('\r\n'));

    // Part 2: Media
    bodyBytes.add(utf8.encode(delimiter));
    bodyBytes.add(
      utf8.encode('Content-Type: application/octet-stream\r\n\r\n'),
    );
    bodyBytes.add(bytes);
    bodyBytes.add(utf8.encode(closeDelimiter));

    final fullPayload = bodyBytes.toBytes();

    final url = Uri.parse('$_uploadBase/files').replace(
      queryParameters: {
        'uploadType': 'multipart',
        'fields': 'id,name,version,md5Checksum,modifiedTime,size',
      },
    );

    final response = await _sendWithRetry((token) {
      return _httpClient.post(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'multipart/related; boundary=$boundary',
          'Content-Length': fullPayload.length.toString(),
        },
        body: fullPayload,
      );
    });

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw GoogleDriveClientException(
        'Failed to create vault in Drive: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return GoogleDriveFileMetadata.fromJson(data);
  }

  /// Updates existing file [fileId] with [bytes].
  /// Uses media upload or resumable upload for larger files (> 5MB).
  Future<GoogleDriveFileMetadata> updateVault({
    required String fileId,
    required Uint8List bytes,
  }) async {
    if (bytes.lengthInBytes > 5 * 1024 * 1024) {
      return await _resumableUpdateVault(fileId: fileId, bytes: bytes);
    }

    final url = Uri.parse('$_uploadBase/files/$fileId').replace(
      queryParameters: {
        'uploadType': 'media',
        'fields': 'id,name,version,md5Checksum,modifiedTime,size',
      },
    );

    final response = await _sendWithRetry((token) {
      return _httpClient.patch(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/octet-stream',
          'Content-Length': bytes.length.toString(),
        },
        body: bytes,
      );
    });

    if (response.statusCode == 404) {
      throw GoogleDriveFileNotFoundException(
        'Vault file not found for update ($fileId)',
      );
    }

    if (response.statusCode != 200) {
      throw GoogleDriveClientException(
        'Failed to update vault in Drive: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return GoogleDriveFileMetadata.fromJson(data);
  }

  /// Resumable upload for files larger than 5 MB.
  Future<GoogleDriveFileMetadata> _resumableUpdateVault({
    required String fileId,
    required Uint8List bytes,
  }) async {
    final startUrl = Uri.parse('$_uploadBase/files/$fileId').replace(
      queryParameters: {
        'uploadType': 'resumable',
        'fields': 'id,name,version,md5Checksum,modifiedTime,size',
      },
    );

    final initResponse = await _sendWithRetry((token) {
      return _httpClient.patch(
        startUrl,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json; charset=UTF-8',
          'X-Upload-Content-Type': 'application/octet-stream',
          'X-Upload-Content-Length': bytes.length.toString(),
        },
      );
    });

    if (initResponse.statusCode != 200) {
      throw GoogleDriveClientException(
        'Failed to initiate resumable upload: HTTP ${initResponse.statusCode}',
        statusCode: initResponse.statusCode,
      );
    }

    final uploadLocation = initResponse.headers['location'];
    if (uploadLocation == null) {
      throw GoogleDriveClientException(
        'No upload location header returned by Drive.',
      );
    }

    final uploadResponse = await _sendWithRetry((token) {
      return _httpClient.put(
        Uri.parse(uploadLocation),
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': bytes.length.toString(),
        },
        body: bytes,
      );
    });

    if (uploadResponse.statusCode != 200 && uploadResponse.statusCode != 201) {
      throw GoogleDriveClientException(
        'Failed to finish resumable upload: HTTP ${uploadResponse.statusCode}',
        statusCode: uploadResponse.statusCode,
      );
    }

    final data = json.decode(uploadResponse.body) as Map<String, dynamic>;
    return GoogleDriveFileMetadata.fromJson(data);
  }

  /// Lists revisions for file [fileId] (for race window recovery).
  Future<List<GoogleDriveRevision>> listRevisions(String fileId) async {
    final url = Uri.parse('$_apiBase/files/$fileId/revisions').replace(
      queryParameters: {
        'fields': 'revisions(id,modifiedTime,md5Checksum,size)',
      },
    );

    final response = await _sendWithRetry((token) {
      return _httpClient.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
        },
      );
    });

    if (response.statusCode != 200) {
      _logger.warning('Failed to list revisions: HTTP ${response.statusCode}');
      return [];
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final rawRevs = data['revisions'] as List<dynamic>? ?? [];
    return rawRevs
        .map((r) => GoogleDriveRevision.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Downloads specific revision [revisionId] of file [fileId].
  Future<Uint8List?> downloadRevision(String fileId, String revisionId) async {
    final url = Uri.parse('$_apiBase/files/$fileId/revisions/$revisionId')
        .replace(
          queryParameters: {
            'alt': 'media',
          },
        );

    final response = await _sendWithRetry((token) {
      return _httpClient.get(
        url,
        headers: {
          'Authorization': 'Bearer $token',
        },
      );
    });

    if (response.statusCode != 200) {
      _logger.warning(
        'Failed to download revision $revisionId: HTTP ${response.statusCode}',
      );
      return null;
    }

    return response.bodyBytes;
  }

  /// Computes the MD5 hex string of a byte list.
  static String computeMd5(Uint8List bytes) {
    return md5.convert(bytes).toString();
  }
}
