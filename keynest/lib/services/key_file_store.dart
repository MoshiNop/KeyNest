import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('KeyNestKeyFileStore');

/// Safe reference to a key file associated with a specific vault.
/// Never contains master passwords, raw key file contents, or derived encryption keys.
class KeyFileReference {
  const KeyFileReference({
    required this.vaultUuid,
    required this.displayName,
    this.filePath,
    this.filePickerIdentifier,
    this.macOsBookmark,
    this.formatName,
    this.updatedAt,
  });

  factory KeyFileReference.fromJson(Map<String, dynamic> json) {
    return KeyFileReference(
      vaultUuid: json['vaultUuid'] as String,
      displayName: json['displayName'] as String? ?? 'keyfile',
      filePath: json['filePath'] as String?,
      filePickerIdentifier: json['filePickerIdentifier'] as String?,
      macOsBookmark: json['macOsBookmark'] as String?,
      formatName: json['formatName'] as String?,
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'] as String)
          : null,
    );
  }

  /// UUID of the vault this key file is configured for.
  final String vaultUuid;

  /// User-facing display name of the key file (e.g. "my_vault.keyx").
  final String displayName;

  /// Direct filesystem path (primarily desktop / unconfined files).
  final String? filePath;

  /// Storage Access Framework identifier or JSON serialized [FileInfo] from [FilePickerWritable].
  final String? filePickerIdentifier;

  /// macOS Security-Scoped Bookmark for sandboxed access.
  final String? macOsBookmark;

  /// Name of the key file format (e.g. "xmlV2", "binary32").
  final String? formatName;

  /// When this association was last configured.
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'vaultUuid': vaultUuid,
    'displayName': displayName,
    if (filePath != null) 'filePath': filePath,
    if (filePickerIdentifier != null)
      'filePickerIdentifier': filePickerIdentifier,
    if (macOsBookmark != null) 'macOsBookmark': macOsBookmark,
    if (formatName != null) 'formatName': formatName,
    'updatedAt': (updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
  };
}

/// Service that securely persists and resolves key file references on a per-vault basis.
/// Ensures vault credentials remain completely decoupled and never leaks key files across vaults.
class KeyNestKeyFileStore {
  KeyNestKeyFileStore._();

  static final KeyNestKeyFileStore instance = KeyNestKeyFileStore._();

  static const String _fileName = 'keynest_vault_keyfiles.json';
  Map<String, KeyFileReference>? _cache;

  /// Clears the in-memory cache to simulate an app restart or force reloading from disk.
  @visibleForTesting
  void clearMemoryCache() {
    _cache = null;
  }

  /// Forces reloading persisted key file associations from storage.
  Future<void> reload() async {
    _cache = null;
    await _load();
  }

  Future<io.File> _getFile() async {
    final appDataDir = await PathUtils().getAppDataDirectory();
    return io.File(p.join(appDataDir.path, _fileName));
  }

  Future<Map<String, KeyFileReference>> _load() async {
    if (_cache != null) {
      return _cache!;
    }

    try {
      final file = await _getFile();
      if (file.existsSync()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = json.decode(content);
          if (decoded is Map<String, dynamic>) {
            _cache = decoded.map(
              (key, val) => MapEntry(
                key,
                KeyFileReference.fromJson(val as Map<String, dynamic>),
              ),
            );
            return _cache!;
          }
        }
      }
    } catch (e, st) {
      _logger.warning('Failed to load key file references: $e', e, st);
    }

    _cache = {};
    return _cache!;
  }

  Future<void> _save() async {
    if (_cache == null) {
      return;
    }
    try {
      final file = await _getFile();
      await file.parent.create(recursive: true);
      final jsonMap = _cache!.map((key, val) => MapEntry(key, val.toJson()));
      await file.writeAsString(json.encode(jsonMap), flush: true);
    } catch (e, st) {
      _logger.severe('Failed to save key file references: $e', e, st);
    }
  }

  /// Retrieves the key file reference for the given vault UUID, if one was configured.
  Future<KeyFileReference?> getReference(String vaultUuid) async {
    final map = await _load();
    return map[vaultUuid];
  }

  /// Checks if a key file is configured for the given vault UUID.
  Future<bool> hasKeyFile(String vaultUuid) async {
    final ref = await getReference(vaultUuid);
    return ref != null;
  }

  /// Associates a key file reference with a specific vault.
  Future<void> saveReference({
    required String vaultUuid,
    required String displayName,
    String? filePath,
    String? filePickerIdentifier,
    String? macOsBookmark,
    String? formatName,
  }) async {
    final map = await _load();
    map[vaultUuid] = KeyFileReference(
      vaultUuid: vaultUuid,
      displayName: displayName,
      filePath: filePath,
      filePickerIdentifier: filePickerIdentifier,
      macOsBookmark: macOsBookmark,
      formatName: formatName,
      updatedAt: DateTime.now().toUtc(),
    );
    await _save();
    _logger.fine(
      'Saved key file reference for vault $vaultUuid ($displayName)',
    );
  }

  /// Removes the key file association for a specific vault.
  Future<void> removeReference(String vaultUuid) async {
    final map = await _load();
    if (map.remove(vaultUuid) != null) {
      await _save();
      _logger.fine('Removed key file reference for vault $vaultUuid');
    }
  }

  /// Attempts to read the bytes for the key file configured for [vaultUuid].
  /// Returns `null` if the reference cannot be resolved or is inaccessible,
  /// prompting the user to safely re-select their file.
  Future<Uint8List?> resolveKeyFileBytes(String vaultUuid) async {
    final ref = await getReference(vaultUuid);
    if (ref == null) {
      return null;
    }

    // 1. Mobile Storage Access Framework (SAF) via FilePickerWritable
    if ((KeyNestPlatform.isAndroid || KeyNestPlatform.isIOS) &&
        ref.filePickerIdentifier != null) {
      try {
        final identifier = () {
          if (ref.filePickerIdentifier!.startsWith('{')) {
            try {
              final info = FileInfo.fromJson(
                json.decode(ref.filePickerIdentifier!) as Map<String, dynamic>,
              );
              return info.identifier;
            } catch (_) {}
          }
          return ref.filePickerIdentifier!;
        }();

        final bytes = await FilePickerWritable().readFile(
          identifier: identifier,
          reader: (fileInfo, file) async {
            return await file.readAsBytes();
          },
        );
        if (bytes.isNotEmpty) {
          return bytes;
        }
      } catch (e) {
        _logger.warning(
          'Failed to resolve mobile key file URI for vault $vaultUuid: $e',
        );
      }
    }

    // 2. macOS Secure-Scoped Bookmark
    if (KeyNestPlatform.isMacOS && ref.macOsBookmark != null) {
      try {
        final resolved = await SecureBookmarks().resolveBookmark(
          ref.macOsBookmark!,
        );
        final access = await SecureBookmarks()
            .startAccessingSecurityScopedResource(resolved);
        final ioFile = io.File(resolved.path);
        try {
          if (ioFile.existsSync()) {
            return await ioFile.readAsBytes();
          }
        } finally {
          if (access) {
            await SecureBookmarks().stopAccessingSecurityScopedResource(
              resolved,
            );
          }
        }
      } catch (e) {
        _logger.warning(
          'Failed to resolve macOS bookmark for vault $vaultUuid: $e',
        );
      }
    }

    // 3. Direct local filesystem path
    if (ref.filePath != null && ref.filePath!.isNotEmpty) {
      try {
        final localFile = io.File(ref.filePath!);
        if (localFile.existsSync()) {
          return await localFile.readAsBytes();
        }
      } catch (e) {
        _logger.warning(
          'Failed to read local key file at ${ref.filePath} for vault $vaultUuid: $e',
        );
      }
    }

    return null;
  }
}
