// ignore_for_file: use_build_context_synchronously
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_state.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';
import 'package:keynest/services/key_file_store.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/keynest_saf_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('KeyNestCloudVaultBrowserScreen');

class CloudVaultItem {
  CloudVaultItem({
    required this.id,
    required this.name,
    this.sizeBytes,
    this.modifiedTime,
    required this.isLinked,
    this.rawMetadata,
  });

  final String id;
  final String name;
  final int? sizeBytes;
  final DateTime? modifiedTime;
  final bool isLinked;
  final dynamic rawMetadata;

  String get formattedSize {
    if (sizeBytes == null || sizeBytes == 0) {
      return '0 B';
    }
    if (sizeBytes! < 1024) {
      return '$sizeBytes B';
    }
    if (sizeBytes! < 1024 * 1024) {
      return '${(sizeBytes! / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class KeyNestCloudVaultBrowserScreen extends StatefulWidget {
  const KeyNestCloudVaultBrowserScreen({
    super.key,
    required this.provider,
  });

  final CloudStorageProvider provider;

  static Route<void> route(CloudStorageProvider provider) {
    return MaterialPageRoute<void>(
      settings: RouteSettings(name: '/cloud/browser/${provider.id}'),
      builder: (_) => KeyNestCloudVaultBrowserScreen(provider: provider),
    );
  }

  static bool isValidKdbxBytes(Uint8List bytes) {
    if (bytes.length < 8) {
      return false;
    }
    final bdata = ByteData.sublistView(bytes);
    final sig1 = bdata.getUint32(0, Endian.little);
    final sig2 = bdata.getUint32(4, Endian.little);
    return sig1 == 0x9AA2D903 && (sig2 == 0xB54BFB67 || sig2 == 0xB54BFB66);
  }

  @override
  State<KeyNestCloudVaultBrowserScreen> createState() =>
      _KeyNestCloudVaultBrowserScreenState();
}

class _KeyNestCloudVaultBrowserScreenState
    extends State<KeyNestCloudVaultBrowserScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<CloudVaultItem> _vaults = [];
  final Set<String> _selectedIds = {};
  bool _isActionRunning = false;
  KeyNestDirectoryDestination? _selectedDestination;

  @override
  void initState() {
    super.initState();
    _initDestinationDir();
    _fetchCloudVaults();
  }

  Future<void> _initDestinationDir() async {
    try {
      final dest = await _getDefaultDestination();
      if (mounted) {
        setState(() {
          _selectedDestination = dest;
        });
      }
    } catch (e) {
      _logger.warning('Failed to initialize destination directory: $e');
    }
  }

  Future<void> _fetchCloudVaults() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFiles.entries.map((e) => e.key).toList();

    try {
      final items = <CloudVaultItem>[];

      if (widget.provider is GoogleDriveProvider) {
        final google = widget.provider as GoogleDriveProvider;
        final folderId = await google.driveClient.getOrCreateKeyNestFolder(
          stateStore: google.stateStore,
        );
        final driveFiles = await google.driveClient.findFilesInFolder(folderId);

        for (final f in driveFiles) {
          if (!f.name.toLowerCase().endsWith('.kdbx')) {
            continue;
          }
          final isLinked = openedFiles.any(
            (s) =>
                s.displayName.toLowerCase() == f.name.toLowerCase() ||
                (s is FileSourceCloudStorage && s.fileInfo['id'] == f.id),
          );
          items.add(
            CloudVaultItem(
              id: f.id,
              name: f.name,
              sizeBytes: f.sizeBytes,
              modifiedTime: f.modifiedTime,
              isLinked: isLinked,
              rawMetadata: f,
            ),
          );
        }
      } else if (widget.provider is DropboxProvider) {
        final dropbox = widget.provider as DropboxProvider;
        var files = await dropbox.dropboxClient.listFiles(
          folderPath: '/KeyNest',
        );
        if (files.isEmpty) {
          final rootFiles = await dropbox.dropboxClient.listFiles(
            folderPath: '',
          );
          files = rootFiles
              .where((f) => f.name.toLowerCase().endsWith('.kdbx'))
              .toList();
        }

        for (final f in files) {
          if (!f.name.toLowerCase().endsWith('.kdbx')) {
            continue;
          }
          final isLinked = openedFiles.any(
            (s) =>
                s.displayName.toLowerCase() == f.name.toLowerCase() ||
                (s is FileSourceCloudStorage &&
                    s.fileInfo['path']?.toLowerCase() ==
                        f.pathLower.toLowerCase()),
          );
          items.add(
            CloudVaultItem(
              id: f.pathLower,
              name: f.name,
              sizeBytes: f.size,
              modifiedTime: f.serverModified,
              isLinked: isLinked,
              rawMetadata: f,
            ),
          );
        }
      }

      if (mounted) {
        setState(() {
          _vaults = items;
          _isLoading = false;
        });
      }
    } catch (e, stack) {
      _logger.warning('Failed to fetch cloud vaults: $e', stack);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage =
              'Could not load vaults from ${widget.provider.displayName}: $e';
        });
      }
    }
  }

  Future<void> _openSelectedInKeyNest() async {
    final selectedVaults = _vaults
        .where((v) => _selectedIds.contains(v.id))
        .toList();
    if (selectedVaults.isEmpty) {
      return;
    }

    for (final vault in selectedVaults) {
      FileSource source;
      if (widget.provider is GoogleDriveProvider) {
        source = FileSourceCloudStorage(
          provider: widget.provider,
          fileInfo: {
            'id': vault.id,
            'name': vault.name,
            'size': vault.sizeBytes?.toString(),
          },
          uuid: const Uuid().v4(),
        );
      } else {
        source = FileSourceCloudStorage(
          provider: widget.provider,
          fileInfo: {
            'path': vault.id,
            'name': vault.name,
          },
          uuid: const Uuid().v4(),
        );
      }

      if (mounted) {
        await Navigator.of(context).push(CredentialsScreen.route(source));
      }
    }
  }

  Future<KeyNestDirectoryDestination> _getDefaultDestination() async {
    if (KeyNestPlatform.isAndroid) {
      try {
        final extDirs = await getExternalStorageDirectories(
          type: StorageDirectory.documents,
        );
        if (extDirs != null && extDirs.isNotEmpty) {
          final dir = extDirs.first;
          if (dir.existsSync() && KeyNestSafService.isDirectlyWritable(dir.path)) {
            return KeyNestDirectoryDestination(
              displayPath: dir.path,
              displayName: 'KeyNest Documents',
            );
          }
        }
      } catch (_) {}

      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null && ext.existsSync() && KeyNestSafService.isDirectlyWritable(ext.path)) {
          return KeyNestDirectoryDestination(
            displayPath: ext.path,
            displayName: 'KeyNest Storage',
          );
        }
      } catch (_) {}
    } else if (KeyNestPlatform.isWindows ||
        KeyNestPlatform.isMacOS ||
        KeyNestPlatform.isLinux) {
      try {
        final doc = await getApplicationDocumentsDirectory();
        if (doc.existsSync()) {
          return KeyNestDirectoryDestination(
            displayPath: doc.path,
            displayName: 'Documents',
          );
        }
      } catch (_) {}
    }

    try {
      final docDir = await PathUtils().getAppDocDirectory(ensureCreated: true);
      return KeyNestDirectoryDestination(
        displayPath: docDir.path,
        displayName: 'App Storage',
      );
    } catch (_) {
      final appData = await PathUtils().getAppDataDirectory();
      return KeyNestDirectoryDestination(
        displayPath: appData.path,
        displayName: 'App Storage',
      );
    }
  }

  Future<KeyNestDirectoryDestination?> _pickDestinationDirectory({
    BuildContext? parentContext,
  }) async {
    try {
      final initialDest =
          _selectedDestination ?? await _getDefaultDestination();

      final picked = await KeyNestSafService.pickDirectory(
        initialPath: initialDest.displayPath,
        parentContext: parentContext,
      );

      if (picked != null) {
        return picked;
      }
      return null;
    } catch (e) {
      _logger.warning('Error choosing destination directory: $e');
      final ctx = parentContext ?? (mounted ? context : null);
      if (ctx != null && ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text('Could not select directory: $e'),
            backgroundColor: KeyNestTokens.error,
          ),
        );
      }
      return null;
    }
  }

  Future<void> _confirmAndDeleteCloudVault(CloudVaultItem vault) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: KeyNestTokens.error),
            SizedBox(width: 8),
            Text('Delete Cloud Vault?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to permanently delete "${vault.name}" from ${widget.provider.displayName}?',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: KeyNestTokens.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: KeyNestTokens.error.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '• Vault: ${vault.name}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '• Size: ${vault.formattedSize}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '• Location: ${widget.provider.displayName}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'WARNING: This action deletes the vault file directly from your cloud storage. '
                    'Depending on your cloud provider, this may be irreversible or unrecoverable through KeyNest.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: KeyNestTokens.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (vault.isLinked) ...[
              const SizedBox(height: 12),
              Text(
                'Note: This vault is currently open in KeyNest. Deleting it will safely close and detach the active session.',
                style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: Theme.of(ctx).brightness == Brightness.dark
                      ? KeyNestTokens.textSecondaryDark
                      : KeyNestTokens.textSecondaryLight,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: KeyNestTokens.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete from Cloud'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _isActionRunning = true);

    try {
      // 1. Delete file on cloud provider
      if (widget.provider is GoogleDriveProvider) {
        final google = widget.provider as GoogleDriveProvider;
        await google.driveClient.deleteFile(vault.id);
      } else if (widget.provider is DropboxProvider) {
        final dropbox = widget.provider as DropboxProvider;
        await dropbox.dropboxClient.deleteFile(vault.id);
      }

      // 2. If open in KeyNest, safely close active session and detach state
      final kdbxBloc = context.read<KdbxBloc>();
      final openEntry = kdbxBloc.openedFiles.entries.firstWhereOrNull((entry) {
        final s = entry.key;
        if (widget.provider is GoogleDriveProvider &&
            s is FileSourceCloudStorage) {
          return s.fileInfo['id'] == vault.id ||
              s.displayName.toLowerCase() == vault.name.toLowerCase();
        } else if (widget.provider is DropboxProvider &&
            s is FileSourceCloudStorage) {
          return s.fileInfo['path']?.toLowerCase() == vault.id.toLowerCase() ||
              s.displayName.toLowerCase() == vault.name.toLowerCase();
        }
        return false;
      });

      if (openEntry != null) {
        if (KeyNestVaultScope.instance.getSelectedVault(kdbxBloc) ==
            openEntry.value.kdbxFile) {
          KeyNestVaultScope.instance.setSelectedVault(kdbxBloc, null);
        }
        KeyNestVaultScope.instance.clearVaultFromAllTabs(openEntry.key.uuid);
        KeyNestVaultScope.instance.clearVaultFromAllTabs(
          openEntry.key.displayPath,
        );

        if (widget.provider is GoogleDriveProvider) {
          await GoogleDriveSyncStateStore().clearVaultSyncState(
            openEntry.key.uuid,
          );
        } else if (widget.provider is DropboxProvider) {
          await DropboxSyncStateStore().clearVaultSyncState(openEntry.key.uuid);
        }

        await kdbxBloc.quickUnlockStorage.removeVaultCredential(
          openEntry.key.uuid,
        );
        await KeyNestKeyFileStore.instance.removeReference(openEntry.key.uuid);
        await kdbxBloc.close(openEntry.value.kdbxFile);

        final appDataBloc = context.read<AppDataBloc>();
        await appDataBloc.update((builder, data) {
          builder.previousFiles.removeWhere(
            (f) =>
                f.uuid == openEntry.key.uuid ||
                f.isSameFileAs(openEntry.value.openedFile),
          );
        });
      }

      _selectedIds.remove(vault.id);

      if (mounted) {
        setState(() => _isActionRunning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully deleted "${vault.name}" from ${widget.provider.displayName}.',
            ),
          ),
        );
        await _fetchCloudVaults();
      }
    } catch (e) {
      _logger.warning('Failed to delete cloud vault: $e');
      if (mounted) {
        setState(() => _isActionRunning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete vault: $e'),
            backgroundColor: KeyNestTokens.error,
          ),
        );
      }
    }
  }

  Future<void> _confirmAndDeleteSelectedVaults() async {
    final selectedVaults = _vaults
        .where((v) => _selectedIds.contains(v.id))
        .toList();
    if (selectedVaults.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        insetPadding: KeyNestDialogDefaults.insetPadding,
        actionsOverflowDirection: VerticalDirection.down,
        actionsPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        title: const KeyNestDialogTitle(
          title: 'Delete Selected Vaults?',
          icon: Icons.warning_amber_rounded,
          iconColor: KeyNestTokens.error,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to permanently delete ${selectedVaults.length} vault${selectedVaults.length > 1 ? 's' : ''} from ${widget.provider.displayName}?',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: KeyNestTokens.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: KeyNestTokens.error.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...selectedVaults.map(
                      (v) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '• ${v.name} (${v.formattedSize})',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                          softWrap: true,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'WARNING: This action deletes the files directly from your cloud storage. '
                      'This operation cannot be undone through KeyNest.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: KeyNestTokens.error,
                        fontWeight: FontWeight.w600,
                      ),
                      softWrap: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: KeyNestTokens.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete from Cloud'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _isActionRunning = true);

    try {
      final kdbxBloc = context.read<KdbxBloc>();
      final appDataBloc = context.read<AppDataBloc>();
      int deletedCount = 0;

      for (final vault in selectedVaults) {
        if (widget.provider is GoogleDriveProvider) {
          final google = widget.provider as GoogleDriveProvider;
          await google.driveClient.deleteFile(vault.id);
        } else if (widget.provider is DropboxProvider) {
          final dropbox = widget.provider as DropboxProvider;
          await dropbox.dropboxClient.deleteFile(vault.id);
        }

        final openEntry = kdbxBloc.openedFiles.entries.firstWhereOrNull((
          entry,
        ) {
          final s = entry.key;
          if (widget.provider is GoogleDriveProvider &&
              s is FileSourceCloudStorage) {
            return s.fileInfo['id'] == vault.id ||
                s.displayName.toLowerCase() == vault.name.toLowerCase();
          } else if (widget.provider is DropboxProvider &&
              s is FileSourceCloudStorage) {
            return s.fileInfo['path']?.toLowerCase() ==
                    vault.id.toLowerCase() ||
                s.displayName.toLowerCase() == vault.name.toLowerCase();
          }
          return false;
        });

        if (openEntry != null) {
          if (KeyNestVaultScope.instance.getSelectedVault(kdbxBloc) ==
              openEntry.value.kdbxFile) {
            KeyNestVaultScope.instance.setSelectedVault(kdbxBloc, null);
          }
          KeyNestVaultScope.instance.clearVaultFromAllTabs(openEntry.key.uuid);
          KeyNestVaultScope.instance.clearVaultFromAllTabs(
            openEntry.key.displayPath,
          );

          if (widget.provider is GoogleDriveProvider) {
            await GoogleDriveSyncStateStore().clearVaultSyncState(
              openEntry.key.uuid,
            );
          } else if (widget.provider is DropboxProvider) {
            await DropboxSyncStateStore().clearVaultSyncState(
              openEntry.key.uuid,
            );
          }

          await kdbxBloc.quickUnlockStorage.removeVaultCredential(
            openEntry.key.uuid,
          );
          await KeyNestKeyFileStore.instance.removeReference(openEntry.key.uuid);
          await kdbxBloc.close(openEntry.value.kdbxFile);

          await appDataBloc.update((builder, data) {
            builder.previousFiles.removeWhere(
              (f) =>
                  f.uuid == openEntry.key.uuid ||
                  f.isSameFileAs(openEntry.value.openedFile),
            );
          });
        }

        _selectedIds.remove(vault.id);
        deletedCount++;
      }

      if (mounted) {
        setState(() => _isActionRunning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully deleted $deletedCount vault${deletedCount > 1 ? 's' : ''} from ${widget.provider.displayName}.',
            ),
          ),
        );
        await _fetchCloudVaults();
      }
    } catch (e) {
      _logger.warning('Failed to delete cloud vaults: $e');
      if (mounted) {
        setState(() => _isActionRunning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete vaults: $e'),
            backgroundColor: KeyNestTokens.error,
          ),
        );
      }
    }
  }

  Future<void> _importSelectedToLocal() async {
    final selectedVaults = _vaults
        .where((v) => _selectedIds.contains(v.id))
        .toList();
    if (selectedVaults.isEmpty) {
      return;
    }

    _selectedDestination ??= await _getDefaultDestination();
    KeyNestDirectoryDestination targetDest = _selectedDestination!;

    // Display confirmation dialog with interactive destination selection before operation begins
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final theme = Theme.of(dialogCtx);
        final isDark = theme.brightness == Brightness.dark;

        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
              ),
              title: const Row(
                children: [
                  Icon(Icons.download_rounded, color: KeyNestTokens.primary),
                  SizedBox(width: 8),
                  Text('Import to Local'),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Import ${selectedVaults.length} vault${selectedVaults.length > 1 ? 's' : ''} to local storage? Original cloud vaults will not be modified or deleted.',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? KeyNestTokens.surfaceContainerDark
                            : KeyNestTokens.surfaceLight,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isDark
                              ? KeyNestTokens.borderDark
                              : KeyNestTokens.borderLight,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Destination Directory:',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isDark
                                      ? KeyNestTokens.textSecondaryDark
                                      : KeyNestTokens.textSecondaryLight,
                                ),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  foregroundColor: KeyNestTokens.primary,
                                ),
                                icon: const Icon(
                                  Icons.folder_open_rounded,
                                  size: 15,
                                ),
                                label: const Text(
                                  'Change',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                onPressed: () async {
                                  final picked =
                                      await _pickDestinationDirectory(
                                    parentContext: dialogCtx,
                                  );
                                  if (picked != null) {
                                    setDialogState(() {
                                      targetDest = picked;
                                    });
                                    setState(() {
                                      _selectedDestination = picked;
                                    });
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.folder_rounded,
                                size: 16,
                                color: KeyNestTokens.primary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  targetDest.displayPath,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? KeyNestTokens.textPrimaryDark
                                        : KeyNestTokens.textPrimaryLight,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: selectedVaults
                                .map(
                                  (v) => Chip(
                                    visualDensity: VisualDensity.compact,
                                    label: Text(
                                      '${v.name} (${v.formattedSize})',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KeyNestTokens.primary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(dialogCtx).pop(true),
                  child: const Text('Start Import'),
                ),
              ],
            );
          },
        );
      },
    );

    if (proceed != true) {
      return;
    }

    // Verify writability or resolve SAF permission before starting import
    if (KeyNestPlatform.isAndroid && !targetDest.isSaf) {
      final isWritable =
          KeyNestSafService.isDirectlyWritable(targetDest.displayPath);
      if (!isWritable) {
        final persistedUri = await KeyNestSafService.getPersistedTreeUriForPath(
          targetDest.displayPath,
        );
        if (persistedUri != null) {
          targetDest = KeyNestDirectoryDestination(
            displayPath: targetDest.displayPath,
            treeUri: persistedUri,
            displayName: targetDest.displayName,
          );
          _selectedDestination = targetDest;
        } else {
          // Destination requires user authorization via system document tree picker
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Please authorize access to the destination folder.',
                ),
                duration: Duration(seconds: 2),
              ),
            );
          }
          final authorized = await _pickDestinationDirectory(
            parentContext: context,
          );
          if (authorized == null) {
            return;
          }
          targetDest = authorized;
          _selectedDestination = targetDest;
        }
      }
    }

    if (!targetDest.isSaf) {
      final dir = io.Directory(targetDest.displayPath);
      if (!dir.existsSync()) {
        try {
          dir.createSync(recursive: true);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Destination directory is inaccessible: $e'),
                backgroundColor: KeyNestTokens.error,
              ),
            );
          }
          return;
        }
      }
    }

    setState(() => _isActionRunning = true);

    try {
      int importedCount = 0;

      for (final vault in selectedVaults) {
        Uint8List bytes;
        if (widget.provider is GoogleDriveProvider) {
          final google = widget.provider as GoogleDriveProvider;
          bytes = await google.driveClient.downloadFile(vault.id);
        } else {
          final dropbox = widget.provider as DropboxProvider;
          final res = await dropbox.dropboxClient.downloadVault(vault.name);
          bytes = res.bytes;
        }

        if (!KeyNestCloudVaultBrowserScreen.isValidKdbxBytes(bytes)) {
          throw FormatException(
            'The downloaded file "${vault.name}" is not a valid encrypted KDBX vault.',
          );
        }

        var finalFileName = vault.name;
        bool shouldOverwrite = false;

        final exists = await KeyNestSafService.checkFileExists(
          destination: targetDest,
          fileName: finalFileName,
        );

        if (exists) {
          final choice = await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('File Already Exists'),
              content: Text(
                'A local vault named "$finalFileName" already exists in "${targetDest.displayName ?? p.basename(targetDest.displayPath)}". '
                'Would you like to overwrite it or save with a new name?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('cancel'),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('rename'),
                  child: const Text('Keep Both (Rename)'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KeyNestTokens.error,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(ctx).pop('overwrite'),
                  child: const Text('Overwrite'),
                ),
              ],
            ),
          );

          if (choice == 'cancel' || choice == null) {
            continue;
          } else if (choice == 'rename') {
            final base = p.basenameWithoutExtension(vault.name);
            final ext = p.extension(vault.name);
            final timestamp = DateFormat(
              'yyyyMMdd_HHmmss',
            ).format(DateTime.now());
            finalFileName = '$base-$timestamp$ext';
            shouldOverwrite = false;
          } else if (choice == 'overwrite') {
            shouldOverwrite = true;
          }
        }

        final writtenIdentifierOrPath = await KeyNestSafService.writeVaultFile(
          destination: targetDest,
          fileName: finalFileName,
          bytes: bytes,
          overwrite: shouldOverwrite,
        );

        importedCount++;

        // Prompt to unlock the newly imported local file
        final FileSourceLocal localSource;
        if (targetDest.isSaf) {
          localSource = FileSourceLocal(
            FileSourceLocal.localFile(finalFileName),
            uuid: const Uuid().v4(),
            databaseName: p.basenameWithoutExtension(finalFileName),
            filePickerIdentifier: FileInfo(
              identifier: writtenIdentifierOrPath,
              persistable: true,
              uri: writtenIdentifierOrPath,
              fileName: finalFileName,
            ).toJsonString(),
          );
        } else {
          localSource = FileSourceLocal(
            FileSourceLocal.localFile(writtenIdentifierOrPath),
            uuid: const Uuid().v4(),
            databaseName: p.basenameWithoutExtension(finalFileName),
          );
        }

        try {
          final appDataBloc = context.read<AppDataBloc>();
          await appDataBloc.openedFile(
            localSource,
            name: p.basenameWithoutExtension(finalFileName),
          );
        } catch (e) {
          _logger.fine('Could not pre-register opened file in appDataBloc: $e');
        }

        if (mounted) {
          await Navigator.of(context).push(
            CredentialsScreen.route(localSource),
          );
        }
      }

      if (mounted) {
        setState(() => _isActionRunning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Imported $importedCount vault${importedCount > 1 ? 's' : ''} to ${targetDest.displayName ?? p.basename(targetDest.displayPath)}.',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
        await _fetchCloudVaults();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isActionRunning = false);
        final errorText = e is io.FileSystemException
            ? (e.osError != null ? '${e.message} (${e.osError})' : e.message)
            : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to import vault: $errorText'),
            backgroundColor: KeyNestTokens.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final Color brandColor;
    if (widget.provider is GoogleDriveProvider) {
      brandColor = const Color(0xFF1EA362);
    } else if (widget.provider is DropboxProvider) {
      brandColor = const Color(0xFF0061FF);
    } else {
      brandColor = isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary;
    }

    final hasSelection = _selectedIds.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text('Browse ${widget.provider.displayName}'),
        actions: [
          if (hasSelection)
            IconButton(
              tooltip: 'Delete Selected from Cloud',
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: KeyNestTokens.error,
              ),
              onPressed: _isActionRunning ? null : _confirmAndDeleteSelectedVaults,
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _isLoading ? null : _fetchCloudVaults,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Explanatory Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  decoration: BoxDecoration(
                    color: brandColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(
                      KeyNestTokens.radiusCard,
                    ),
                    border: Border.all(
                      color: brandColor.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 18,
                            color: brandColor,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Vault Storage & Portability',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: brandColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '• Open from Cloud: Opens the vault directly from ${widget.provider.displayName}. Changes synchronize automatically.\n'
                        '• Import Local Copy: Downloads an independent, encrypted .kdbx copy to your device storage.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11.5,
                          height: 1.4,
                          color: isDark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                        ),
                      ),
                    ],
                  ),
                ),

                if (_errorMessage != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: KeyNestTokens.error.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: KeyNestTokens.error.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: KeyNestTokens.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Selection Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Available Vaults (${_vaults.length})',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_vaults.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            setState(() {
                              if (_selectedIds.length == _vaults.length) {
                                _selectedIds.clear();
                              } else {
                                _selectedIds.addAll(_vaults.map((v) => v.id));
                              }
                            });
                          },
                          child: Text(
                            _selectedIds.length == _vaults.length
                                ? 'Deselect All'
                                : 'Select All',
                            style: TextStyle(fontSize: 12, color: brandColor),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 6),

                // Vault List
                Expanded(
                  child: _vaults.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.folder_open_rounded,
                                size: 48,
                                color: isDark ? Colors.white38 : Colors.black26,
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'No .kdbx vault files found',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Create or upload vaults into the "KeyNest" folder in ${widget.provider.displayName}.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          itemCount: _vaults.length,
                          separatorBuilder: (_, i) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final vault = _vaults[index];
                            final isChecked = _selectedIds.contains(vault.id);
                            final successColor = isDark
                                ? KeyNestTokens.darkSuccess
                                : KeyNestTokens.lightSuccess;

                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? KeyNestPalette.cardDark
                                    : KeyNestPalette.cardLight,
                                borderRadius: BorderRadius.circular(
                                  KeyNestTokens.radiusCard,
                                ),
                                border: Border.all(
                                  color: isChecked
                                      ? brandColor.withValues(alpha: 0.4)
                                      : (isDark
                                            ? Colors.white12
                                            : Colors.black12),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Checkbox(
                                    activeColor: brandColor,
                                    value: isChecked,
                                    onChanged: (val) {
                                      setState(() {
                                        if (val == true) {
                                          _selectedIds.add(vault.id);
                                        } else {
                                          _selectedIds.remove(vault.id);
                                        }
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              vault.name,
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                            ),
                                            if (vault.isLinked) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: successColor
                                                      .withValues(alpha: 0.12),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  'Linked / Open',
                                                  style: TextStyle(
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                    color: successColor,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Size: ${vault.formattedSize}${vault.modifiedTime != null ? ' • Modified: ${DateFormat('MMM d, yyyy h:mm a').format(vault.modifiedTime!)}' : ''}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                fontSize: 11,
                                                color: isDark
                                                    ? KeyNestPalette
                                                          .textSecondaryDark
                                                    : KeyNestPalette
                                                          .textSecondaryLight,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete from Cloud',
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 20,
                                      color: KeyNestTokens.error,
                                    ),
                                    onPressed: _isActionRunning
                                        ? null
                                        : () => _confirmAndDeleteCloudVault(
                                              vault,
                                            ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),

                // Bottom Action Bar
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDark
                        ? KeyNestPalette.cardDark
                        : KeyNestPalette.cardLight,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        offset: const Offset(0, -2),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.download_rounded, size: 16),
                          label: const Text(
                            'Import to Local',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: brandColor,
                            side: BorderSide(color: brandColor),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: hasSelection && !_isActionRunning
                              ? _importSelectedToLocal
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: _isActionRunning
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.lock_open_rounded, size: 16),
                          label: const Text(
                            'Open in KeyNest',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: brandColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: hasSelection && !_isActionRunning
                              ? _openSelectedInKeyNest
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
