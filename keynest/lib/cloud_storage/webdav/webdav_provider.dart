import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:http_auth/http_auth.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/storage_exception.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/webdav/webdav_models.dart';
import 'package:keynest/utils/format_utils.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';
import 'package:xml/xml.dart' as xml;

final _logger = Logger('keynest.webdav_provider');

abstract class HttpHeaders {
  static const ifNoneMatchHeader = 'if-none-match';
  static const etagHeader = 'etag';
  static const ifMatchHeader = 'if-match';
  static const contentTypeHeader = 'content-type';
}

abstract class HttpStatus {
  static const notFound = 404;
  static const preconditionFailed = 412;
}

class WebDavClient extends NegotiateAuthClient {
  WebDavClient(this.credentials)
    : super(credentials.username ?? '', credentials.password ?? '');

  UserNamePasswordCredentials credentials;
}

class WebDavProvider extends CloudStorageProviderClientBase<WebDavClient> {
  WebDavProvider({required super.helper});

  @NonNls
  @override
  final String id = 'WebDavProvider';

  static const METHOD_HEAD = 'HEAD'; // NON-NLS
  static const METHOD_PUT = 'PUT'; // NON-NLS
  static const METHOD_PROPFIND = 'PROPFIND'; // NON-NLS

  /// Enforces HTTPS for remote WebDAV servers so Basic/Digest credentials and
  /// vault payloads are never transmitted in cleartext over untrusted networks.
  /// Loopback addresses (`localhost`, `127.0.0.1`, `::1`) are permitted over
  /// `http://` for local self-hosted development/testing bridges.
  static void validateSecureWebDavUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError('Invalid WebDAV URL: $rawUrl');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'https') {
      return;
    }
    if (scheme == 'http') {
      final host = uri.host.toLowerCase();
      if (host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '::1' ||
          host == '[::1]') {
        return;
      }
      throw ArgumentError(
        'Insecure WebDAV URL rejected: remote WebDAV servers must use https://.',
      );
    }
    throw ArgumentError(
      'Unsupported WebDAV URL scheme "${uri.scheme}". Expected https://.',
    );
  }

  xml.XmlNode _propfindRequest() {
    return nonNls(() {
      final builder = xml.XmlBuilder();
      builder.processing('xml', 'version="1.0"');
      builder.element(
        'd:propfind',
        namespaces: {'DAV:': 'd'},
        nest: () {
          builder.element(
            'd:prop',
            nest: () {
              builder.element('d:getlastmodified');
              builder.element('d:getetag');
              builder.element('d:getcontenttype');
              builder.element('d:resourcetype');
            },
          );
        },
      );
      return builder.buildDocument();
    })();
  }

  @override
  Future<WebDavClient?> clientFromAuthenticationFlow<
    TF extends UserAuthenticationPromptResult,
    UF extends UserAuthenticationPromptData<TF>
  >(prompt) async {
    assert(
      prompt
          is PromptUserForCode<
            UrlUsernamePasswordResult,
            UrlUsernamePasswordPromptData
          >,
    );
    final urlPrompt =
        prompt
            as PromptUserForCode<
              UrlUsernamePasswordResult,
              UrlUsernamePasswordPromptData
            >;
    final result =
        await promptUser<
          UrlUsernamePasswordResult,
          UrlUsernamePasswordPromptData
        >(urlPrompt, UrlUsernamePasswordPromptData());
    if (result == null) {
      _logger.finer('prompt was canceled by user.');
      return null;
    }
    validateSecureWebDavUrl(result.url);
    final credentials = UserNamePasswordCredentials(
      baseUrl: result.url.trim(),
      username: result.username,
      password: result.password,
    );
    final client = WebDavClient(credentials);

    // fetch root, to validate credentials.
    await propFind(client, null);

    await storeCredentials(json.encode(credentials));
    return client;
  }

  /// Directly tests and connects with WebDAV credentials (URL, username, password).
  Future<void> connectWithCredentials({
    required String url,
    required String username,
    required String password,
  }) async {
    validateSecureWebDavUrl(url);
    final credentials = UserNamePasswordCredentials(
      baseUrl: url.trim(),
      username: username,
      password: password,
    );
    final webDavClient = WebDavClient(credentials);
    await propFind(webDavClient, null);
    await storeCredentials(json.encode(credentials));
    client = webDavClient;
  }

  @override
  WebDavClient clientWithStoredCredentials(String stored) {
    if (stored.trim().isEmpty) {
      throw ArgumentError('Stored WebDAV credentials cannot be empty.');
    }
    final credentials = UserNamePasswordCredentials.fromJson(
      json.decode(stored) as Map<String, dynamic>,
    );
    validateSecureWebDavUrl(credentials.baseUrl);
    return WebDavClient(credentials);
  }

  @override
  Future<FileSource> createEntity(
    CloudStorageSelectorSaveResult saveAs,
    Uint8List bytes,
  ) async {
    final client = await requireAuthenticatedClient();
    final uri = _uriForEntity(client, saveAs.parent).resolve(saveAs.fileName);
    _logger.finer('Saving to $uri');
    final request = Request(METHOD_PUT, uri);
    request.headers[HttpHeaders.ifNoneMatchHeader] = Nls.STAR;
    request.bodyBytes = bytes;
    final response = await client.send(request);
    await _expectSuccessResponse(response);
    final etag =
        response.headers[HttpHeaders.etagHeader] ??
        await _refetchEtagFromHead(uri);
    final newMetadata = WebDavFileMetadata(etag: etag);
    _logger.finer(
      'Successfully created entity. '
      'new metadata: ${newMetadata.toJson()} - '
      'http headers: ${response.headers}',
    );
    return toFileSource(
      _toCloudStorageEntity(
        client,
        uri.path,
        CloudStorageEntityType.file,
      ),
      uuid: AppDataBloc.createUuid(),
      initialCachedContent: FileContent(bytes, newMetadata.toJson()),
    );
  }

  Future<String?> _refetchEtagFromHead(Uri uri) async {
    final client = await requireAuthenticatedClient();
    _logger.info('No etag on PUT, fetch HEAD.');
    final headResponse = await client.send(Request(METHOD_HEAD, uri));
    await _expectSuccessResponse(headResponse);
    final etag = headResponse.headers[HttpHeaders.etagHeader];
    if (etag == null) {
      _logger.warning('No etag in HEAD response.');
    }
    return etag;
  }

  @override
  FileSourceIcon get displayIcon => FileSourceIcon.webDav;

  @override
  String get displayName => 'WebDAV'; // NON-NLS

  Uri _uriForEntity(WebDavClient client, CloudStorageEntity? entity) {
    final uri = Uri.parse(client.credentials.baseUrl);
    if (entity != null) {
      if (entity.type == CloudStorageEntityType.directory) {
        return uri.resolve(entity.id + Nls.SLASH);
      }
      return uri.resolve(entity.id);
    }
    return uri;
  }

  Future<SearchResponse> propFind(
    WebDavClient client,
    CloudStorageEntity? parent,
  ) async {
    final parentUri = _uriForEntity(client, parent);
    final request = Request(METHOD_PROPFIND, parentUri);
    request.headers['Depth'] = '1'; // NON-NLS
    final body = _propfindRequest();
    request.body = body.toXmlString();
    final response = await client.send(request);

    await _expectSuccessResponse(response);

    final bytes = await response.stream.toBytes();
    final doc = xml.XmlDocument.parse(utf8.decode(bytes));
    @NonNls
    final entities = doc.findAllElements(
      'response',
      namespace: 'DAV:',
    );
    _logger.finer('entities: ${entities.length}');
    final cloudStorageEntities = nonNls(
      entities
          .map((entity) {
            final hrefEls = entity.findAllElements('href', namespace: 'DAV:');
            final href = hrefEls.isEmpty ? null : hrefEls.first.innerText;
            final rtEls = entity.findAllElements(
              'resourcetype',
              namespace: 'DAV:',
            );
            if (href == null || rtEls.isEmpty) {
              return null;
            }
            final resourcetype = rtEls.first;
            final isFolder = resourcetype
                .findElements('collection', namespace: 'DAV:')
                .isNotEmpty;
            final isFile = resourcetype.children.isEmpty;
            final type = isFolder
                ? CloudStorageEntityType.directory
                : isFile
                ? CloudStorageEntityType.file
                : null;
            if (type == null) {
              return null;
            }

            final cse = _toCloudStorageEntity(client, href, type);
            final uri = _uriForEntity(client, cse);
            if (uri == parentUri) {
              return null;
            }
            return cse;
          })
          .where((el) => el != null)
          .toList(),
    );

    return SearchResponse(
      (b) => b
        ..results.addAll(cloudStorageEntities)
        ..hasMore = false,
    );
  }

  static final _removeTrailingSlash = RegExp(r'/+$');

  CloudStorageEntity _toCloudStorageEntity(
    WebDavClient client,
    String href,
    CloudStorageEntityType type,
  ) {
    href = href.replaceFirst(_removeTrailingSlash, Nls.BLANK);
    final hrefUri = Uri.parse(href);
    _logger.fine(
      'Cloud entity to href: $href (pathSegments: ${hrefUri.pathSegments})',
    );
    final baseSegments = Uri.parse(
      client.credentials.baseUrl,
    ).pathSegments.where((s) => s.isNotEmpty).toList();
    final hrefSegments = hrefUri.pathSegments
        .where((val) => val.isNotEmpty)
        .toList();
    final basePath = baseSegments.isEmpty ? '.' : path.url.joinAll(baseSegments);
    final hrefPath = hrefSegments.isEmpty ? '.' : path.url.joinAll(hrefSegments);
    final relPath = path.url.relative(hrefPath, from: basePath);
    return CloudStorageEntity(
      (b) => b
        ..id = href
        ..type = type
        ..path = Nls.SLASH + (relPath == '.' ? '' : relPath)
        ..name = hrefSegments.isEmpty ? Nls.SLASH : hrefSegments.last,
    );
  }

  @override
  Future<SearchResponse> list({CloudStorageEntity? parent}) async {
    final client = await requireAuthenticatedClient();
    return propFind(client, parent);
  }

  @override
  Future<FileContent> loadEntity(CloudStorageEntity file) async {
    final client = await requireAuthenticatedClient();
    final uri = _uriForEntity(client, file);
    final response = await client.get(uri);
    if (response.statusCode == HttpStatus.notFound) {
      throw LoadFileNotFoundException(
        'File was not found on webdav server. $uri',
      );
    }
    if (response.statusCode ~/ 100 != 2) {
      throw LoadFileException(
        'Error while loading file from webdav server. '
        'Unexpected error code ${response.statusCode}',
      );
    }
    final metadata = WebDavFileMetadata(
      etag: response.headers[HttpHeaders.etagHeader],
    );
    _logger.finer(
      'Successfully loaded entity with metadata: ${metadata.toJson()}',
    );
    return FileContent(response.bodyBytes, metadata.toJson());
  }

  @override
  Future<Map<String, dynamic>> saveEntity(
    CloudStorageEntity file,
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async {
    final client = await requireAuthenticatedClient();
    final uri = _uriForEntity(client, file);
    final request = Request(METHOD_PUT, uri);
    if (previousMetadata == null) {
      _logger.severe(
        'There was no previous metadata set?! Overwriting blindly.',
      );
    } else {
      final metadata = WebDavFileMetadata.fromJson(previousMetadata);
      if (metadata.etag != null) {
        // remove weak (W/) prefix from etag
        request.headers[HttpHeaders.ifMatchHeader] = metadata.etag!
            .replaceFirst('W/', ''); // NON-NLS
      } else {
        _logger.severe('No etag set for content. Overwriting blindly!');
      }
    }
    request.bodyBytes = bytes;
    final response = await client.send(request);
    await _expectSuccessResponse(response);
    final etag =
        response.headers[HttpHeaders.etagHeader] ??
        await _refetchEtagFromHead(uri);
    _logger.finest(
      'successfully written file.',
    );
    final newMetadata = WebDavFileMetadata(etag: etag);
    _logger.finer(
      'Successfully saved entity. new metadata: ${newMetadata.toJson()}',
    );
    return newMetadata.toJson();
  }

  Future<void> _expectSuccessResponse(StreamedResponse response) async {
    if (response.statusCode == 401) {
      _logger.severe(
        'Authentication error: HTTP ${response.statusCode}',
      );
      throw AuthenticationException(
        'Provided credentials were invalid. (Server Response ${response.statusCode}',
      );
    } else if (response.statusCode >= 300 || response.statusCode < 200) {
      if (response.statusCode == HttpStatus.preconditionFailed) {
        throw StorageException.conflict('Precondition failed.');
      }
      final body = utf8.decode(await response.stream.toBytes());
      _logger.severe(
        'Error during call to webdav endpoint: HTTP ${response.statusCode} ${response.reasonPhrase}',
      );
      throw StorageException.unknown(
        'Error during request. (${response.statusCode} ${response.reasonPhrase})',
        errorBody: [response.headers.toString(), body].join('\n'),
      );
    }
  }
}
