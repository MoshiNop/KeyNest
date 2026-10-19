import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:logging/logging.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:path/path.dart' as path;
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('keynest.dropbox_provider');

@NonNls
const _METADATA_KEY_DROPBOX_DATA = 'dropbox.file_metadata';

@NonNls
const _HEADER_DOWNLOAD_METADATA = 'Dropbox-API-Result';

class DropboxProvider extends CloudStorageProviderClientBase<oauth2.Client> {
  DropboxProvider({
    required this.env,
    required super.helper,
    this.onAuthChanged,
  }) {
    _initDropboxComponents();
  }

  @NonNls
  @override
  final String id = 'DropboxProvider';

  final Env env;
  final VoidCallback? onAuthChanged;

  String? connectedAccountEmail;
  String? connectedDisplayName;

  late DropboxAuthService authService;
  late DropboxSyncStateStore stateStore;
  late DropboxClient dropboxClient;
  late DropboxSyncEngine syncEngine;

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

  void _initDropboxComponents() {
    authService = DropboxAuthService();
    stateStore = DropboxSyncStateStore(
      pathUtils: helper.pathUtil is PathUtils
          ? helper.pathUtil as PathUtils
          : PathUtils(),
    );
    dropboxClient = DropboxClient(
      appKey: configuredAppKey,
      authService: authService,
      getRefreshToken: () async {
        final stored = await loadCredentials();
        if (stored == null || stored.trim().isEmpty) {
          return null;
        }
        try {
          final decoded = json.decode(stored) as Map<String, dynamic>;
          return decoded['refresh_token'] as String? ??
              decoded['accessToken'] as String?;
        } catch (_) {
          return stored;
        }
      },
      saveRefreshToken: (newToken) async {
        await storeCredentials(json.encode({'refresh_token': newToken}));
      },
      clearCredentials: () async {
        await helper.saveCredentials(id, '');
      },
      onAuthenticationLost: () {
        client = null;
        onAuthChanged?.call();
      },
    );
    syncEngine = DropboxSyncEngine(
      client: dropboxClient,
      stateStore: stateStore,
    );
  }

  @override
  oauth2.Client clientWithStoredCredentials(String stored) {
    if (stored.trim().isEmpty) {
      throw ArgumentError('Stored Dropbox credentials cannot be empty.');
    }
    oauth2.Credentials credentials;
    try {
      final decoded = json.decode(stored) as Map<String, dynamic>;
      if (decoded.containsKey('refresh_token')) {
        final refreshToken = decoded['refresh_token'] as String?;
        credentials = oauth2.Credentials(
          decoded['access_token'] as String? ?? refreshToken ?? '',
          refreshToken: refreshToken,
          tokenEndpoint: Uri.parse('https://api.dropboxapi.com/oauth2/token'),
        );
      } else {
        credentials = oauth2.Credentials.fromJson(stored);
      }
    } catch (_) {
      credentials = oauth2.Credentials(stored);
    }

    return oauth2.Client(
      credentials,
      identifier: configuredAppKey,
      onCredentialsRefreshed: _onCredentialsRefreshed,
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

    if (tokens.refreshToken != null) {
      await storeCredentials(json.encode(tokens.toJson()));
    } else {
      await storeCredentials(tokens.accessToken);
    }

    client = oauth2.Client(
      oauth2.Credentials(
        tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiration: tokens.expiresAt,
        tokenEndpoint: Uri.parse('https://api.dropboxapi.com/oauth2/token'),
      ),
      identifier: session.appKey,
      onCredentialsRefreshed: _onCredentialsRefreshed,
    );

    try {
      final acct = await dropboxClient.getCurrentAccount();
      connectedAccountEmail = acct['email'];
      connectedDisplayName = acct['displayName'];
      final tokenJson = tokens.toJson();
      if (connectedAccountEmail != null) {
        tokenJson['email'] = connectedAccountEmail;
      }
      if (connectedDisplayName != null) {
        tokenJson['displayName'] = connectedDisplayName;
      }
      await storeCredentials(json.encode(tokenJson));
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
    await storeCredentials(token);
    client = oauth2.Client(oauth2.Credentials(token));
    onAuthChanged?.call();
  }

  @override
  Future<oauth2.Client?> clientFromAuthenticationFlow<
    TF extends UserAuthenticationPromptResult,
    UF extends UserAuthenticationPromptData<TF>
  >(prompt) async {
    final session = createPkceSession();
    _logger.info('Launching PKCE authorization URL: ${session.authorizeUrl}');

    final code = await oAuthTokenPrompt(
      prompt as PromptUserForCode,
      session.authorizeUrl.toString(),
    );

    if (code == null || code.trim().isEmpty) {
      _logger.warning('User cancelled authorization.');
      return null;
    }

    await completePkceAuth(session: session, code: code.trim());
    return client;
  }

  void _onCredentialsRefreshed(oauth2.Credentials credentials) {
    _logger.fine('Received refreshed credentials.');
    storeCredentials(credentials.toJson());
    if (credentials.accessToken.isNotEmpty) {
      dropboxClient.setInMemoryToken(
        DropboxTokenResponse(
          accessToken: credentials.accessToken,
          refreshToken: credentials.refreshToken,
          expiresAt:
              credentials.expiration ??
              DateTime.now().add(const Duration(hours: 4)),
        ),
      );
    }
    onAuthChanged?.call();
  }

  @override
  Future<bool> loadSavedAuth() async {
    final creds = await loadCredentials();
    if (creds == null || creds.trim().isEmpty) {
      client = null;
      return false;
    }

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
        }

        if (accessToken.isNotEmpty || refreshToken != null) {
          dropboxClient.setInMemoryToken(
            DropboxTokenResponse(
              accessToken: accessToken,
              refreshToken: refreshToken,
              expiresAt:
                  expiresAt ?? DateTime.now().add(const Duration(hours: 4)),
            ),
          );
        }
      }
    } catch (_) {}

    final ok = await super.loadSavedAuth();
    if (ok) {
      if (connectedAccountEmail == null || connectedAccountEmail!.isEmpty) {
        try {
          final acct = await dropboxClient.getCurrentAccount();
          connectedAccountEmail = acct['email'];
          connectedDisplayName = acct['displayName'];

          final stored = await loadCredentials();
          if (stored != null) {
            try {
              final map = json.decode(stored) as Map<String, dynamic>;
              map['email'] = connectedAccountEmail;
              map['displayName'] = connectedDisplayName;
              await storeCredentials(json.encode(map));
            } catch (_) {}
          }
        } catch (e) {
          _logger.fine('Could not fetch Dropbox account details: $e');
        }
      }
    }
    return ok;
  }

  @override
  Future<void> logout() async {
    _logger.info('Disconnecting from Dropbox...');
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

    await super.logout();
    onAuthChanged?.call();
    _logger.info('Successfully disconnected from Dropbox.');
  }

  @override
  bool get supportSearch => true;

  @override
  Future<SearchResponse> search({String name = Env.KeePassExtension}) async {
    final searchUri = Uri.parse('https://api.dropboxapi.com/2/files/search_v2');
    final c = await requireAuthenticatedClient();
    final response = await c.post(
      searchUri,
      headers: {'content-type': 'application/json'},
      body: json.encode(nonNls(<String, String>{'query': name})),
    );
    if (response.statusCode >= 300 || response.statusCode < 200) {
      throw Exception('Dropbox search failed: HTTP ${response.statusCode}');
    }
    final jsonData = json.decode(response.body) as Map<String, dynamic>;
    final jsonResponse = FileSearchResponse.fromJson(jsonData);
    return SearchResponse(
      (srb) => srb
        ..results.addAll(
          jsonResponse.matches!.map((responseEntity) {
            final metadata = responseEntity.metadata!.metadata!;
            return metadata.toCloudStorageEntity();
          }),
        )
        ..hasMore = jsonResponse.hasMore,
    );
  }

  @override
  Future<SearchResponse> list({CloudStorageEntity? parent}) async {
    final listUri = Uri.parse('https://api.dropboxapi.com/2/files/list_folder');
    final c = await requireAuthenticatedClient();
    final response = await c.post(
      listUri,
      headers: {'content-type': 'application/json'},
      body: json.encode(nonNls(<String, String>{'path': parent?.id ?? ''})),
    );
    if (response.statusCode >= 300 || response.statusCode < 200) {
      throw Exception('Dropbox list failed: HTTP ${response.statusCode}');
    }
    final jsonData = json.decode(response.body) as Map<String, dynamic>;
    final jsonResponse = FileListResponse.fromJson(jsonData);
    return SearchResponse(
      (srb) => srb
        ..results.addAll(
          jsonResponse.entries!.map((m) => m.toCloudStorageEntity()),
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
    final c = await requireAuthenticatedClient();
    final downloadUrl = Uri.parse(
      'https://content.dropboxapi.com/2/files/download',
    );
    final response = await c.post(
      downloadUrl,
      headers: nonNls({
        'Dropbox-API-Arg': json.encode({'path': file.id}),
      }),
    );
    if (response.statusCode ~/ 100 != 2) {
      throw LoadFileException(
        'Failed to download from Dropbox: HTTP ${response.statusCode}',
      );
    }
    final apiResultJson =
        response.headers[_HEADER_DOWNLOAD_METADATA.toLowerCase()];
    if (apiResultJson == null) {
      throw StateError(
        'Missing $_HEADER_DOWNLOAD_METADATA header from Dropbox.',
      );
    }
    final fileMetadataJson = json.decode(apiResultJson) as Map<String, dynamic>;
    return FileContent(response.bodyBytes, <String, dynamic>{
      _METADATA_KEY_DROPBOX_DATA: fileMetadataJson,
    });
  }

  @override
  Future<Map<String, dynamic>> saveEntity(
    CloudStorageEntity file,
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async {
    return await _upload(file.id, bytes, previousMetadata: previousMetadata);
  }

  Future<Map<String, dynamic>> _upload(
    String? filePath,
    Uint8List bytes, {
    Map<String, dynamic>? previousMetadata,
    bool update = true,
  }) async {
    dynamic mode;
    if (update) {
      mode = 'overwrite';
      if (previousMetadata != null &&
          previousMetadata[_METADATA_KEY_DROPBOX_DATA] != null) {
        final fileMetadata = FileMetadata.fromJson(
          previousMetadata[_METADATA_KEY_DROPBOX_DATA] as Map<String, dynamic>,
        );
        mode = nonNls(<String, dynamic>{
          '.tag': 'update',
          'update': fileMetadata.rev,
        });
      }
    } else {
      mode = 'add';
    }

    final uploadUrl = Uri.parse(
      'https://content.dropboxapi.com/2/files/upload',
    );
    final c = await requireAuthenticatedClient();
    final response = await c.post(
      uploadUrl,
      headers: nonNls({
        'content-type': 'application/octet-stream',
        'Dropbox-API-Arg': json.encode({
          'path': filePath,
          'mode': mode,
          'autorename': false,
        }),
      }),
      body: bytes,
    );

    if (response.statusCode ~/ 100 != 2) {
      if (response.statusCode == 409) {
        throw StorageException.conflict('Dropbox upload conflict.');
      }
      throw StorageException.unknown(
        'Dropbox upload failed: HTTP ${response.statusCode}',
      );
    }

    final metadataJson = json.decode(response.body) as Map<String, dynamic>;
    return <String, dynamic>{_METADATA_KEY_DROPBOX_DATA: metadataJson};
  }

  @override
  Future<FileSource> createEntity(
    CloudStorageSelectorSaveResult saveAs,
    Uint8List bytes,
  ) async {
    final parent = saveAs.parent;
    final filePath = parent == null
        ? [CharConstants.slash, saveAs.fileName].join()
        : path.join(parent.id, saveAs.fileName);
    final metadataJson = await _upload(filePath, bytes, update: false);
    final metadata = FileMetadata.fromJson(metadataJson);
    return toFileSource(
      metadata.toCloudStorageEntity(),
      uuid: AppDataBloc.createUuid(),
      initialCachedContent: FileContent(bytes, metadataJson),
    );
  }
}
