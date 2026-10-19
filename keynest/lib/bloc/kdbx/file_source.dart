import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/platform.dart';
import 'package:keynest/utils/storage_location_helper.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('file_source');

enum FileSourceIcon {
  hdd,
  externalLink,
  dropbox,
  googleDrive,
  webDav,
  oneDrive,
  keyNest,
}

abstract class FileSource {
  FileSource({
    required this.databaseName,
    required this.uuid,
    FileContent? initialCachedContent,
  }) : _cached = initialCachedContent;

  FileContent? _cached;

  @protected
  @visibleForTesting
  FileContent? get cached => _cached;

  /// the last read or written content.
  FileContent? get lastContent => cached;

  final String uuid;

  /// If known should return the name of the database, null otherwise.
  final String? databaseName;

  /// Cleans a filename or path to serve as the single source of truth for the vault's display name.
  /// Strips directories, URI components, and the `.kdbx` extension case-insensitively.
  static String cleanDisplayName(String rawName) {
    var clean = rawName.trim();
    if (clean.isEmpty) {
      return 'Vault';
    }

    // Strip query parameters if present (e.g., from web or file URIs)
    final questionMark = clean.indexOf('?');
    if (questionMark > 0) {
      clean = clean.substring(0, questionMark);
    }

    // URL decode if percent-encoded before splitting slashes (e.g. primary%3Atest%2FVault3.kdbx)
    try {
      clean = Uri.decodeComponent(clean);
    } catch (_) {}

    // If it's a file path, URL path, or SAF document URI, extract the basename
    if (clean.contains('/') || clean.contains(r'\')) {
      final lastSlash = clean.lastIndexOf(RegExp(r'[/\\]'));
      if (lastSlash >= 0 && lastSlash < clean.length - 1) {
        clean = clean.substring(lastSlash + 1);
      }
    }

    // If it contains a SAF colon prefix (e.g. primary:Vault3.kdbx or 1234-5678:vault.kdbx)
    if (clean.contains(':')) {
      final lastColon = clean.lastIndexOf(':');
      if (lastColon >= 0 && lastColon < clean.length - 1) {
        clean = clean.substring(lastColon + 1);
      }
    }

    // Additional URL decode in case inner segment was also encoded
    try {
      clean = Uri.decodeComponent(clean);
    } catch (_) {}

    // Case-insensitively strip .kdbx extension
    if (clean.toLowerCase().endsWith(AppConstants.kdbxExtension)) {
      clean = clean
          .substring(0, clean.length - AppConstants.kdbxExtension.length)
          .trim();
    }

    return clean.isEmpty ? 'Vault' : clean;
  }

  /// Returns the clean file name without extension as the single source of truth for the vault display name.
  String get displayName {
    final fromPath = cleanDisplayName(displayNameFromPath);
    if (fromPath.isNotEmpty &&
        fromPath != 'Vault' &&
        fromPath.toLowerCase() != 'vault') {
      return fromPath;
    }
    if (databaseName != null && databaseName!.trim().isNotEmpty) {
      final fromDb = cleanDisplayName(databaseName!);
      if (fromDb.isNotEmpty &&
          fromDb != 'Vault' &&
          fromDb.toLowerCase() != 'vault') {
        return fromDb;
      }
    }
    if (fromPath.isNotEmpty) {
      return fromPath;
    }
    if (databaseName != null && databaseName!.trim().isNotEmpty) {
      return cleanDisplayName(databaseName!);
    }
    return 'Vault';
  }

  FileSourceIcon get displayIcon;

  /// The database name to display if [databaseName] is unknown.
  @protected
  String get displayNameFromPath;

  /// Exact path to the file source.
  String get displayPath;

  /// User-friendly storage location (e.g. Download/Secret, Documents/KeyNest).
  String get friendlyLocation =>
      KeyNestStorageLocationHelper.getFriendlyLocation(this);

  /// whether this file source supports saving of changes.
  bool get supportsWrite;

  /// The metadata which was fetched on the last call to [content].
  @protected
  Map<String, dynamic>? get previousMetadata => _cached!.metadata;

  String get typeDebug => runtimeType.toString();

  /// Checks if the underlying file or storage resource actually exists.
  Future<bool> checkExists() async => true;

  FileSource copyWithDatabaseName(String databaseName);

  @protected
  Stream<FileContent> load();

  /// Should write the given contents to the file. when there was a previous
  /// call to [load] which returned [FileContent.metadata], this will be passe
  /// into [previousMetadata]
  @protected
  Future<Map<String, dynamic>?> write(
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  );

  Future<void> contentPreCache() async {
    if (_cached != null) {
      return;
    }
    await content().last;
  }

  Stream<FileContent> content({bool updateCache = true}) async* {
    if (_cached != null) {
      //  memory cache is perfectly fine.
      yield _cached!;
    }
    await for (final content in load()) {
      yield content;
      if (updateCache) {
        _cached = FileContent(
          content.content,
          content.metadata,
          FileContentSource.memoryCache,
        );
      }
    }
  }

  Future<FileContent> contentWrite(
    Uint8List bytes, {
    required Map<String, dynamic>? metadata,
  }) async {
    _logger.finer('Writing content to $typeDebug ($runtimeType) $this');
    try {
      final newMetadata = await write(bytes, metadata ?? _cached?.metadata);
      return _cached = FileContent(
        bytes,
        newMetadata,
        FileContentSource.memoryCache,
      );
    } catch (e, stackTrace) {
      _logger.severe(
        'Error while writing into $typeDebug ($runtimeType) $this',
        e,
        stackTrace,
      );
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is FileSource) {
      return other.uuid == uuid;
    }
    return super == other;
  }

  @override
  int get hashCode => uuid.hashCode;

  @NonNls
  @protected
  Map<String, String?> toDebugMap() => {
    'type': runtimeType.toString(),
    'uuid': uuid,
    'databaseName': databaseName,
    'displayPath': displayPath,
  };

  @NonNls
  String toStringDisplay() => '[$displayName]($displayPath)';
}

class FileSourceUrl extends FileSource {
  FileSourceUrl(this.url, {super.databaseName, required super.uuid});

  @NonNls
  static const _webCorsProxy = 'https://cors-anywhere.herokuapp.com/';

  final Uri? url;

  Uri? get _url =>
      KeyNestPlatform.isWeb && !url.toString().contains(_webCorsProxy)
      ? Uri.parse([_webCorsProxy, url].join())
      : url;

  @override
  Stream<FileContent> load() async* {
    final response = await http.readBytes(_url!);
    yield FileContent(response);
  }

  @override
  String get displayPath => Uri(
    scheme: url!.scheme,
    host: url!.host,
    path: url!.path,
  ).toString(); //url.replace(queryParameters: <String, dynamic>{}, fragment: '').toString();

  @override
  String get displayNameFromPath =>
      FileSource.cleanDisplayName(url?.path ?? '');

  @override
  Future<Map<String, dynamic>> write(
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async {
    throw UnsupportedError('Cannot write to urls.');
  }

  @override
  bool get supportsWrite => false;

  @override
  FileSourceIcon get displayIcon => FileSourceIcon.externalLink;

  @override
  FileSource copyWithDatabaseName(String databaseName) => FileSourceUrl(
    url,
    uuid: uuid,
    databaseName: databaseName,
  );
}
