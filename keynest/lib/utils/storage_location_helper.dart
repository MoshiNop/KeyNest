import 'dart:io' as io;

import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/utils/constants.dart';
import 'package:path/path.dart' as p;

/// Helper to format raw storage paths and Android content:// URIs into clean,
/// human-friendly location labels across Android, Windows, and Linux.
class KeyNestStorageLocationHelper {
  /// Resolves a user-friendly storage location label for the given [source].
  static String getFriendlyLocation(FileSource source) {
    if (source is FileSourceCloudStorage) {
      final folder = source.fileInfo['path'] ?? 'KeyNest';
      final cleanFolder = folder.replaceAll(RegExp(r'^/|/$'), '');
      return '${source.provider.displayName}/$cleanFolder';
    }

    if (source is FileSourceLocal) {
      final uri = source.filePickerInfo?.uri;
      if (uri != null && uri.startsWith('content://')) {
        return _formatAndroidContentUri(
          uri,
          fileName: source.filePickerInfo?.fileName,
        );
      }

      // Check if displayPath itself is a content:// URI
      if (source.displayPath.startsWith('content://')) {
        return _formatAndroidContentUri(
          source.displayPath,
          fileName: source.displayNameFromPath,
        );
      }

      // Standard desktop / filesystem path
      return _formatFilesystemPath(source.file.path);
    }

    // Fallback for custom or unknown sources
    if (source.displayPath.startsWith('content://')) {
      return _formatAndroidContentUri(source.displayPath);
    }
    return _formatFilesystemPath(source.displayPath);
  }

  /// Parses Android content:// document provider URIs into human-readable labels.
  /// Handles externalstorage, downloads, media, and third-party document providers.
  static String _formatAndroidContentUri(String rawUri, {String? fileName}) {
    try {
      final uri = Uri.parse(rawUri);
      final authority = uri.authority;
      final pathSegments = uri.pathSegments;

      // Authority: com.android.externalstorage.documents
      // e.g. /document/primary:Download/Secret/vault.kdbx or /tree/primary:Download
      if (authority.contains('externalstorage.documents')) {
        final docIndex = pathSegments.indexOf('document');
        final treeIndex = pathSegments.indexOf('tree');
        String? docId;

        if (docIndex >= 0 && docIndex < pathSegments.length - 1) {
          docId = pathSegments[docIndex + 1];
        } else if (treeIndex >= 0 && treeIndex < pathSegments.length - 1) {
          docId = pathSegments[treeIndex + 1];
        }

        if (docId != null && docId.isNotEmpty) {
          docId = Uri.decodeComponent(docId);
          final colonIdx = docId.indexOf(':');
          final rootId = colonIdx >= 0 ? docId.substring(0, colonIdx) : 'primary';
          final subPath = colonIdx >= 0 ? docId.substring(colonIdx + 1) : docId;

          // Strip filename if present at end
          var folderPath = subPath;
          if (folderPath.toLowerCase().endsWith(AppConstants.kdbxExtension)) {
            final lastSlash = folderPath.lastIndexOf('/');
            folderPath = lastSlash >= 0 ? folderPath.substring(0, lastSlash) : '';
          } else if (fileName != null && folderPath.endsWith(fileName)) {
            final trimmed = folderPath.substring(0, folderPath.length - fileName.length);
            folderPath = trimmed.replaceAll(RegExp(r'/+$'), '');
          }

          if (rootId.toLowerCase() == 'primary') {
            if (folderPath.isEmpty) {
              return 'Internal storage';
            }
            // Friendly prefix mapping
            if (folderPath.startsWith('Download') || folderPath.startsWith('Documents')) {
              return folderPath;
            }
            return 'Internal storage/$folderPath';
          } else {
            // Secondary storage / SD Card
            if (folderPath.isEmpty) {
              return 'SD card';
            }
            return 'SD card/$folderPath';
          }
        }
      }

      // Authority: com.android.providers.downloads.documents
      if (authority.contains('downloads.documents')) {
        final docIndex = pathSegments.indexOf('document');
        if (docIndex >= 0 && docIndex < pathSegments.length - 1) {
          final docId = Uri.decodeComponent(pathSegments[docIndex + 1]);
          if (docId.startsWith('raw:')) {
            final rawPath = docId.substring(4);
            return _formatFilesystemPath(rawPath);
          }
          if (docId.contains('Download')) {
            final match = RegExp(r'Download(?:/(.*))?').firstMatch(docId);
            if (match != null) {
              final rest = match.group(1);
              if (rest != null && rest.isNotEmpty) {
                var folder = rest;
                if (folder.toLowerCase().endsWith(AppConstants.kdbxExtension)) {
                  final lastSlash = folder.lastIndexOf('/');
                  folder = lastSlash >= 0 ? folder.substring(0, lastSlash) : '';
                }
                return folder.isEmpty ? 'Download' : 'Download/$folder';
              }
            }
            return 'Download';
          }
        }
        return 'Download';
      }

      // Generic document providers: attempt to extract clean folder name
      final lastSegment = pathSegments.isNotEmpty ? Uri.decodeComponent(pathSegments.last) : '';
      if (lastSegment.contains(':')) {
        final afterColon = lastSegment.substring(lastSegment.indexOf(':') + 1);
        if (afterColon.isNotEmpty && !afterColon.toLowerCase().endsWith(AppConstants.kdbxExtension)) {
          return 'Selected storage location/$afterColon';
        }
      }

      return 'Custom storage location';
    } catch (_) {
      return 'Custom storage location';
    }
  }

  /// Formats native filesystem paths on Windows, Linux, and macOS.
  static String _formatFilesystemPath(String fullPath) {
    if (fullPath.isEmpty) {
      return 'Local storage';
    }

    final normalized = fullPath.replaceAll(r'\', '/');
    final dirPath = p.posix.dirname(normalized);

    // If dirPath is current directory or root
    if (dirPath == '.' || dirPath.isEmpty) {
      return 'Local storage';
    }

    // Handle common user directories (Documents, Downloads)
    const wellKnownDirs = ['Documents', 'Download', 'Downloads', 'KeyNest'];
    for (final dir in wellKnownDirs) {
      final pattern = '/$dir';
      final idx = normalized.indexOf(pattern);
      if (idx >= 0) {
        final rel = normalized.substring(idx + 1);
        final relDir = p.posix.dirname(rel);
        if (relDir != '.' && relDir.isNotEmpty) {
          return relDir;
        }
        return dir;
      }
    }

    // Windows drive root check: C:/
    if (RegExp(r'^[a-zA-Z]:/?$').hasMatch(dirPath)) {
      return dirPath;
    }

    // Replace user home directory if known
    try {
      final home = io.Platform.environment['USERPROFILE'] ??
          io.Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        final normHome = home.replaceAll(r'\', '/');
        if (dirPath.startsWith(normHome)) {
          final sub = dirPath.substring(normHome.length).replaceAll(RegExp(r'^/+'), '');
          return sub.isNotEmpty ? '~/$sub' : '~';
        }
      }
    } catch (_) {}

    // Fall back to the last 2-3 segments for readable display without exposing full absolute paths
    final parts = dirPath.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length > 2) {
      return parts.sublist(parts.length - 2).join('/');
    }
    return dirPath;
  }
}
