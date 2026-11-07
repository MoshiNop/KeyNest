import 'dart:io' as io;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _logger = Logger('KeyNestSafService');

/// Represents a chosen destination directory, which may be an Android
/// Storage Access Framework tree URI (with a friendly display path) or a
/// directly accessible filesystem directory.
class KeyNestDirectoryDestination {
  const KeyNestDirectoryDestination({
    required this.displayPath,
    this.treeUri,
    this.displayName,
  });

  final String displayPath;
  final String? treeUri;
  final String? displayName;

  bool get isSaf => treeUri != null && treeUri!.isNotEmpty;

  @override
  String toString() =>
      'KeyNestDirectoryDestination(displayPath: $displayPath, isSaf: $isSaf, treeUri: $treeUri)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeyNestDirectoryDestination &&
          runtimeType == other.runtimeType &&
          displayPath == other.displayPath &&
          treeUri == other.treeUri;

  @override
  int get hashCode => Object.hash(displayPath, treeUri);
}

class KeyNestSafService {
  static const MethodChannel _miscChannel = MethodChannel('app.keynest/misc');

  /// Prompts the user to select a destination directory using the appropriate
  /// mechanism for the current platform:
  /// - On Android: Native Storage Access Framework ACTION_OPEN_DOCUMENT_TREE
  ///   with persistable permissions.
  /// - On Desktop: System folder picker via file_selector.
  static Future<KeyNestDirectoryDestination?> pickDirectory({
    String? initialPath,
    BuildContext? parentContext,
  }) async {
    if (KeyNestPlatform.isAndroid) {
      try {
        final result = await _miscChannel.invokeMapMethod<String, dynamic>(
          'pickDirectoryTree',
        );
        if (result != null) {
          final treeUri = result['treeUri'] as String?;
          final displayPath = result['displayPath'] as String?;
          final dirName = result['displayName'] as String?;
          if (treeUri != null && displayPath != null) {
            _logger.fine(
              'User picked Android SAF directory: treeUri=$treeUri, displayPath=$displayPath',
            );
            return KeyNestDirectoryDestination(
              displayPath: displayPath,
              treeUri: treeUri,
              displayName: dirName,
            );
          }
        }
        return null; // User cancelled
      } catch (e) {
        _logger.warning('Native pickDirectoryTree failed on Android: $e');
        return null;
      }
    }

    // Desktop platforms (Windows, Linux, macOS)
    try {
      final picked = await getDirectoryPath(
        initialDirectory: initialPath,
        confirmButtonText: 'Select Destination Folder',
      );
      if (picked != null && picked.trim().isNotEmpty) {
        return KeyNestDirectoryDestination(
          displayPath: picked.trim(),
          displayName: p.basename(picked.trim()),
        );
      }
    } catch (e) {
      _logger.warning('getDirectoryPath threw exception on desktop: $e');
    }
    return null;
  }

  /// On Android, checks if the app already holds a persisted SAF tree URI
  /// permission for the given directory path.
  static Future<String?> getPersistedTreeUriForPath(String path) async {
    if (!KeyNestPlatform.isAndroid) {
      return null;
    }
    try {
      final uri = await _miscChannel.invokeMethod<String>(
        'getPersistedTreeUriForPath',
        {'path': path},
      );
      return uri;
    } catch (e) {
      _logger.fine('getPersistedTreeUriForPath check failed: $e');
      return null;
    }
  }

  /// Verifies whether the application has direct POSIX filesystem write
  /// authorization for the given directory path on the current OS.
  static bool isDirectlyWritable(String directoryPath) {
    try {
      final dir = io.Directory(directoryPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final probe = io.File(
        p.join(
          directoryPath,
          '.probe_${DateTime.now().microsecondsSinceEpoch}.tmp',
        ),
      );
      probe.writeAsStringSync('keynest_probe', flush: true);
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Computes the relative subdirectory path inside an Android SAF [treeUri]
  /// when [displayPath] points to a nested folder beneath the persisted tree root.
  static String? extractRelativeSubPath(String? treeUri, String displayPath) {
    if (treeUri == null || treeUri.isEmpty || displayPath.trim().isEmpty) {
      return null;
    }
    try {
      final uri = Uri.parse(treeUri);
      final segments = uri.pathSegments;
      final treeIdx = segments.indexOf('tree');
      if (treeIdx == -1 || treeIdx + 1 >= segments.length) {
        return null;
      }
      final docId = Uri.decodeComponent(segments[treeIdx + 1]);
      final parts = docId.split(':');
      String treeRootPath;
      if (parts.length >= 2) {
        final vol = parts[0];
        final rel = parts.sublist(1).join(':');
        if (vol.toLowerCase() == 'primary') {
          treeRootPath = rel.isEmpty
              ? '/storage/emulated/0'
              : '/storage/emulated/0/$rel';
        } else {
          treeRootPath = rel.isEmpty ? '/storage/$vol' : '/storage/$vol/$rel';
        }
      } else {
        treeRootPath = docId.toLowerCase() == 'primary'
            ? '/storage/emulated/0'
            : docId;
      }

      var normTree = treeRootPath.replaceAll('\\', '/');
      while (normTree.endsWith('/') && normTree.length > 1) {
        normTree = normTree.substring(0, normTree.length - 1);
      }
      var normTarget = displayPath.replaceAll('\\', '/');
      while (normTarget.endsWith('/') && normTarget.length > 1) {
        normTarget = normTarget.substring(0, normTarget.length - 1);
      }

      if (normTarget.toLowerCase() == normTree.toLowerCase()) {
        return null;
      }
      final prefix = '$normTree/';
      if (normTarget.toLowerCase().startsWith(prefix.toLowerCase())) {
        final sub = normTarget.substring(prefix.length).trim();
        return sub.isEmpty ? null : sub;
      }
    } catch (_) {}
    return null;
  }

  /// Checks if a file named [fileName] already exists in [destination].
  static Future<bool> checkFileExists({
    required KeyNestDirectoryDestination destination,
    required String fileName,
  }) async {
    if (destination.isSaf) {
      try {
        final subPath = extractRelativeSubPath(
          destination.treeUri,
          destination.displayPath,
        );
        final exists = await _miscChannel.invokeMethod<bool>(
          'safCheckFileExists',
          {
            'treeUri': destination.treeUri,
            'fileName': fileName,
            'subPath': ?subPath,
          },
        );
        return exists == true;
      } catch (e) {
        _logger.warning('safCheckFileExists error: $e');
        return false;
      }
    }

    final destFile = io.File(p.join(destination.displayPath, fileName));
    return destFile.existsSync();
  }

  /// Writes [bytes] to [fileName] in [destination].
  ///
  /// For Android SAF destinations:
  /// - The bytes are staged into a temporary file in the app's cache directory.
  /// - Staged content is written through DocumentProvider streams via native SAF.
  /// - Returns the document `content://` URI string which can be stored in
  ///   [FileSourceLocal.filePickerIdentifier].
  ///
  /// For direct filesystem directories:
  /// - Writes atomically using a `.tmp` file in the destination directory,
  ///   moves any existing target to `.bak`, promotes `.tmp`, and cleans `.bak`.
  /// - Returns the absolute file path.
  ///
  /// Cleans up all temporary files on completion or failure.
  static Future<String> writeVaultFile({
    required KeyNestDirectoryDestination destination,
    required String fileName,
    required Uint8List bytes,
    required bool overwrite,
  }) async {
    io.File? cacheTempFile;

    try {
      // 1. Write to destination
      if (destination.isSaf) {
        // Stage bytes into app private cache for native SAF streaming
        final tempDir = await getTemporaryDirectory();
        cacheTempFile = io.File(
          p.join(
            tempDir.path,
            'import_stage_${DateTime.now().microsecondsSinceEpoch}.kdbx.tmp',
          ),
        );
        await cacheTempFile.writeAsBytes(bytes, flush: true);

        final subPath = extractRelativeSubPath(
          destination.treeUri,
          destination.displayPath,
        );
        final res = await _miscChannel.invokeMapMethod<String, dynamic>(
          'safWriteFile',
          {
            'treeUri': destination.treeUri,
            'fileName': fileName,
            'sourceFilePath': cacheTempFile.path,
            'overwrite': overwrite,
            'subPath': ?subPath,
          },
        );
        if (res == null || res['uri'] == null) {
          throw const io.FileSystemException(
            'SAF document provider returned null uri after writing.',
          );
        }
        _logger.fine(
          'Successfully wrote vault to SAF document: ${res['uri']} (${res['size']} bytes)',
        );
        return res['uri'] as String;
      } else {
        // Direct filesystem atomic write (.tmp -> .bak -> target)
        final targetDir = io.Directory(destination.displayPath);
        if (!targetDir.existsSync()) {
          targetDir.createSync(recursive: true);
        }

        final finalFile = io.File(p.join(targetDir.path, fileName));
        if (finalFile.existsSync() && !overwrite) {
          throw io.FileSystemException(
            'A file named $fileName already exists in the destination folder.',
            finalFile.path,
          );
        }

        final ts = DateTime.now().microsecondsSinceEpoch;
        final localTempFile = io.File(
          p.join(targetDir.path, '$fileName.tmp_$ts'),
        );
        io.File? bakFile;

        try {
          await localTempFile.writeAsBytes(bytes, flush: true);
          final writtenLen = localTempFile.lengthSync();
          if (writtenLen != bytes.length) {
            throw io.FileSystemException(
              'Incomplete write to temporary vault file '
              '($writtenLen != ${bytes.length} bytes).',
              localTempFile.path,
            );
          }
        } catch (e) {
          try {
            if (localTempFile.existsSync()) {
              localTempFile.deleteSync();
            }
          } catch (_) {}
          rethrow;
        }

        try {
          if (finalFile.existsSync()) {
            bakFile = io.File(p.join(targetDir.path, '$fileName.bak_$ts'));
            finalFile.renameSync(bakFile.path);
          }

          try {
            localTempFile.renameSync(finalFile.path);
          } on io.FileSystemException {
            await localTempFile.copy(finalFile.path);
            try {
              localTempFile.deleteSync();
            } catch (_) {}
          }

          if (!finalFile.existsSync() ||
              finalFile.lengthSync() != bytes.length) {
            throw io.FileSystemException(
              'Vault verification failed after atomic write.',
              finalFile.path,
            );
          }
        } catch (e) {
          if (bakFile != null && bakFile.existsSync()) {
            try {
              if (finalFile.existsSync()) {
                finalFile.deleteSync();
              }
              bakFile.renameSync(finalFile.path);
            } catch (restoreErr, restoreStack) {
              _logger.severe(
                'Failed to restore backup vault ${bakFile.path}',
                restoreErr,
                restoreStack,
              );
            }
          }
          try {
            if (localTempFile.existsSync()) {
              localTempFile.deleteSync();
            }
          } catch (_) {}
          rethrow;
        }

        if (bakFile != null) {
          try {
            if (bakFile.existsSync()) {
              bakFile.deleteSync();
            }
          } catch (_) {}
        }

        return finalFile.path;
      }
    } finally {
      try {
        if (cacheTempFile != null && cacheTempFile.existsSync()) {
          cacheTempFile.deleteSync();
        }
      } catch (_) {}
    }
  }
}
