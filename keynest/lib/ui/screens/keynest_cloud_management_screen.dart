// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:keynest/bloc/kdbx/file_source_ui.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_provider.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/cloud_storage/keynest_cloud_sync_manager.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/keynest_cloud_vault_browser_screen.dart';
import 'package:provider/provider.dart';

class KeyNestCloudManagementScreen extends StatefulWidget {
  const KeyNestCloudManagementScreen({
    super.key,
    required this.provider,
  });

  final CloudStorageProvider provider;

  static Route<void> route(CloudStorageProvider provider) {
    return MaterialPageRoute<void>(
      settings: RouteSettings(name: '/cloud/manage/${provider.id}'),
      builder: (_) => KeyNestCloudManagementScreen(provider: provider),
    );
  }

  @override
  State<KeyNestCloudManagementScreen> createState() =>
      _KeyNestCloudManagementScreenState();
}

class _KeyNestCloudManagementScreenState
    extends State<KeyNestCloudManagementScreen> {
  final KeyNestCloudSyncManager _syncManager = KeyNestCloudSyncManager.instance;
  bool _isSyncing = false;
  String? _syncSummaryMessage;

  @override
  void initState() {
    super.initState();
    _syncManager.load().then((_) {
      if (mounted) {
        setState(() {});
      }
    });
    if (!widget.provider.isAuthenticated) {
      widget.provider.loadSavedAuth().then((_) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  String? get _accountEmail {
    if (widget.provider is GoogleDriveProvider) {
      return (widget.provider as GoogleDriveProvider).connectedAccountEmail;
    } else if (widget.provider is DropboxProvider) {
      return (widget.provider as DropboxProvider).connectedAccountEmail;
    }
    return null;
  }

  String? get _displayName {
    if (widget.provider is GoogleDriveProvider) {
      return (widget.provider as GoogleDriveProvider).connectedDisplayName;
    } else if (widget.provider is DropboxProvider) {
      return (widget.provider as DropboxProvider).connectedDisplayName;
    }
    return null;
  }

  Future<void> _handleSyncSelected() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFiles.entries.toList();

    if (openedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No vaults currently open to synchronize.'),
        ),
      );
      return;
    }

    setState(() {
      _isSyncing = true;
      _syncSummaryMessage = null;
    });

    try {
      final results = await _syncManager.syncSelectedVaults(
        provider: widget.provider,
        openedFiles: openedFiles,
        kdbxBloc: kdbxBloc,
      );

      final successCount = results.where((r) => r.isSuccess).length;
      final failCount = results.length - successCount;

      if (mounted) {
        setState(() {
          _isSyncing = false;
          if (results.isEmpty) {
            _syncSummaryMessage =
                'No vaults were checked for sync. Check at least one vault below.';
          } else if (failCount == 0) {
            _syncSummaryMessage =
                'Successfully synchronized $successCount vault${successCount > 1 ? 's' : ''}.';
          } else {
            _syncSummaryMessage =
                'Sync completed: $successCount succeeded, $failCount encountered errors.';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncSummaryMessage = 'Sync failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFiles.entries.toList();

    final Color brandColor;
    if (widget.provider is GoogleDriveProvider) {
      brandColor = const Color(0xFF1EA362);
    } else if (widget.provider is DropboxProvider) {
      brandColor = const Color(0xFF0061FF);
    } else {
      brandColor = isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary;
    }

    final email = _accountEmail;
    final displayName = _displayName;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.provider.displayName} Sync'),
        actions: [
          IconButton(
            tooltip: 'Browse Cloud Vaults',
            icon: const Icon(Icons.cloud_download_outlined),
            onPressed: () {
              Navigator.of(context).push(
                KeyNestCloudVaultBrowserScreen.route(widget.provider),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _syncManager,
        builder: (context, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Provider Status Card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDark
                        ? KeyNestPalette.cardDark
                        : KeyNestPalette.cardLight,
                    borderRadius: BorderRadius.circular(
                      KeyNestTokens.radiusCard,
                    ),
                    border: Border.all(
                      color: isDark ? Colors.white12 : Colors.black12,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: brandColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: widget.provider.displayIcon.iconData.widget(
                              color: brandColor,
                              size: 24,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    Text(
                                      widget.provider.displayName,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: (isDark
                                                ? KeyNestPalette.successDark
                                                : KeyNestPalette.success)
                                            .withValues(
                                              alpha: isDark ? 0.22 : 0.15,
                                            ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'Connected',
                                        style: TextStyle(
                                          color: isDark
                                              ? KeyNestPalette.successDark
                                              : KeyNestPalette.success,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (email != null && email.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    displayName != null &&
                                            displayName.isNotEmpty
                                        ? '$displayName ($email)'
                                        : email,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: isDark
                                          ? KeyNestPalette.textSecondaryDark
                                          : KeyNestPalette.textSecondaryLight,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.folder_outlined,
                                      size: 14,
                                      color: Colors.grey,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Folder: KeyNest',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isDark
                                            ? Colors.white70
                                            : Colors.black87,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(
                              Icons.cloud_download_rounded,
                              size: 16,
                            ),
                            label: const Text(
                              'Browse Cloud Vaults',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: brandColor,
                              side: BorderSide(color: brandColor),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: () {
                              Navigator.of(context).push(
                                KeyNestCloudVaultBrowserScreen.route(
                                  widget.provider,
                                ),
                              );
                            },
                          ),
                          TextButton.icon(
                            icon: const Icon(
                              Icons.link_off_rounded,
                              size: 16,
                              color: KeyNestTokens.error,
                            ),
                            label: const Text(
                              'Disconnect',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: KeyNestTokens.error,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Disconnect Account?'),
                                  content: Text(
                                    'Are you sure you want to disconnect ${widget.provider.displayName}? '
                                    'Your local vaults will remain completely intact.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: KeyNestTokens.error,
                                        foregroundColor: Colors.white,
                                      ),
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(true),
                                      child: const Text('Disconnect'),
                                    ),
                                  ],
                                ),
                              );

                              if (confirm == true && mounted) {
                                await widget.provider.logout();
                                if (mounted) {
                                  Navigator.of(context).pop();
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Per-vault sync section header - responsive adaptive layout prevents overflow
                LayoutBuilder(
                  builder: (context, constraints) {
                    final syncBtn = ElevatedButton.icon(
                      icon: _isSyncing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.sync_rounded, size: 16),
                      label: Text(
                        _isSyncing ? 'Syncing...' : 'Sync Selected Vaults',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: brandColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: _isSyncing ? null : _handleSyncSelected,
                    );

                    if (constraints.maxWidth < 460) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Per-Vault Synchronization',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Select the vaults you want to synchronize with your ${widget.provider.displayName} account. Unchecked vaults will never be uploaded.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: syncBtn,
                          ),
                        ],
                      );
                    } else {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Per-Vault Synchronization',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              syncBtn,
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Select the vaults you want to synchronize with your ${widget.provider.displayName} account. Unchecked vaults will never be uploaded.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                        ],
                      );
                    }
                  },
                ),
                const SizedBox(height: 14),

                // Summary message banner if present
                if (_syncSummaryMessage != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color:
                          _syncSummaryMessage!.contains('fail') ||
                              _syncSummaryMessage!.contains('error')
                          ? KeyNestTokens.error.withValues(alpha: 0.12)
                          : (isDark
                                    ? KeyNestPalette.successDark
                                    : KeyNestPalette.success)
                                .withValues(alpha: isDark ? 0.20 : 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color:
                            _syncSummaryMessage!.contains('fail') ||
                                _syncSummaryMessage!.contains('error')
                            ? KeyNestTokens.error.withValues(alpha: 0.3)
                            : (isDark
                                    ? KeyNestPalette.successDark
                                    : KeyNestPalette.success)
                                .withValues(alpha: isDark ? 0.4 : 0.3),
                      ),
                    ),
                    child: Text(
                      _syncSummaryMessage!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color:
                            _syncSummaryMessage!.contains('fail') ||
                                _syncSummaryMessage!.contains('error')
                            ? KeyNestTokens.error
                            : (isDark
                                  ? KeyNestPalette.successDark
                                  : KeyNestPalette.success),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // Vault checklist
                if (openedFiles.isEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: isDark
                          ? KeyNestPalette.surfaceDark
                          : KeyNestPalette.surfaceLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.lock_clock_outlined,
                          size: 40,
                          color: isDark ? Colors.white38 : Colors.black26,
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'No vaults are currently open.',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Open or import a vault in KeyNest to configure its cloud synchronization.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: openedFiles.length,
                    separatorBuilder: (_, i) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final entry = openedFiles[index];
                      final source = entry.key;
                      final isNativeCloud =
                          source is FileSourceCloudStorage &&
                          source.provider.id == widget.provider.id;
                      final isSelected = _syncManager.isVaultSyncEnabled(
                        widget.provider.id,
                        source.uuid,
                        isNativeCloudVault: isNativeCloud,
                      );
                      final syncInfo = _syncManager.getVaultSyncInfo(
                        widget.provider.id,
                        source.uuid,
                      );

                      return _buildVaultRow(
                        context: context,
                        source: source,
                        openedFile: entry.value,
                        isSelected: isSelected,
                        syncInfo: syncInfo,
                        brandColor: brandColor,
                        isDark: isDark,
                      );
                    },
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildVaultRow({
    required BuildContext context,
    required FileSource source,
    required KdbxOpenedFile openedFile,
    required bool isSelected,
    required VaultSyncInfo syncInfo,
    required Color brandColor,
    required bool isDark,
  }) {
    final theme = Theme.of(context);
    final isNativeCloud =
        source is FileSourceCloudStorage &&
        source.provider.id == widget.provider.id;

    Widget statusBadge;
    switch (syncInfo.status) {
      case KeyNestSyncStatus.syncing:
        statusBadge = const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            SizedBox(width: 4),
            Text(
              'Syncing...',
              style: TextStyle(fontSize: 11, color: Colors.blue),
            ),
          ],
        );
        break;
      case KeyNestSyncStatus.success:
        statusBadge = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_rounded,
              size: 13,
              color: isDark
                  ? KeyNestPalette.successDark
                  : KeyNestPalette.success,
            ),
            const SizedBox(width: 4),
            Text(
              syncInfo.lastSyncTime != null
                  ? 'Synced ${DateFormat('MMM d, h:mm a').format(syncInfo.lastSyncTime!)}'
                  : 'Synced',
              style: TextStyle(
                fontSize: 11,
                color: isDark
                    ? KeyNestPalette.successDark
                    : KeyNestPalette.success,
              ),
            ),
          ],
        );
        break;
      case KeyNestSyncStatus.conflict:
        statusBadge = const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 13, color: Colors.orange),
            SizedBox(width: 4),
            Text(
              'Conflict',
              style: TextStyle(fontSize: 11, color: Colors.orange),
            ),
          ],
        );
        break;
      case KeyNestSyncStatus.error:
        statusBadge = const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 13,
              color: KeyNestTokens.error,
            ),
            SizedBox(width: 4),
            Text(
              'Sync failed',
              style: TextStyle(fontSize: 11, color: KeyNestTokens.error),
            ),
          ],
        );
        break;
      default:
        statusBadge = Text(
          isSelected ? 'Configured to sync' : 'Sync disabled',
          style: TextStyle(
            fontSize: 11,
            color: isSelected
                ? (isDark ? Colors.white70 : Colors.black54)
                : Colors.grey,
          ),
        );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? KeyNestPalette.cardDark : KeyNestPalette.cardLight,
        borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
        border: Border.all(
          color: isSelected
              ? brandColor.withValues(alpha: 0.3)
              : (isDark ? Colors.white12 : Colors.black12),
        ),
      ),
      child: Row(
        children: [
          Checkbox(
            activeColor: brandColor,
            value: isSelected,
            onChanged: (val) {
              _syncManager.setVaultSyncEnabled(
                widget.provider.id,
                source.uuid,
                val == true,
              );
            },
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        source.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (isNativeCloud) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: brandColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Cloud Vault',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: brandColor,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                statusBadge,
              ],
            ),
          ),
          IconButton(
            tooltip: 'Sync this vault now',
            icon: const Icon(Icons.sync_rounded, size: 20),
            onPressed: isSelected && !_isSyncing
                ? () async {
                    final kdbxBloc = context.read<KdbxBloc>();
                    final res = await _syncManager.syncVault(
                      provider: widget.provider,
                      source: source,
                      openedFile: openedFile,
                      kdbxBloc: kdbxBloc,
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(res.message ?? 'Synchronized.'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  }
                : null,
          ),
        ],
      ),
    );
  }
}
