import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/storage_exception.dart';
import 'package:keynest/cloud_storage/cloud_config_store.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_auth.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_client.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_models.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_engine.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_state.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('keynest.dropbox_provider');

@NonNls
const _METADATA_KEY_DROPBOX_DATA = 'dropbox.file_metadata';

class DropboxProvider extends CloudStorageProvider {
  DropboxProvider({
    required this.env,
    required super.helper,
    this.onAuthChanged,
    http.Client? httpClient,
  }) : _httpClient = httpClient {
    _initDropboxComponents();
  }

  @NonNls
  @override
  final String id = 'DropboxProvider';

  final Env env;
  final VoidCallback? onAuthChanged;
  final http.Client? _httpClient;

  bool _isAuthorized = false;
  String? connectedAccountEmail;
  String? connectedDisplayName;

  late DropboxAuthService authService;
  late DropboxSyncStateStore stateStore;
  late DropboxClient dropboxClient;
  late DropboxSyncEngine syncEngine;

  @override
  bool get isAuthenticated => _isAuthorized;

  String get configuredAppKey {
    final userKey = CloudConfigStore.instance.dropboxAppKey;
    if (userKey != null && userKey.isNotEmpty) {
      return userKey;
    }
    return env.secrets?.dropboxKey ?? kDefaultDropboxAppKey;
  }

  String? get configuredRedirectUri {
    const customDefine = String.fromEnvironment(
      'KEYNEST_DROPBOX_REDIRECT_URI',
      defaultValue: String.fromEnvironment(
        'DROPBOX_REDIRECT_URI',
        defaultValue: '',
      ),
    );
    if (customDefine.isNotEmpty) {
      return customDefine;
    }
    return kDefaultDropboxRedirectUri.isNotEmpty
        ? kDefaultDropboxRedirectUri
        : null;
  }

  /// Reinitializes Dropbox components when the user updates the App Key.
  void updateConfiguredAppKey() {
    _initDropboxComponents();
  }

  Future<Map<String, dynamic>> _readExistingCredentialMap() async {
    final stored = await loadCredentials();
    if (stored == null || stored.trim().isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = json.decode(stored);
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> _persistTokenResponse(DropboxTokenResponse tokens) async {
    final existing = await _readExistingCredentialMap();
    final updated = <String, dynamic>{
      ...existing,
      ...tokens.toJson(),
      if (connectedAccountEmail != null && connectedAccountEmail!.isNotEmpty)
        'email': connectedAccountEmail,
      if (connectedDisplayName != null && connectedDisplayName!.isNotEmpty)
        'displayName': connectedDisplayName,
    };
    await storeCredentials(json.encode(updated));
  }

  void _initDropboxComponents() {
    authService = DropboxAuthService(httpClient: _httpClient);
    stateStore = DropboxSyncStateStore(
      pathUtils: helper.pathUtil is PathUtils
          ? helper.pathUtil as PathUtils
          : PathUtils(),
    );
    dropboxClient = DropboxClient(
      appKey: configuredAppKey,
      authService: authService,
      httpClient: _httpClient,
      getRefreshToken: () async {
        final stored = await loadCredentials();
        if (stored == null || stored.trim().isEmpty) {
          return null;
        }
        try {
          final decoded = json.decode(stored) as Map<String, dynamic>;
          return decoded['refresh_token'] as String? ??
              decoded['refreshToken'] as String? ??
              decoded['accessToken'] as String?;
        } catch (_) {
          return stored;
        }
      },
      saveRefreshToken: (newToken) async {
        final existing = await _readExistingCredentialMap();
        existing['refresh_token'] = newToken;
        if (connectedAccountEmail != null &&
            connectedAccountEmail!.isNotEmpty) {
          existing['email'] = connectedAccountEmail;
        }
        if (connectedDisplayName != null && connectedDisplayName!.isNotEmpty) {
          existing['displayName'] = connectedDisplayName;
        }
        await storeCredentials(json.encode(existing));
      },
      onTokensRefreshed: _persistTokenResponse,
      clearCredentials: () async {
        await helper.saveCredentials(id, '');
      },
      onAuthenticationLost: () {
        _isAuthorized = false;
        onAuthChanged?.call();
      },
    );
    syncEngine = DropboxSyncEngine(
      client: dropboxClient,
      stateStore: stateStore,
    );
  }

  /// Creates a PKCE authorization session for starting the OAuth flow.
  DropboxPkceSession createPkceSession({
    String? appKey,
    String? redirectUri,
  }) {
    final key = (appKey ?? configuredAppKey).trim();
    if (key.isEmpty) {
      throw DropboxAuthException(
        'Dropbox App Key is not configured. '
        'Provide KEYNEST_DROPBOX_APP_KEY via cloud_config.json (--dart-define-from-file) '
        'or configure an App Key in KeyNest Cloud Settings.',
      );
    }
    return DropboxPkceSession.create(
      appKey: key,
      redirectUri: redirectUri ?? configuredRedirectUri,
    );
  }

  /// Completes the OAuth PKCE flow using an authorization code.
  Future<void> completePkceAuth({
    required DropboxPkceSession session,
    required String code,
  }) async {
    final tokens = await authService.exchangeCodeForToken(
      code: code,
      session: session,
    );

    dropboxClient.setInMemoryToken(tokens);
    _isAuthorized = true;
    await _persistTokenResponse(tokens);

    try {
      final acct = await dropboxClient.getCurrentAccount();
      connectedAccountEmail = acct['email'];
      connectedDisplayName = acct['displayName'];
      await _persistTokenResponse(tokens);
    } catch (e) {
      _logger.fine('Could not fetch Dropbox account details: $e');
    }

    onAuthChanged?.call();
  }

  /// Completes PKCE authentication directly from the deep link redirect URI.
  Future<void> completePkceWithRedirectUri({
    required DropboxPkceSession session,
    required Uri redirectUri,
  }) async {
    final code = authService.validateRedirect(
      redirectUri: redirectUri,
      session: session,
    );
    if (code == null) {
      _logger.info('User cancelled Dropbox authorization.');
      return;
    }
    await completePkceAuth(session: session, code: code);
  }

  /// Connects with an OAuth authorization code from Dropbox (legacy/manual fallback).
  Future<void> connectWithAuthorizationCode({
    required String appKey,
    String? appSecret,
    required String code,
    String? redirectUri,
  }) async {
    final session = DropboxPkceSession(
      codeVerifier: '',
      codeChallenge: '',
      state: '',
      appKey: appKey,
      redirectUri: redirectUri ?? configuredRedirectUri,
      authorizeUrl: Uri.parse(''),
    );
    await completePkceAuth(session: session, code: code);
  }

  /// Connects directly using a Dropbox Personal Access Token (legacy fallback).
  Future<void> connectWithAccessToken(String token) async {
    final tokenResponse = DropboxTokenResponse(
      accessToken: token,
      expiresAt: DateTime.now().add(const Duration(hours: 4)),
    );
    dropboxClient.setInMemoryToken(tokenResponse);
    _isAuthorized = true;
    await _persistTokenResponse(tokenResponse);
    onAuthChanged?.call();
  }

  @override
  Future<bool> startAuth<
    RESULT extends UserAuthenticationPromptResult,
    DATA extends UserAuthenticationPromptData<RESULT>
  >(PromptUserForCode<RESULT, DATA> prompt) async {
    final session = createPkceSession();
    _logger.info('Launching PKCE authorization URL: ${session.authorizeUrl}');

    final completer = Completer<OAuthTokenResult?>();
    final typedPrompt =
        prompt as PromptUserForCode<OAuthTokenResult, OAuthTokenFlowPromptData>;
    await typedPrompt(
      UserAuthenticationPrompt(
        OAuthTokenFlowPromptData(session.authorizeUrl.toString()),
        completer.complete,
      ),
    );
    final code = (await completer.future)?.code;

    if (code == null || code.trim().isEmpty) {
      _logger.warning('User cancelled authorization.');
      return false;
    }

    await completePkceAuth(session: session, code: code.trim());
    return isAuthenticated;
  }

  Future<void> _ensureAuthenticated() async {
    if (_isAuthorized) {
      return;
    }
    final loaded = await loadSavedAuth();
    if (!loaded) {
      throw LoadFileException('Unable to load Dropbox credentials.');
    }
  }

  @override
  Future<bool> loadSavedAuth() async {
    final creds = await loadCredentials();
    if (creds == null || creds.trim().isEmpty) {
      _isAuthorized = false;
      return false;
    }

    bool hasUsableCreds = false;
    try {
      final decoded = json.decode(creds);
      if (decoded is Map<String, dynamic>) {
        connectedAccountEmail ??= decoded['email'] as String?;
        connectedDisplayName ??= decoded['displayName'] as String?;

        final accessToken = decoded['access_token'] as String? ??
            decoded['accessToken'] as String? ??
            '';
        final refreshToken = decoded['refresh_token'] as String? ??
            decoded['refreshToken'] as String?;
        DateTime? expiresAt;
        if (decoded['expires_at'] != null) {
          expiresAt = DateTime.tryParse(decoded['expires_at'] as String);
        } else if (decoded['expiration'] is int) {
          expiresAt = DateTime.fromMillisecondsSinceEpoch(
            decoded['expiration'] as int,
          );
        }

        if (accessToken.isNotEmpty) {
          dropboxClient.setInMemoryToken(
            DropboxTokenResponse(
              accessToken: accessToken,
              refreshToken: refreshToken,
              expiresAt:
                  expiresAt ?? DateTime.now().add(const Duration(hours: 4)),
            ),
          );
          hasUsableCreds = true;
        } else if (refreshToken != null && refreshToken.trim().isNotEmpty) {
          hasUsableCreds = true;
        }
      } else if (creds.trim().isNotEmpty) {
        dropboxClient.setInMemoryToken(
          DropboxTokenResponse(
            accessToken: creds.trim(),
            expiresAt: DateTime.now().add(const Duration(hours: 4)),
          ),
        );
        hasUsableCreds = true;
      }
    } catch (_) {
      dropboxClient.setInMemoryToken(
        DropboxTokenResponse(
          accessToken: creds.trim(),
          expiresAt: DateTime.now().add(const Duration(hours: 4)),
        ),
      );
      hasUsableCreds = true;
    }

    _isAuthorized = hasUsableCreds;
    if (_isAuthorized &&
        (connectedAccountEmail == null || connectedAccountEmail!.isEmpty)) {
      try {
        final acct = await dropboxClient.getCurrentAccount();
        connectedAccountEmail = acct['email'];
        connectedDisplayName = acct['displayName'];

        final existing = await _readExistingCredentialMap();
        if (existing.isNotEmpty) {
          if (connectedAccountEmail != null) {
            existing['email'] = connectedAccountEmail;
          }
          if (connectedDisplayName != null) {
            existing['displayName'] = connectedDisplayName;
          }
          await storeCredentials(json.encode(existing));
        }
      } catch (e) {
        _logger.fine('Could not fetch Dropbox account details: $e');
      }
    }
    return _isAuthorized;
  }

  @override
  Future<void> logout() async {
    _logger.info('Disconnecting from Dropbox...');
    _isAuthorized = false;
    connectedAccountEmail = null;
    connectedDisplayName = null;
    try {
      await dropboxClient.revokeToken();
    } catch (e) {
      _logger.warning('Failed to revoke remote token during disconnect: $e');
    }

    try {
      await stateStore.clearAllSyncState();
    } catch (e) {
      _logger.warning('Failed to clear sync state during disconnect: $e');
    }

    await helper.saveCredentials(id, '');
    onAuthChanged?.call();
    _logger.info('Successfully disconnected from Dropbox.');
  }

  @override
  bool get supportSearch => true;

  @override
  Future<SearchResponse> search({String name = Env.KeePassExtension}) async {
    await _ensureAuthenticated();
    final jsonData = await dropboxClient.searchRaw(name);
    final jsonResponse = FileSearchResponse.fromJson(jsonData);
    return SearchResponse(
      (srb) => srb
        ..results.addAll(
          (jsonResponse.matches ?? const []).map((responseEntity) {
            final metadata = responseEntity.metadata!.metadata!;
            return metadata.toCloudStorageEntity();
          }),
        )
        ..hasMore = jsonResponse.hasMore,
    );
  }

  @override
  Future<SearchResponse> list({CloudStorageEntity? parent}) async {
    await _ensureAuthenticated();
    final jsonData = await dropboxClient.listFolderRaw(parent?.id ?? '');
    final jsonResponse = FileListResponse.fromJson(jsonData);
    return SearchResponse(
      (srb) => srb
        ..results.addAll(
          (jsonResponse.entries ?? const []).map((m) => m.toCloudStorageEntity()),
        )
        ..hasMore = jsonResponse.hasMore,
    );
  }

  @NonNls
  @override
  String get displayName => 'Dropbox';

  @override
  FileSourceIcon get displayIcon => FileSourceIcon.dropbox;

  @override
  Future<FileContent> loadEntity(CloudStorageEntity file) async {
    await _ensureAuthenticated();
    final targetPath = file.id.isNotEmpty ? file.id : (file.path ?? '');
    try {
      final (bytes, fileMetadataJson) = await dropboxClient.downloadRaw(
        targetPath,
      );
      return FileContent(bytes, <String, dynamic>{
        _METADATA_KEY_DROPBOX_DATA: fileMetadataJson,
      });
    } on DropboxNotFoundException {
      throw LoadFileNotFoundException(
        'File was not found on Dropbox ($targetPath).',
      );
    } catch (e) {
      throw LoadFileException('Failed to download from Dropbox: $e');
    }
  }

  @override
  Future<Map<String, dynamic>> saveEntity(
    CloudStorageEntity file,
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async {
    final targetPath = file.id.isNotEmpty ? file.id : (file.path ?? '');
    return await _upload(targetPath, bytes, previousMetadata: previousMetadata);
  }

  Future<Map<String, dynamic>> _upload(
    String? filePath,
    Uint8List bytes, {
    Map<String, dynamic>? previousMetadata,
    bool update = true,
  }) async {
    await _ensureAuthenticated();
    if (filePath == null || filePath.trim().isEmpty) {
      throw StorageException.unknown('Missing Dropbox destination path.');
    }

    dynamic mode;
    if (update) {
      mode = 'overwrite';
      if (previousMetadata != null &&
          previousMetadata[_METADATA_KEY_DROPBOX_DATA] != null) {
        final fileMetadata = FileMetadata.fromJson(
          previousMetadata[_METADATA_KEY_DROPBOX_DATA] as Map<String, dynamic>,
        );
        final rev = fileMetadata.rev;
        if (rev != null && rev.isNotEmpty) {
          mode = nonNls(<String, dynamic>{
            '.tag': 'update',
            'update': rev,
          });
        }
      }
    } else {
      mode = 'add';
    }

    try {
      final metadataJson = await dropboxClient.uploadRaw(
        pathOrId: filePath,
        bytes: bytes,
        mode: mode,
      );
      return <String, dynamic>{_METADATA_KEY_DROPBOX_DATA: metadataJson};
    } on DropboxConflictException catch (e) {
      throw StorageException.conflict('Dropbox upload conflict: ${e.message}');
    } catch (e) {
      throw StorageException.unknown('Dropbox upload failed: $e');
    }
  }

  @override
  Future<FileSource> createEntity(
    CloudStorageSelectorSaveResult saveAs,
    Uint8List bytes,
  ) async {
    final parent = saveAs.parent;
    final cleanFileName = DropboxSyncEngine.ensureKdbxExtension(
      saveAs.fileName,
    );
    final String filePath;
    if (parent == null || parent.id.trim().isEmpty) {
      filePath = path.posix.join('/KeyNest', cleanFileName);
    } else {
      final parentPath = parent.id.startsWith('/')
          ? parent.id
          : '/${parent.id}';
      filePath = path.posix.join(parentPath, cleanFileName);
    }
    final wrappedMetadata = await _upload(filePath, bytes, update: false);
    final innerMetadataJson =
        wrappedMetadata[_METADATA_KEY_DROPBOX_DATA] as Map<String, dynamic>;
    final metadata = FileMetadata.fromJson(innerMetadataJson);
    return toFileSource(
      metadata.toCloudStorageEntity(),
      uuid: AppDataBloc.createUuid(),
      initialCachedContent: FileContent(bytes, wrappedMetadata),
    );
  }
}
