import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:keynest/utils/uuid_util.dart';
import 'package:logging/logging.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('file_source_local');

const fileSystem = LocalFileSystem();

class FileSourceLocal extends FileSource {
  FileSourceLocal(
    this.file, {
    super.databaseName,
    required super.uuid,
    this.macOsSecureBookmark,
    this.filePickerIdentifier,
    super.initialCachedContent,
  });

  static File localFile(String path) => (const LocalFileSystem()).file(path);

  final File file;

  /// on macos a secure bookmark is required, if we are in a sandbox.
  final String? macOsSecureBookmark;

  /// stores the complete json [FileInfo] from [FilePickerWritable]
  /// for backward compatibility might also only contains [FileInfo.identifier]
  final String? filePickerIdentifier;

  FileInfo? _filePickerInfo;

  FileInfo? get filePickerInfo {
    if (_filePickerInfo != null) {
      return _filePickerInfo;
    }
    if (filePickerIdentifier != null &&
        filePickerIdentifier!.startsWith(CharConstants.curlyOpen)) {
      try {
        return _filePickerInfo = FileInfo.fromJson(
          json.decode(filePickerIdentifier!) as Map<String, dynamic>,
        );
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @NonNls
  @override
  String get typeDebug => '$runtimeType:$typeDebugFilePicker';

  @NonNls
  String get typeDebugFilePicker {
    final uri = filePickerInfo?.uri;
    if (uri == null) {
      return macOsSecureBookmark != null ? 'macos' : 'internal';
    }
    if (KeyNestPlatform.isIOS && uri.contains('CloudDocs')) {
      return 'icloud';
    }
    final parsed = Uri.parse(uri);
    return '${parsed.scheme}:${parsed.host}';
  }

  @override
  Stream<FileContent> content({bool updateCache = true}) async* {
    if (cached != null) {
      yield cached!;
      return;
    }
    await for (final c in super.content(updateCache: updateCache)) {
      yield c;
    }
  }

  @override
  Stream<FileContent> load() async* {
    yield await _accessFile((f) async => FileContent(await f.readAsBytes()));
  }

  @override
  Future<bool> checkExists() async {
    try {
      if (file.existsSync()) {
        return true;
      }
      if ((KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) &&
          filePickerIdentifier != null) {
        try {
          return await _accessFile((f) async => f.existsSync());
        } catch (e) {
          _logger.fine('Access check failed for $displayPath: $e');
          return false;
        }
      }
      return false;
    } catch (e) {
      _logger.fine('checkExists error for $displayPath: $e');
      return false;
    }
  }

  Future<T> _accessFile<T>(Future<T> Function(File file) cb) async {
    if ((KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) &&
        filePickerIdentifier != null) {
      final oldFileInfo = filePickerInfo;
      final identifier = oldFileInfo?.identifier ?? filePickerIdentifier!;
      return await FilePickerWritable().readFile(
        identifier: identifier,
        reader: (fileInfo, file) async {
          _logger.finest('Got uri: ${fileInfo.uri}');
          if (fileInfo.identifier != identifier) {
            _logger.severe(
              'Identifier changed. panic. $fileInfo vs $identifier',
            );
          }
          return await cb(fileSystem.file(file.path));
        },
      );
    } else if (KeyNestPlatform.isMacOS && macOsSecureBookmark != null) {
      final resolved = await SecureBookmarks().resolveBookmark(
        macOsSecureBookmark!,
      );
      _logger.finer('Reading from secure  bookmark. ($resolved)');
      if (resolved != file) {
        _logger.warning(
          'Stored secure bookmark resolves to a different file than'
          ' we originally opened. $resolved vs. $file',
        );
      }
      final access = await SecureBookmarks()
          .startAccessingSecurityScopedResource(resolved);
      _logger.fine('startAccessingSecurityScopedResource: $access');
      try {
        return await cb(fileSystem.file(resolved.path));
      } finally {
        await SecureBookmarks().stopAccessingSecurityScopedResource(resolved);
      }
    } else if (KeyNestPlatform.isIOS && !file.existsSync()) {
      // On iOS we must not store the absolute path, but since we do, try to
      // load it relative from application support.
      _logger.fine(
        'iOS file ${file.path} no longer exists, checking new paths',
      );
      final docDir = (await PathUtils().getAppDocDirectory(
        ensureCreated: true,
      )).childFile(file.basename);
      if (docDir.existsSync()) {
        _logger.fine('${file.path} exists at ${docDir.path}.');
        return cb(docDir);
      }

      final newFile = (await PathUtils().getAppDataDirectory()).childFile(
        file.basename,
      );
      _logger.fine(
        'iOS file ${file.path} no longer exists, checking ${newFile.path}',
      );
      if (newFile.existsSync()) {
        _logger.fine('... exists, moving to ${docDir.path}');
        final renamed = newFile.renameSync(docDir.path);
        return cb(renamed);
      }
    }
    return cb(file);
  }

  @override
  String get displayPath => filePickerInfo?.uri ?? file.absolute.path;

  @override
  String get displayNameFromPath {
    final raw = filePickerInfo?.fileName ?? displayPath;
    return FileSource.cleanDisplayName(raw);
  }

  @override
  Future<Map<String, dynamic>?> write(
    Uint8List bytes,
    Map<String, dynamic>? previousMetadata,
  ) async {
    if (filePickerIdentifier != null) {
      _logger.finer('Writing into file with file picker.');
      final identifier = filePickerInfo?.identifier ?? filePickerIdentifier;
      final baseName =
          displayNameFromPath.toLowerCase().endsWith(AppConstants.kdbxExtension)
          ? displayNameFromPath
          : '$displayNameFromPath${AppConstants.kdbxExtension}';
      await createFileInNewTempDirectory(
        baseName,
        (f) async {
          await f.writeAsBytes(bytes, flush: true);
          final fileInfo = await FilePickerWritable().writeFileWithIdentifier(
            identifier!,
            f,
          );
          if (fileInfo.identifier != identifier) {
            _logger.severe('Panic, fileIdentifier changed. must no happen.');
          }
        },
      );
    } else {
      _logger.finer('Writing into file directly.');
      await _accessFile((f) async {
        final parentDir = f.parent;
        if (parentDir.existsSync()) {
          final tempFile = parentDir.childFile(
            '${f.basename}.tmp_${DateTime.now().millisecondsSinceEpoch}',
          );
          try {
            await tempFile.writeAsBytes(bytes, flush: true);
            if (KeyNestPlatform.isWindows) {
              await tempFile.copy(f.path);
              await tempFile.delete();
            } else {
              await tempFile.rename(f.path);
            }
            return;
          } catch (e, stack) {
            _logger.warning(
              'Atomic write via temp file failed, falling back to direct write: $e',
              e,
              stack,
            );
            try {
              if (tempFile.existsSync()) {
                await tempFile.delete();
              }
            } catch (_) {}
          }
        }
        await f.writeAsBytes(bytes, flush: true);
      });
    }
    return null;
  }

  static Future<T> createFileInNewTempDirectory<T>(
    String baseName,
    Future<T> Function(File tempFile) callback,
  ) async {
    if (baseName.length > 30) {
      final ext = baseName.toLowerCase().endsWith(AppConstants.kdbxExtension)
          ? baseName.substring(
              baseName.length - AppConstants.kdbxExtension.length,
            )
          : AppConstants.kdbxExtension;
      final nameWithoutExt =
          baseName.toLowerCase().endsWith(AppConstants.kdbxExtension)
          ? baseName.substring(
              0,
              baseName.length - AppConstants.kdbxExtension.length,
            )
          : (baseName.contains('.')
                ? baseName.substring(0, baseName.lastIndexOf('.'))
                : baseName);
      final effectiveExt = ext.toLowerCase() == AppConstants.kdbxExtension
          ? ext
          : AppConstants.kdbxExtension;
      final maxNameLen = 30 - effectiveExt.length;
      final shortenedName = maxNameLen > 0
          ? (nameWithoutExt.length > maxNameLen
                ? nameWithoutExt.substring(0, maxNameLen)
                : nameWithoutExt)
          : (nameWithoutExt.isNotEmpty ? nameWithoutExt.substring(0, 1) : 'v');
      baseName = '$shortenedName$effectiveExt';
    }
    final tempDirBase = await PathUtils().getTemporaryDirectory();
    final tempDir = tempDirBase.childDirectory(UuidUtil.createUuid());
    await tempDir.create(recursive: true);
    final tempFile = tempDir.childFile(baseName);
    try {
      return await callback(tempFile);
    } finally {
      unawaited(
        tempDir.delete(recursive: true).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          _logger.warning('Error while deleting temp dir.', error, stackTrace);
          return tempDir;
        }),
      );
    }
  }

  @override
  bool get supportsWrite => true;

  @override
  FileSourceIcon get displayIcon => FileSourceIcon.hdd;

  @override
  FileSource copyWithDatabaseName(String databaseName) => FileSourceLocal(
    file,
    databaseName: databaseName,
    uuid: uuid,
    macOsSecureBookmark: macOsSecureBookmark,
    filePickerIdentifier: filePickerIdentifier,
  );

  @NonNls
  @override
  Map<String, String?> toDebugMap() => {
    ...super.toDebugMap(),
    'filePickerIdentifier': filePickerIdentifier,
    'local': macOsSecureBookmark != null ? 'macOsSecureBookmark' : 'internal',
  };
}
