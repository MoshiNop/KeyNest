import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:file/file.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('file_source_cloud_storage');

@NonNls
const _jsonMetadata = 'metadata';
@NonNls
const _jsonCacheDate = 'cacheDate';
@NonNls
const _jsonCacheSize = 'cacheSize';

class FileContentCached {
  FileContentCached({
    required this.metadata,
    required this.cacheDate,
    required this.cacheSize,
  }) : assert(cacheDate.isUtc);
  factory FileContentCached.fromJson(Map<String, dynamic> json) =>
      FileContentCached(
        metadata: json[_jsonMetadata] as Map<String, dynamic>?,
        cacheDate: DateTime.fromMillisecondsSinceEpoch(
          json[_jsonCacheDate] as int,
          isUtc: true,
        ),
        cacheSize: json[_jsonCacheSize] as int?,
      );

  final Map<String, dynamic>? metadata;
  final DateTime cacheDate;
  final int? cacheSize;

  Map<String, Object?> toJson() => {
    _jsonMetadata: metadata,
    _jsonCacheDate: cacheDate.millisecond,
    _jsonCacheSize: cacheSize,
  };

  @override
  String toString() => toJson().toString();
}

class FileSourceCloudStorage extends FileSource {
  FileSourceCloudStorage({
    required this.provider,
    required this.fileInfo,
    super.databaseName,
    required super.uuid,
    super.initialCachedContent,
  });

  static Directory? _cacheDir;

  Future<Directory> _getCacheDir() => provider.pathUtil.getTemporaryDirectory(
    subNamespace: 'cloud_storage_cache',
  );

  final CloudStorageProvider provider;

  final Map<String, String?> fileInfo;

  @NonNls
  @override
  String get typeDebug => '$runtimeType:${provider.id}';

  @override
  String get displayNameFromPath => provider.displayNameFromPath(fileInfo);

  @override
  String get displayPath => provider.displayPath(fileInfo);

  @NonNls
  File _cacheMetadataFile(Directory cacheDir) =>
      cacheDir.childFile('$uuid.kdbx.json');
  @NonNls
  File _cacheKdbxFile(Directory cacheDir) => cacheDir.childFile('$uuid.kdbx');

  bool _isWorkingCopyDirty = false;
  bool get isWorkingCopyDirty => _isWorkingCopyDirty;

  @override
  Stream<FileContent> load() async* {
    // 1. First load from local working copy cache if present
    final cacheDir = _cacheDir ??= await _getCacheDir();
    final metadataFile = _cacheMetadataFile(cacheDir);
    final kdbxFile = _cacheKdbxFile(cacheDir);
    bool yieldedCachedVersion = false;
    try {
      if (metadataFile.existsSync()) {
        final cacheInfo = FileContentCached.fromJson(
          json.decode(await metadataFile.readAsString())
              as Map<String, dynamic>,
        );
        final content = await kdbxFile.readAsBytes();
        if (content.length != cacheInfo.cacheSize) {
          throw StateError(
            'Cached size does not match size in '
            'cache file. ${content.length} vs $cacheInfo',
          );
        }
        yield FileContent(content, cacheInfo.metadata, FileContentSource.cache);
        yieldedCachedVersion = true;
      }
    } catch (e, stackTrace) {
      _logger.severe('Error while loading cached kdbx file', e, stackTrace);
    }

    // 2. If working copy has unsaved local modifications, do not overwrite with remote version!
    if (_isWorkingCopyDirty && yieldedCachedVersion) {
      _logger.fine('Local working copy has pending unsynced edits. Preserving local copy.');
      return;
    }

    // 3. Download fresh content from provider if no valid cache exists or to check remote updates
    _logger.finer('loading ${toString()}');
    try {
      final freshContent = await provider.loadFile(fileInfo);
      yield freshContent;
      unawaited(_writeCache(freshContent));
    } on LoadFileException catch (e, stackTrace) {
      _logger.severe(
        'Error while loading file from provider ${toString()}',
        e,
        stackTrace,
      );
      if (!yieldedCachedVersion) {
        throw LoadFileException(
          'Error while loading from cloud storage. ${toStringDisplay()}',
        ).causedBy(e, stackTrace);
      }
      _logger.info('Using local working copy after remote load error: $e');
    } catch (e, stackTrace) {
      _logger.severe(
        'Error while loading file from provider ${toString()}',
        e,
        stackTrace,
      );
      if (!yieldedCachedVersion) {
        rethrow;
      }
    }
  }

  Future<void> _writeCache(FileContent freshContent) async {
    try {
      final cacheDir = _cacheDir ??= await _getCacheDir();
      final metadataFile = _cacheMetadataFile(cacheDir);
      final kdbxFile = _cacheKdbxFile(cacheDir);
      final cacheInfo = FileContentCached(
        metadata: freshContent.metadata,
        cacheDate: clock.now().toUtc(),
        cacheSize: freshContent.content.length,
      );
      _logger.finer('Writing cache ${metadataFile.path}');
      await metadataFile.writeAsString(
        json.encode(cacheInfo.toJson()),
        flush: true,
      );
      await kdbxFile.writeAsBytes(freshContent.content, flush: true);
      _logger.finer('Done: Written cache ${metadataFile.path}');
    } catch (e, stackTrace) {
      _logger.severe('Error while writing cache for $uuid', e, stackTrace);
    }
  }

  @override
  bool get supportsWrite => true;

  @override
  Future<Map<String, dynamic>?> write(
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async {
    _isWorkingCopyDirty = true;
    final cacheDir = _cacheDir ??= await _getCacheDir();
    final metadataFile = _cacheMetadataFile(cacheDir);
    final kdbxFile = _cacheKdbxFile(cacheDir);
    final cacheInfo = FileContentCached(
      metadata: previousMetadata,
      cacheDate: clock.now().toUtc(),
      cacheSize: bytes.length,
    );
    await metadataFile.writeAsString(
      json.encode(cacheInfo.toJson()),
      flush: true,
    );
    await kdbxFile.writeAsBytes(bytes, flush: true);
    return previousMetadata;
  }

  /// Asynchronously uploads the current local working copy to the remote cloud provider.
  Future<Map<String, dynamic>?> uploadWorkingCopy() async {
    final cacheDir = _cacheDir ??= await _getCacheDir();
    final kdbxFile = _cacheKdbxFile(cacheDir);
    if (!kdbxFile.existsSync()) {
      return null;
    }
    final bytes = await kdbxFile.readAsBytes();
    final metadataFile = _cacheMetadataFile(cacheDir);
    Map<String, dynamic>? prevMeta;
    if (metadataFile.existsSync()) {
      try {
        final cacheInfo = FileContentCached.fromJson(
          json.decode(await metadataFile.readAsString())
              as Map<String, dynamic>,
        );
        prevMeta = cacheInfo.metadata;
      } catch (_) {}
    }
    final newMetadata = await provider.saveFile(fileInfo, bytes, prevMeta);
    await _writeCache(FileContent(bytes, newMetadata));
    _isWorkingCopyDirty = false;
    return newMetadata;
  }

  @override
  FileSourceIcon get displayIcon => provider.displayIcon;

  @override
  FileSource copyWithDatabaseName(String databaseName) =>
      FileSourceCloudStorage(
        provider: provider,
        fileInfo: fileInfo,
        uuid: uuid,
        databaseName: databaseName,
        initialCachedContent: cached,
      );
}
