import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:file/file.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';
import 'package:synchronized/synchronized.dart';

final _logger = Logger('file_source_cloud_storage');

@NonNls
const _jsonMetadata = 'metadata';
@NonNls
const _jsonCacheDate = 'cacheDate';
@NonNls
const _jsonCacheSize = 'cacheSize';
@NonNls
const _jsonIsDirty = 'isDirty';

class FileContentCached {
  FileContentCached({
    required this.metadata,
    required this.cacheDate,
    required this.cacheSize,
    this.isDirty = false,
  }) : assert(cacheDate.isUtc);
  factory FileContentCached.fromJson(Map<String, dynamic> json) =>
      FileContentCached(
        metadata: json[_jsonMetadata] as Map<String, dynamic>?,
        cacheDate: DateTime.fromMillisecondsSinceEpoch(
          (json[_jsonCacheDate] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
        cacheSize: json[_jsonCacheSize] as int?,
        isDirty: (json[_jsonIsDirty] as bool?) ?? false,
      );

  final Map<String, dynamic>? metadata;
  final DateTime cacheDate;
  final int? cacheSize;
  final bool isDirty;

  Map<String, Object?> toJson() => {
    _jsonMetadata: metadata,
    _jsonCacheDate: cacheDate.millisecondsSinceEpoch,
    _jsonCacheSize: cacheSize,
    _jsonIsDirty: isDirty,
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

  static final Map<String, Lock> _cacheLocks = <String, Lock>{};
  Lock get _cacheLock => _cacheLocks.putIfAbsent(uuid, Lock.new);

  Directory? _resolvedCacheDir;

  Future<Directory> _getCacheDir() async {
    if (_resolvedCacheDir != null) {
      return _resolvedCacheDir!;
    }

    Directory persistentDir;
    if (provider.pathUtil is PathUtils) {
      final appDir = await (provider.pathUtil as PathUtils).getAppDataDirectory();
      persistentDir = appDir.childDirectory('cloud_storage_cache')
        ..createSync(recursive: true);
    } else {
      persistentDir = await provider.pathUtil.getCacheDirectory(
        subNamespace: 'cloud_storage_cache',
      );
    }

    // One-time migration from legacy OS-evictable temporary directory if present
    final targetKdbx = _cacheKdbxFile(persistentDir);
    if (!targetKdbx.existsSync()) {
      try {
        final legacyTempDir = await provider.pathUtil.getTemporaryDirectory(
          subNamespace: 'cloud_storage_cache',
        );
        if (legacyTempDir.path != persistentDir.path) {
          final legacyKdbx = _cacheKdbxFile(legacyTempDir);
          final legacyMeta = _cacheMetadataFile(legacyTempDir);
          if (legacyKdbx.existsSync()) {
            await targetKdbx.writeAsBytes(
              await legacyKdbx.readAsBytes(),
              flush: true,
            );
            if (legacyMeta.existsSync()) {
              await _cacheMetadataFile(persistentDir).writeAsString(
                await legacyMeta.readAsString(),
                flush: true,
              );
              await legacyMeta.delete();
            }
            await legacyKdbx.delete();
          }
        }
      } catch (e) {
        _logger.fine('Legacy cloud storage temp cache check skipped: $e');
      }
    }

    return _resolvedCacheDir = persistentDir;
  }

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
  Stream<FileContent> content({
    bool updateCache = true,
    bool forceReload = false,
  }) async* {
    if (!forceReload) {
      yield* super.content(updateCache: updateCache, forceReload: false);
      return;
    }

    // Explicit forceReload: fetch directly from remote provider.
    final freshContent = await provider.loadFile(fileInfo);
    yield freshContent;
    if (updateCache && !_isWorkingCopyDirty) {
      await _writeCache(freshContent, isDirty: false);
      setCachedContent(
        FileContent(
          freshContent.content,
          freshContent.metadata,
          FileContentSource.memoryCache,
        ),
      );
    }
  }

  @override
  Stream<FileContent> load() async* {
    // 1. First load from local working copy cache if present
    final cacheDir = await _getCacheDir();
    final metadataFile = _cacheMetadataFile(cacheDir);
    final kdbxFile = _cacheKdbxFile(cacheDir);
    bool yieldedCachedVersion = false;
    try {
      if (metadataFile.existsSync() && kdbxFile.existsSync()) {
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
        _isWorkingCopyDirty = _isWorkingCopyDirty || cacheInfo.isDirty;
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
      if (!_isWorkingCopyDirty) {
        await _writeCache(freshContent, isDirty: false);
      }
      yield freshContent;
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

  Future<void> _writeCache(
    FileContent freshContent, {
    required bool isDirty,
  }) async {
    try {
      await _cacheLock.synchronized(() async {
        if (!isDirty && _isWorkingCopyDirty) {
          return;
        }
        final cacheDir = await _getCacheDir();
        await _writeAtomicBytesAndMetadata(
          cacheDir: cacheDir,
          bytes: freshContent.content,
          metadata: freshContent.metadata,
          isDirty: isDirty,
        );
      });
    } catch (e, stackTrace) {
      _logger.severe('Error while writing cache for $uuid', e, stackTrace);
    }
  }

  Future<void> _writeAtomicBytesAndMetadata({
    required Directory cacheDir,
    required Uint8List bytes,
    required Map<String, dynamic>? metadata,
    required bool isDirty,
  }) async {
    final kdbxFile = _cacheKdbxFile(cacheDir);
    final metadataFile = _cacheMetadataFile(cacheDir);
    final tmpKdbx = cacheDir.childFile('$uuid.kdbx.tmp');
    final tmpMeta = cacheDir.childFile('$uuid.kdbx.json.tmp');

    final cacheInfo = FileContentCached(
      metadata: metadata,
      cacheDate: clock.now().toUtc(),
      cacheSize: bytes.length,
      isDirty: isDirty,
    );

    await tmpKdbx.writeAsBytes(bytes, flush: true);
    await tmpKdbx.rename(kdbxFile.path);
    await tmpMeta.writeAsString(json.encode(cacheInfo.toJson()), flush: true);
    await tmpMeta.rename(metadataFile.path);
  }

  @override
  bool get supportsWrite => true;

  @override
  Future<Map<String, dynamic>?> write(
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async {
    _isWorkingCopyDirty = true;
    await _cacheLock.synchronized(() async {
      final cacheDir = await _getCacheDir();
      await _writeAtomicBytesAndMetadata(
        cacheDir: cacheDir,
        bytes: bytes,
        metadata: previousMetadata,
        isDirty: true,
      );
    });
    return previousMetadata;
  }

  /// Updates the local persistent working copy cache after an authoritative
  /// 3-way cloud sync completes and clears the dirty flag.
  bool get hasUnsavedChanges => _isWorkingCopyDirty;

  Future<FileContent> markWorkingCopySynced(
    Uint8List bytes, [
    Map<String, dynamic>? metadata,
  ]) async {
    final effectiveMeta = metadata ?? cached?.metadata;
    await _cacheLock.synchronized(() async {
      final cacheDir = await _getCacheDir();
      await _writeAtomicBytesAndMetadata(
        cacheDir: cacheDir,
        bytes: bytes,
        metadata: effectiveMeta,
        isDirty: false,
      );
      _isWorkingCopyDirty = false;
    });
    final syncedContent = FileContent(
      bytes,
      effectiveMeta,
      FileContentSource.memoryCache,
    );
    setCachedContent(syncedContent);
    return syncedContent;
  }

  /// Reads the current working copy bytes from the persistent cache, falling
  /// back to in-memory cached content if needed.
  Future<Uint8List?> readWorkingCopyBytes() async {
    final cacheDir = await _getCacheDir();
    final kdbxFile = _cacheKdbxFile(cacheDir);
    if (kdbxFile.existsSync()) {
      return await kdbxFile.readAsBytes();
    }
    return cached?.content;
  }

  /// Asynchronously uploads the current local working copy to the remote cloud provider.
  Future<Map<String, dynamic>?> uploadWorkingCopy() async {
    final cacheDir = await _getCacheDir();
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
    await markWorkingCopySynced(bytes, newMetadata);
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
