// ignore_for_file: use_build_context_synchronously, always_put_control_body_on_new_line, unawaited_futures
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_state.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_engine.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';
import 'package:keynest/cloud_storage/keynest_cloud_sync_manager.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/key_file_store.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/locked_screen.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/ui/widgets/keynest_key_file_creation_section.dart';
import 'package:keynest/ui/widgets/keynest_popup_menu.dart';
import 'package:keynest/ui/widgets/password_input_field.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

final _logger = Logger('keynest_vault_manager');

/// Dedicated screen for managing multiple KDBX vaults and their native folder hierarchies.
class KeyNestVaultManagerScreen extends StatefulWidget {
  const KeyNestVaultManagerScreen({super.key});

  static Route<KdbxGroup?> route() {
    if (KeyNestPlatform.isDesktopOrWeb) {
      return KeyNestDesktopDialogRoute<KdbxGroup?>(
        settings: const RouteSettings(name: '/vault_manager'),
        maxWidth: 540,
        maxHeight: 620,
        builder: (_) => const KeyNestVaultManagerScreen(),
      );
    }
    return KeyNestPageRoute<KdbxGroup?>(
      settings: const RouteSettings(name: '/vault_manager'),
      builder: (_) => const KeyNestVaultManagerScreen(),
    );
  }

  @override
  State<KeyNestVaultManagerScreen> createState() =>
      _KeyNestVaultManagerScreenState();
}

class _KeyNestVaultManagerScreenState extends State<KeyNestVaultManagerScreen> {
  final Set<String> _collapsedVaults = {};
  final Set<String> _collapsedFolders = {};
  bool _isProcessing = false;

  String _getStorageBadge(FileSource source) {
    if (source is FileSourceLocal) {
      return source.filePickerIdentifier != null ? 'SAF' : 'LOCAL';
    }
    if (source is FileSourceCloudStorage) {
      return source.provider.displayName.toUpperCase();
    }
    return 'VAULT';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFiles.entries.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vaults & Folders'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync_rounded),
            tooltip: 'Sync All Vaults',
            onPressed: openedFiles.isEmpty || _isProcessing
                ? null
                : () => _syncAllVaults(context, kdbxBloc),
          ),
          IconButton(
            icon: const Icon(Icons.add_box_outlined),
            tooltip: 'Add / Open Vault',
            onPressed: _isProcessing ? null : () => _showAddVaultSheet(context),
          ),
          if (KeyNestPlatform.isDesktopOrWeb)
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
        ],
      ),
      body: _isProcessing
          ? Center(
              child: CircularProgressIndicator(
                color: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
              ),
            )
          : openedFiles.isEmpty
          ? _buildEmptyState(context, isDark)
          : ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              children: [
                _buildTopActionsBar(context, isDark, kdbxBloc),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Text(
                        'OPENED VAULTS (${openedFiles.length})',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
                          color: isDark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        ),
                        icon: const Icon(Icons.visibility_rounded, size: 16),
                        label: const Text('Show All Entries'),
                        onPressed: () {
                          KeyNestVaultScope.instance.setSelectedVault(
                            kdbxBloc,
                            null,
                          );
                          KeyNestVaultScope.instance.setActiveTab(0);
                          Navigator.of(context).pop(null);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ...openedFiles.map((fileEntry) {
                  return _buildVaultCard(
                    context: context,
                    isDark: isDark,
                    fileEntry: fileEntry,
                    kdbxBloc: kdbxBloc,
                    totalVaultsCount: openedFiles.length,
                  );
                }),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _buildTopActionsBar(
    BuildContext context,
    bool isDark,
    KdbxBloc kdbxBloc,
  ) {
    return Row(
      children: [
        Expanded(
          child: KeyNestPressScale(
            onTap: () => _showCreateVaultDialog(context, kdbxBloc),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
              decoration: BoxDecoration(
                color: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestTokens.primary,
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
                boxShadow: [
                  BoxShadow(
                    color:
                        (isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestTokens.primary)
                            .withValues(alpha: 0.28),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.create_new_folder_rounded,
                    size: 18,
                    color: isDark ? const Color(0xFF00315D) : Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'New Vault',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: isDark ? const Color(0xFF00315D) : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: KeyNestPressScale(
            onTap: () => _openExistingVault(context),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
              decoration: BoxDecoration(
                color: isDark
                    ? KeyNestTokens.surfaceContainerDark
                    : KeyNestTokens.surfaceLight,
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
                border: Border.all(
                  color: isDark
                      ? KeyNestTokens.borderDark
                      : KeyNestTokens.borderLight,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.folder_open_rounded,
                    size: 18,
                    color: isDark
                        ? KeyNestTokens.textPrimaryDark
                        : KeyNestTokens.textPrimaryLight,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Open Vault',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: isDark
                          ? KeyNestTokens.textPrimaryDark
                          : KeyNestTokens.textPrimaryLight,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: KeyNestSurfaceCard(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestTokens.primary)
                          .withValues(alpha: isDark ? 0.20 : 0.12),
                  border: Border.all(
                    color:
                        (isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestTokens.primary)
                            .withValues(alpha: 0.25),
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.folder_off_rounded,
                    size: 40,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestTokens.primary,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'No Vaults Opened',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? KeyNestTokens.textPrimaryDark
                      : KeyNestTokens.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Open an existing .kdbx database or create a new encrypted vault to securely store your passwords and records.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? KeyNestTokens.textSecondaryDark
                      : KeyNestTokens.textSecondaryLight,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  KeyNestPressScale(
                    onTap: () => _showCreateVaultDialog(
                      context,
                      context.read<KdbxBloc>(),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestTokens.primary,
                        borderRadius: BorderRadius.circular(
                          KeyNestTokens.radiusCard,
                        ),
                      ),
                      child: Text(
                        'Create Vault',
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFF00315D)
                              : Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  KeyNestPressScale(
                    onTap: () => _openExistingVault(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? KeyNestTokens.surfaceContainerDark
                            : KeyNestTokens.surfaceLight,
                        borderRadius: BorderRadius.circular(
                          KeyNestTokens.radiusCard,
                        ),
                        border: Border.all(
                          color: isDark
                              ? KeyNestTokens.borderDark
                              : KeyNestTokens.borderLight,
                        ),
                      ),
                      child: Text(
                        'Open Vault',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? KeyNestTokens.textPrimaryDark
                              : KeyNestTokens.textPrimaryLight,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVaultCard({
    required BuildContext context,
    required bool isDark,
    required MapEntry<FileSource, KdbxOpenedFile> fileEntry,
    required KdbxBloc kdbxBloc,
    required int totalVaultsCount,
  }) {
    final theme = Theme.of(context);
    final fileSource = fileEntry.key;
    final openedFile = fileEntry.value;
    final kdbxFile = openedFile.kdbxFile;
    final rootGroup = kdbxFile.body.rootGroup;

    final vaultName = KeyNestVaultScope.cleanVaultName(kdbxBloc, kdbxFile);

    final isCollapsed = _collapsedVaults.contains(fileSource.uuid);
    final totalEntries = rootGroup
        .getAllEntries()
        .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
        .length;
    final allGroups = rootGroup
        .getAllGroups()
        .where(
          (g) =>
              g != rootGroup && !KeyNestItemTypeHelper.isTrashOrRecycleBin(g),
        )
        .length;

    final vaultColor = openedFile.openedFile.color ?? KeyNestTokens.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: KeyNestSurfaceCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
              onTap: () {
                setState(() {
                  if (isCollapsed) {
                    _collapsedVaults.remove(fileSource.uuid);
                  } else {
                    _collapsedVaults.add(fileSource.uuid);
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 14,
                  top: 10,
                  bottom: 10,
                  right: 8,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: KeyNestCompactIconTile(
                        icon: Icons.security_rounded,
                        tint: vaultColor,
                        size: 42,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            vaultName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            softWrap: true,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            fileSource.friendlyLocation,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? KeyNestTokens.textSecondaryDark
                                      .withValues(alpha: 0.75)
                                  : KeyNestTokens.textSecondaryLight
                                      .withValues(alpha: 0.75),
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                            softWrap: true,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$totalEntries items • $allGroups folders',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? KeyNestTokens.textSecondaryDark
                                  : KeyNestTokens.textSecondaryLight,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: KeyNestStatusBadge.compact(
                            label: _getStorageBadge(fileSource),
                            tone: KeyNestSemanticTone.primary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.all(4),
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              icon: Icon(
                                isCollapsed
                                    ? Icons.expand_more_rounded
                                    : Icons.expand_less_rounded,
                                color: isDark
                                    ? KeyNestTokens.textSecondaryDark
                                    : KeyNestTokens.textSecondaryLight,
                                size: 22,
                              ),
                              onPressed: () {
                                setState(() {
                                  if (isCollapsed) {
                                    _collapsedVaults.remove(fileSource.uuid);
                                  } else {
                                    _collapsedVaults.add(fileSource.uuid);
                                  }
                                });
                              },
                            ),
                            KeyNestPopupMenuButton<_VaultAction>(
                              icon: const Icon(Icons.more_vert_rounded, size: 18),
                              padding: EdgeInsets.zero,
                              tooltip: 'Vault options',
                              onSelected: (action) => _handleVaultAction(
                                context,
                                action,
                                fileEntry,
                                kdbxBloc,
                                totalVaultsCount,
                              ),
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: _VaultAction.addRootFolder,
                                  child: ListTile(
                                    dense: true,
                                    leading: Icon(Icons.create_new_folder_outlined),
                                    title: Text('Add Root Folder'),
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: _VaultAction.syncVault,
                                  child: ListTile(
                                    dense: true,
                                    leading: Icon(Icons.sync_rounded),
                                    title: Text('Sync Vault'),
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: _VaultAction.filterEntries,
                                  child: ListTile(
                                    dense: true,
                                    leading: Icon(Icons.filter_list_rounded),
                                    title: Text('Filter View to This Vault'),
                                  ),
                                ),
                                if (fileSource is FileSourceLocal)
                                  const PopupMenuItem(
                                    value: _VaultAction.moveVault,
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(Icons.drive_file_move_outlined),
                                      title: Text('Move Vault'),
                                    ),
                                  ),
                                const PopupMenuDivider(),
                                const PopupMenuItem(
                                  value: _VaultAction.closeVault,
                                  child: ListTile(
                                    dense: true,
                                    leading: Icon(
                                      Icons.lock_outline_rounded,
                                      color: KeyNestTokens.textSecondaryLight,
                                    ),
                                    title: Text('Close / Lock Vault'),
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: _VaultAction.disconnectVault,
                                  child: ListTile(
                                    dense: true,
                                    leading: Icon(
                                      Icons.link_off_rounded,
                                      color: KeyNestTokens.error,
                                    ),
                                    title: Text(
                                      'Disconnect / Remove Vault',
                                      style: TextStyle(color: KeyNestTokens.error),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Collapsible Folder Hierarchy
            if (!isCollapsed) ...[
              Divider(
                height: 1,
                color: isDark
                    ? KeyNestTokens.borderDark
                    : KeyNestTokens.borderLight,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_special_rounded,
                      size: 16,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestTokens.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Folder Hierarchy',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? KeyNestTokens.textSecondaryDark
                            : KeyNestTokens.textSecondaryLight,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestTokens.primary,
                      ),
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text(
                        'Folder',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () => _promptCreateSubfolder(
                        context,
                        kdbxFile,
                        rootGroup,
                        kdbxBloc,
                      ),
                    ),
                  ],
                ),
              ),
              if (rootGroup.groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: 14,
                  ),
                  child: Text(
                    'No subfolders. All entries are in root.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isDark
                          ? KeyNestTokens.textSecondaryDark
                          : KeyNestTokens.textSecondaryLight,
                    ),
                  ),
                )
              else
                ...KeyNestItemTypeHelper.sortGroupsWithTrashLast(
                  rootGroup.groups,
                ).map(
                  (group) => _buildGroupNode(
                    context: context,
                    isDark: isDark,
                    group: group,
                    kdbxFile: kdbxFile,
                    kdbxBloc: kdbxBloc,
                    depth: 0,
                  ),
                ),
              const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGroupNode({
    required BuildContext context,
    required bool isDark,
    required KdbxGroup group,
    required KdbxFile kdbxFile,
    required KdbxBloc kdbxBloc,
    required int depth,
  }) {
    final theme = Theme.of(context);
    final groupUuid = group.uuid.uuid;
    final isFolderCollapsed = _collapsedFolders.contains(groupUuid);
    final hasSubgroups = group.groups.isNotEmpty;
    final isRecycleBin = kdbxFile.recycleBin == group;
    final isInsideTrash = !isRecycleBin && group.isInRecycleBin();
    final groupName = group.name.get() ?? 'Folder';
    final entriesCount = group.entries.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () {
            KeyNestVaultScope.instance.setSelectedVaultAndFolder(
              kdbxBloc,
              kdbxFile,
              group,
              targetTab: 0,
            );
            Navigator.of(context).pop(group);
          },
          child: Padding(
            padding: EdgeInsets.only(
              left: 16.0 + (depth * 20.0),
              right: 8.0,
              top: 4.0,
              bottom: 4.0,
            ),
            child: Row(
              children: [
                if (hasSubgroups)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        if (isFolderCollapsed) {
                          _collapsedFolders.remove(groupUuid);
                        } else {
                          _collapsedFolders.add(groupUuid);
                        }
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(
                        right: 6,
                        left: 2,
                        top: 2,
                        bottom: 2,
                      ),
                      child: Icon(
                        isFolderCollapsed
                            ? Icons.chevron_right_rounded
                            : Icons.expand_more_rounded,
                        size: 20,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 24),
                Icon(
                  isRecycleBin
                      ? Icons.delete_outline_rounded
                      : hasSubgroups && !isFolderCollapsed
                      ? Icons.folder_open_rounded
                      : Icons.folder_rounded,
                  size: 20,
                  color: isRecycleBin
                      ? KeyNestPalette.error
                      : (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    groupName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (entriesCount > 0)
                  Container(
                    margin: const EdgeInsets.only(right: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? KeyNestPalette.surfaceContainerDark
                          : KeyNestPalette.surfaceContainerLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$entriesCount',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                    ),
                  ),
                KeyNestPopupMenuButton<_FolderAction>(
                  icon: const Icon(Icons.more_vert_rounded, size: 18),
                  padding: EdgeInsets.zero,
                  onSelected: (action) => _handleFolderAction(
                    context,
                    action,
                    group,
                    kdbxFile,
                    kdbxBloc,
                  ),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: _FolderAction.viewEntries,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.filter_list_rounded),
                        title: Text('View Entries'),
                      ),
                    ),
                    if (isInsideTrash) ...[
                      const PopupMenuItem(
                        value: _FolderAction.restore,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.restore_from_trash_rounded),
                          title: Text('Restore Folder'),
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: _FolderAction.deletePermanently,
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.delete_forever_rounded,
                            color: KeyNestPalette.error,
                          ),
                          title: Text(
                            'Permanently Delete',
                            style: TextStyle(color: KeyNestPalette.error),
                          ),
                        ),
                      ),
                    ] else if (!isRecycleBin) ...[
                      const PopupMenuItem(
                        value: _FolderAction.addSubfolder,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.create_new_folder_outlined),
                          title: Text('Add Subfolder'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: _FolderAction.rename,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Rename'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: _FolderAction.moveFolder,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.drive_file_move_outlined),
                          title: Text('Move Folder'),
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: _FolderAction.delete,
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.delete_outline,
                            color: KeyNestPalette.error,
                          ),
                          title: Text(
                            'Delete Folder',
                            style: TextStyle(color: KeyNestPalette.error),
                          ),
                        ),
                      ),
                    ] else if (isRecycleBin &&
                        (group.entries.isNotEmpty ||
                            group.groups.isNotEmpty)) ...[
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: _FolderAction.emptyTrash,
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.delete_sweep_rounded,
                            color: KeyNestPalette.error,
                          ),
                          title: Text(
                            'Empty Trash',
                            style: TextStyle(color: KeyNestPalette.error),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        if (hasSubgroups && !isFolderCollapsed)
          ...KeyNestItemTypeHelper.sortGroupsWithTrashLast(group.groups).map(
            (child) => _buildGroupNode(
              context: context,
              isDark: isDark,
              group: child,
              kdbxFile: kdbxFile,
              kdbxBloc: kdbxBloc,
              depth: depth + 1,
            ),
          ),
      ],
    );
  }

  // Vault Actions
  Future<void> _handleVaultAction(
    BuildContext context,
    _VaultAction action,
    MapEntry<FileSource, KdbxOpenedFile> fileEntry,
    KdbxBloc kdbxBloc,
    int totalVaultsCount,
  ) async {
    final kdbxFile = fileEntry.value.kdbxFile;
    switch (action) {
      case _VaultAction.addRootFolder:
        await _promptCreateSubfolder(
          context,
          kdbxFile,
          kdbxFile.body.rootGroup,
          kdbxBloc,
        );
        break;
      case _VaultAction.syncVault:
        await _syncSingleVault(context, fileEntry, kdbxBloc);
        break;
      case _VaultAction.filterEntries:
        KeyNestVaultScope.instance.setSelectedVaultAndFolder(
          kdbxBloc,
          kdbxFile,
          kdbxFile.body.rootGroup,
          targetTab: 0,
        );
        Navigator.of(context).pop(kdbxFile.body.rootGroup);
        break;
      case _VaultAction.moveVault:
        await _handleMoveVault(context, fileEntry, kdbxBloc);
        break;
      case _VaultAction.closeVault:
        await _closeVaultWithConfirmation(
          context,
          fileEntry,
          kdbxBloc,
          totalVaultsCount,
        );
        break;
      case _VaultAction.disconnectVault:
        await _disconnectVaultWithConfirmation(
          context,
          fileEntry,
          kdbxBloc,
          totalVaultsCount,
        );
        break;
    }
  }

  Future<void> _handleMoveVault(
    BuildContext context,
    MapEntry<FileSource, KdbxOpenedFile> fileEntry,
    KdbxBloc kdbxBloc,
  ) async {
    final fileSource = fileEntry.key;
    if (fileSource is! FileSourceLocal) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only local vaults can be moved to another location.'),
        ),
      );
      return;
    }

    final openedFile = fileEntry.value;
    final kdbxFile = openedFile.kdbxFile;
    final vaultName = KeyNestVaultScope.cleanVaultName(kdbxBloc, kdbxFile);
    final currentFriendly = fileSource.friendlyLocation;

    // Check if sync is actively running for this vault
    final syncInfoGD = KeyNestCloudSyncManager.instance.getVaultSyncInfo(
      'GoogleDriveProvider',
      fileSource.uuid,
    );
    final syncInfoDB = KeyNestCloudSyncManager.instance.getVaultSyncInfo(
      'DropboxProvider',
      fileSource.uuid,
    );
    if (syncInfoGD.status == KeyNestSyncStatus.syncing ||
        syncInfoDB.status == KeyNestSyncStatus.syncing) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cannot move vault while synchronization is in progress. Please wait for sync to finish.',
          ),
        ),
      );
      return;
    }

    // Ensure all pending saves have completed
    await kdbxBloc.waitForPendingSaves();

    final defaultFileName = fileSource.displayNameFromPath
            .toLowerCase()
            .endsWith(AppConstants.kdbxExtension)
        ? fileSource.displayNameFromPath
        : '${fileSource.displayNameFromPath}${AppConstants.kdbxExtension}';

    FileInfo? chosenAndroidFileInfo;
    String? chosenDesktopPath;
    String chosenFriendlyLocation;

    try {
      if (KeyNestPlatform.isAndroid || KeyNestPlatform.isIOS) {
        final info = await FilePickerWritable().openFileForCreate(
          fileName: defaultFileName,
          writer: (file) async {
            // Write a dummy byte to establish the document in the user's chosen folder
            await file.writeAsBytes(const [0], flush: true);
          },
        );
        if (info == null) {
          return;
        }
        chosenAndroidFileInfo = info;

        // Check if destination is same as source
        if (fileSource.filePickerIdentifier != null &&
            (info.identifier == fileSource.filePickerIdentifier ||
                info.uri == fileSource.filePickerInfo?.uri)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The selected destination is the same as the current location.',
              ),
            ),
          );
          return;
        }

        final dummyFs = FileSourceLocal(
          FileSourceLocal.localFile(info.fileName ?? defaultFileName),
          uuid: 'temp',
          filePickerIdentifier: info.toJsonString(),
        );
        chosenFriendlyLocation = dummyFs.friendlyLocation;
      } else {
        // Desktop (Windows / Linux)
        String? chosenDir;
        try {
          chosenDir = await getDirectoryPath(
            confirmButtonText: 'Select Destination Folder',
          );
        } catch (_) {}

        if (chosenDir == null || chosenDir.isEmpty) {
          const typeGroup = XTypeGroup(
            label: 'KeePass Database (*.kdbx)',
            extensions: ['kdbx'],
          );
          final saveFile = await getSaveLocation(
            suggestedName: defaultFileName,
            acceptedTypeGroups: [typeGroup],
          );
          if (saveFile == null) {
            return;
          }
          chosenDesktopPath = saveFile.path;
        } else {
          chosenDesktopPath = p.join(chosenDir, defaultFileName);
        }

        // Check if destination is same as source
        if (p.canonicalize(chosenDesktopPath) ==
            p.canonicalize(fileSource.file.path)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The selected destination is the same as the current location.',
              ),
            ),
          );
          return;
        }

        // Collision check
        final destIoFile = io.File(chosenDesktopPath);
        if (destIoFile.existsSync()) {
          final confirmOverwrite = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('File Already Exists'),
              content: Text(
                'A file named "${p.basename(destIoFile.path)}" already exists at this destination. Do you want to overwrite it?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: KeyNestTokens.error,
                  ),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Overwrite'),
                ),
              ],
            ),
          );
          if (confirmOverwrite != true) {
            return;
          }
        }

        final dummyFs = FileSourceLocal(
          FileSourceLocal.localFile(chosenDesktopPath),
          uuid: 'temp',
        );
        chosenFriendlyLocation = dummyFs.friendlyLocation;
      }
    } catch (e) {
      _logger.warning('Failed during destination selection: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not select destination: $e')),
      );
      return;
    }

    // Step 2: Show confirmation dialog with vault name and chosen destination
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move Vault'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Are you sure you want to move this vault? The vault file will be relocated to the selected destination.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(ctx).brightness == Brightness.dark
                    ? KeyNestTokens.surfaceContainerDark
                    : KeyNestTokens.surfaceLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(ctx).brightness == Brightness.dark
                      ? KeyNestTokens.borderDark
                      : KeyNestTokens.borderLight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.security_rounded,
                        size: 16,
                        color: KeyNestTokens.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          vaultName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  Text(
                    'Current Location:',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(ctx).brightness == Brightness.dark
                          ? KeyNestTokens.textSecondaryDark
                          : KeyNestTokens.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    currentFriendly,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'New Destination:',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(ctx).brightness == Brightness.dark
                          ? KeyNestTokens.textSecondaryDark
                          : KeyNestTokens.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chosenFriendlyLocation,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: KeyNestTokens.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Move Vault'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _isProcessing = true);

    try {
      await kdbxBloc.waitForPendingSaves();

      Uint8List bytesToMove;
      if (fileSource.lastContent?.content != null &&
          fileSource.lastContent!.content.isNotEmpty) {
        bytesToMove = fileSource.lastContent!.content;
      } else {
        final content = await fileSource.content().last;
        bytesToMove = content.content.isNotEmpty
            ? content.content
            : await kdbxFile.save();
      }

      FileSourceLocal newSource;
      if (chosenAndroidFileInfo != null) {
        final identifier = chosenAndroidFileInfo.identifier;
        await FileSourceLocal.createFileInNewTempDirectory(
          defaultFileName,
          (tempFile) async {
            await tempFile.writeAsBytes(bytesToMove, flush: true);
            await FilePickerWritable().writeFileWithIdentifier(
              identifier,
              tempFile,
            );
          },
        );

        // Verify destination file before touching source
        final readBack = await FilePickerWritable().readFile(
          identifier: identifier,
          reader: (info, file) async => await file.readAsBytes(),
        );

        if (readBack.isEmpty ||
            !GoogleDriveSyncEngine.isValidKdbxBytes(
              Uint8List.fromList(readBack),
            )) {
          throw Exception('Destination file failed integrity verification.');
        }

        newSource = FileSourceLocal(
          FileSourceLocal.localFile(
            chosenAndroidFileInfo.fileName ?? defaultFileName,
          ),
          databaseName: fileSource.databaseName,
          uuid: fileSource.uuid,
          filePickerIdentifier: chosenAndroidFileInfo.toJsonString(),
        );
      } else if (chosenDesktopPath != null) {
        final destFile = io.File(chosenDesktopPath);
        if (!destFile.parent.existsSync()) {
          destFile.parent.createSync(recursive: true);
        }
        await destFile.writeAsBytes(bytesToMove, flush: true);

        // Verify destination file before touching source
        if (!destFile.existsSync() || destFile.lengthSync() == 0) {
          throw Exception('Destination file could not be created or is empty.');
        }
        final destBytes = await destFile.readAsBytes();
        if (!GoogleDriveSyncEngine.isValidKdbxBytes(destBytes)) {
          throw Exception('Destination file is not a valid KDBX file.');
        }

        String? macOsBookmark;
        if (KeyNestPlatform.isMacOS) {
          macOsBookmark = await SecureBookmarks().bookmark(destFile);
        }

        newSource = FileSourceLocal(
          FileSourceLocal.localFile(chosenDesktopPath),
          databaseName: fileSource.databaseName,
          uuid: fileSource.uuid,
          macOsSecureBookmark: macOsBookmark,
        );
      } else {
        throw Exception('No destination path available.');
      }

      // Update active backing reference in KdbxBloc & AppDataBloc
      await kdbxBloc.replaceFileSource(fileSource, newSource);

      // Delete old source file ONLY after destination verification has succeeded
      try {
        if (fileSource.file.existsSync()) {
          await fileSource.file.delete();
        }
      } catch (e) {
        _logger.warning('Could not delete old source file after move: $e');
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Vault moved successfully to $chosenFriendlyLocation'),
        ),
      );
    } catch (e, stack) {
      _logger.severe('Failed to move vault: $e', e, stack);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to move vault: $e'),
          backgroundColor: KeyNestTokens.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _syncSingleVault(
    BuildContext context,
    MapEntry<FileSource, KdbxOpenedFile> fileEntry,
    KdbxBloc kdbxBloc,
  ) async {
    setState(() => _isProcessing = true);
    try {
      await kdbxBloc.saveFile(fileEntry.value.kdbxFile);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${fileEntry.key.displayName} synchronized successfully.',
            ),
            duration: const Duration(milliseconds: 2000),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        DialogUtils.showErrorDialog(
          context,
          'Sync Failed',
          'Failed to synchronize vault: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _syncAllVaults(BuildContext context, KdbxBloc kdbxBloc) async {
    setState(() => _isProcessing = true);
    try {
      final syncedNames = <String>[];
      for (final entry in kdbxBloc.openedFiles.entries) {
        await kdbxBloc.saveFile(entry.value.kdbxFile);
        syncedNames.add(entry.key.displayName);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Synchronized ${syncedNames.length} vaults: ${syncedNames.join(', ')}',
            ),
            duration: const Duration(milliseconds: 2500),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        DialogUtils.showErrorDialog(
          context,
          'Sync Failed',
          'An error occurred while synchronizing vaults: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _closeVaultWithConfirmation(
    BuildContext context,
    MapEntry<FileSource, KdbxOpenedFile> fileEntry,
    KdbxBloc kdbxBloc,
    int totalVaultsCount,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        title: const Text('Close Vault?'),
        content: Text(
          'Are you sure you want to lock and close "${fileEntry.key.displayName}"? '
          'Any unsaved changes will be saved before closing.',
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Close Vault'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isProcessing = true);
      try {
        await kdbxBloc.saveFile(fileEntry.value.kdbxFile);
        await kdbxBloc.close(fileEntry.value.kdbxFile);

        if (totalVaultsCount <= 1 && mounted) {
          Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
            LockedScreen.route(),
            (_) => false,
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Closed vault ${fileEntry.key.displayName}.'),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Could not close vault: $e',
          );
        }
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _disconnectVaultWithConfirmation(
    BuildContext context,
    MapEntry<FileSource, KdbxOpenedFile> fileEntry,
    KdbxBloc kdbxBloc,
    int totalVaultsCount,
  ) async {
    final appDataBloc = context.read<AppDataBloc>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        title: const Row(
          children: [
            Icon(Icons.link_off_rounded, color: KeyNestTokens.error),
            SizedBox(width: 8),
            Text('Disconnect Vault?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to disconnect "${fileEntry.key.displayName}" from KeyNest?',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    (Theme.of(ctx).brightness == Brightness.dark
                            ? KeyNestPalette.primaryDark
                            : KeyNestTokens.primary)
                        .withValues(
                          alpha: Theme.of(ctx).brightness == Brightness.dark
                              ? 0.20
                              : 0.08,
                        ),
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
                border: Border.all(
                  color:
                      (Theme.of(ctx).brightness == Brightness.dark
                              ? KeyNestPalette.primaryDark
                              : KeyNestTokens.primary)
                          .withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: Theme.of(ctx).brightness == Brightness.dark
                        ? KeyNestPalette.primaryDark
                        : KeyNestTokens.primary,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your original KDBX database file on disk will NOT be deleted or modified. '
                      'This only disconnects and removes the vault from KeyNest so it is no longer opened or remembered in your recent vaults. '
                      'You can reopen it at any time using "Open Existing Vault".',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Disconnect Vault'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isProcessing = true);
      try {
        if (KeyNestVaultScope.instance.getSelectedVault(kdbxBloc) ==
            fileEntry.value.kdbxFile) {
          KeyNestVaultScope.instance.setSelectedVault(kdbxBloc, null);
        }
        KeyNestVaultScope.instance.clearVaultFromAllTabs(fileEntry.key.uuid);
        KeyNestVaultScope.instance.clearVaultFromAllTabs(
          fileEntry.key.displayPath,
        );
        await DropboxSyncStateStore().clearVaultSyncState(fileEntry.key.uuid);
        await GoogleDriveSyncStateStore().clearVaultSyncState(
          fileEntry.key.uuid,
        );
        await kdbxBloc.quickUnlockStorage.removeVaultCredential(
          fileEntry.key.uuid,
        );
        await KeyNestKeyFileStore.instance.removeReference(fileEntry.key.uuid);
        await kdbxBloc.saveFile(fileEntry.value.kdbxFile);
        await kdbxBloc.close(fileEntry.value.kdbxFile);
        await appDataBloc.update((builder, data) {
          builder.previousFiles.removeWhere(
            (f) =>
                f.uuid == fileEntry.key.uuid ||
                f.isSameFileAs(fileEntry.value.openedFile),
          );
        });

        if (totalVaultsCount <= 1 && mounted) {
          final remainingPrevious =
              (await appDataBloc.store.load()).previousFiles;
          if (remainingPrevious.isNotEmpty) {
            Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
              LockedScreen.route(),
              (_) => false,
            );
          } else {
            Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
              SelectFileScreen.route(),
              (_) => false,
            );
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Disconnected vault "${fileEntry.key.displayName}". Original file safe on disk.',
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Could not disconnect vault: $e',
          );
        }
      } finally {
        if (mounted) {
          setState(() => _isProcessing = false);
        }
      }
    }
  }

  // Folder Actions
  Future<void> _handleFolderAction(
    BuildContext context,
    _FolderAction action,
    KdbxGroup group,
    KdbxFile kdbxFile,
    KdbxBloc kdbxBloc,
  ) async {
    switch (action) {
      case _FolderAction.viewEntries:
        KeyNestVaultScope.instance.setSelectedVaultAndFolder(
          kdbxBloc,
          kdbxFile,
          group,
          targetTab: 0,
        );
        Navigator.of(context).pop(group);
        break;
      case _FolderAction.addSubfolder:
        await _promptCreateSubfolder(context, kdbxFile, group, kdbxBloc);
        break;
      case _FolderAction.rename:
        await _promptRenameFolder(context, kdbxFile, group, kdbxBloc);
        break;
      case _FolderAction.moveFolder:
        await _promptMoveFolder(context, kdbxFile, group, kdbxBloc);
        break;
      case _FolderAction.delete:
        await _promptDeleteFolder(context, kdbxFile, group, kdbxBloc);
        break;
      case _FolderAction.deletePermanently:
        await _promptPermanentlyDeleteFolder(
          context,
          kdbxFile,
          group,
          kdbxBloc,
        );
        break;
      case _FolderAction.restore:
        await _restoreFolderFromTrash(context, kdbxFile, group, kdbxBloc);
        break;
      case _FolderAction.emptyTrash:
        await _promptEmptyTrash(context, kdbxFile, group, kdbxBloc);
        break;
    }
  }

  Future<void> _promptCreateSubfolder(
    BuildContext context,
    KdbxFile kdbxFile,
    KdbxGroup parentGroup,
    KdbxBloc kdbxBloc,
  ) async {
    final textController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        title: const Text('New Folder'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder Name',
            hintText: 'e.g. Work, Banking, Social',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(ctx).brightness == Brightness.dark
                  ? KeyNestPalette.primaryDark
                  : KeyNestTokens.primary,
              foregroundColor: Theme.of(ctx).brightness == Brightness.dark
                  ? const Color(0xFF00315D)
                  : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
              ),
            ),
            onPressed: () {
              final val = textController.text.trim();
              if (val.isNotEmpty) Navigator.of(ctx).pop(val);
            },
            child: Text(
              'Create',
              style: TextStyle(
                color: Theme.of(ctx).brightness == Brightness.dark
                    ? const Color(0xFF00315D)
                    : Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty && mounted) {
      setState(() => _isProcessing = true);
      try {
        kdbxFile.createGroup(parent: parentGroup, name: name);
        await kdbxBloc.saveFile(kdbxFile);
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Failed to create folder: $e',
          );
        }
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _promptRenameFolder(
    BuildContext context,
    KdbxFile kdbxFile,
    KdbxGroup group,
    KdbxBloc kdbxBloc,
  ) async {
    final textController = TextEditingController(
      text: group.name.get() ?? 'Folder',
    );
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        title: const Text('Rename Folder'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(ctx).brightness == Brightness.dark
                  ? KeyNestPalette.primaryDark
                  : KeyNestTokens.primary,
              foregroundColor: Theme.of(ctx).brightness == Brightness.dark
                  ? const Color(0xFF00315D)
                  : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
              ),
            ),
            onPressed: () {
              final val = textController.text.trim();
              if (val.isNotEmpty) Navigator.of(ctx).pop(val);
            },
            child: Text(
              'Rename',
              style: TextStyle(
                color: Theme.of(ctx).brightness == Brightness.dark
                    ? const Color(0xFF00315D)
                    : Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && mounted) {
      setState(() => _isProcessing = true);
      try {
        group.name.set(newName);
        await kdbxBloc.saveFile(kdbxFile);
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Failed to rename folder: $e',
          );
        }
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _promptMoveFolder(
    BuildContext context,
    KdbxFile kdbxFile,
    KdbxGroup group,
    KdbxBloc kdbxBloc,
  ) async {
    // List candidate parent groups in the SAME vault (excluding itself and its descendants)
    final root = kdbxFile.body.rootGroup;
    final allGroups = root.getAllGroups().where((g) {
      if (g.uuid == group.uuid) return false;
      // Exclude descendants
      KdbxGroup? p = g.parent;
      while (p != null) {
        if (p.uuid == group.uuid) return false;
        p = p.parent;
      }
      return true;
    }).toList();

    // Include rootGroup as candidate
    final candidates = [root, ...allGroups.where((g) => g.uuid != root.uuid)];

    final selectedTarget = await showDialog<KdbxGroup>(
      context: context,
      builder: (ctx) => SimpleDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        title: const Text('Select Destination Folder'),
        children: candidates.map((target) {
          final isRoot = target == root;
          final title = isRoot
              ? 'Root Folder (${KeyNestVaultScope.cleanVaultName(kdbxBloc, kdbxFile)})'
              : (target.name.get() ?? 'Folder');
          return SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(target),
            child: ListTile(
              leading: Icon(
                isRoot
                    ? Icons.home_repair_service_rounded
                    : Icons.folder_rounded,
                color: Theme.of(ctx).brightness == Brightness.dark
                    ? KeyNestPalette.primaryDark
                    : KeyNestTokens.primary,
              ),
              title: Text(title),
            ),
          );
        }).toList(),
      ),
    );

    if (selectedTarget != null && mounted) {
      setState(() => _isProcessing = true);
      try {
        kdbxFile.move(group, selectedTarget);
        await kdbxBloc.saveFile(kdbxFile);
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Failed to move folder: $e',
          );
        }
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _promptDeleteFolder(
    BuildContext context,
    KdbxFile kdbxFile,
    KdbxGroup group,
    KdbxBloc kdbxBloc,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        title: const Text('Delete Folder?'),
        content: Text(
          'Delete folder "${group.name.get() ?? 'Folder'}" and move its contents to Recycle Bin?',
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isProcessing = true);
      try {
        final scope = KeyNestVaultScope.instance;
        final currentFolder = scope.getCurrentFolder(kdbxBloc);
        if (currentFolder != null &&
            (currentFolder == group ||
                group.getAllGroups().contains(currentFolder))) {
          scope.setCurrentFolder(group.parent ?? kdbxFile.body.rootGroup);
        }
        kdbxFile.deleteGroup(group);
        await kdbxBloc.saveFile(kdbxFile);
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Failed to delete folder: $e',
          );
        }
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _promptPermanentlyDeleteFolder(
    BuildContext context,
    KdbxFile kdbxFile,
    KdbxGroup group,
    KdbxBloc kdbxBloc,
  ) async {
    final folderName = group.name.get() ?? 'Folder';
    final entryCount = group
        .getAllEntries()
        .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
        .length;
    final subfolderCount = group
        .getAllGroups()
        .where(
          (g) => g != group && !KeyNestItemTypeHelper.isTrashOrRecycleBin(g),
        )
        .length;

    String contentMessage =
        'Permanently delete folder "$folderName"?\n\nThis will permanently remove this folder';
    if (entryCount > 0 && subfolderCount > 0) {
      contentMessage +=
          ', $entryCount ${entryCount == 1 ? 'entry' : 'entries'}, and $subfolderCount ${subfolderCount == 1 ? 'subfolder' : 'subfolders'}.';
    } else if (entryCount > 0) {
      contentMessage +=
          ' and $entryCount ${entryCount == 1 ? 'entry' : 'entries'}.';
    } else if (subfolderCount > 0) {
      contentMessage +=
          ' and $subfolderCount ${subfolderCount == 1 ? 'subfolder' : 'subfolders'}.';
    } else {
      contentMessage += '.';
    }
    contentMessage += '\n\nThis action cannot be undone.';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        title: const Text('Permanently Delete Folder?'),
        content: Text(contentMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: KeyNestTokens.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isProcessing = true);
      try {
        final scope = KeyNestVaultScope.instance;
        final currentFolder = scope.getCurrentFolder(kdbxBloc);
        if (currentFolder != null &&
            (currentFolder == group ||
                group.getAllGroups().contains(currentFolder))) {
          scope.setCurrentFolder(group.parent ?? kdbxFile.body.rootGroup);
        }

        kdbxFile.deletePermanently(group);
        await kdbxBloc.saveFile(kdbxFile);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Permanently deleted "$folderName".'),
              backgroundColor: KeyNestTokens.primary,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Failed to permanently delete folder: $e',
          );
        }
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _restoreFolderFromTrash(
    BuildContext context,
    KdbxFile kdbxFile,
    KdbxGroup group,
    KdbxBloc kdbxBloc,
  ) async {
    setState(() => _isProcessing = true);
    try {
      kdbxFile.move(group, kdbxFile.body.rootGroup);
      await kdbxBloc.saveFile(kdbxFile);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Restored "${group.name.get() ?? 'Folder'}" to root.',
            ),
            backgroundColor: KeyNestTokens.primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        DialogUtils.showErrorDialog(
          context,
          'Error',
          'Failed to restore folder: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _promptEmptyTrash(
    BuildContext context,
    KdbxFile kdbxFile,
    KdbxGroup recycleBin,
    KdbxBloc kdbxBloc,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
        ),
        title: const Text('Empty Trash?'),
        content: const Text(
          'Permanently delete all folders and entries in Trash? This action cannot be undone.',
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusCard),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Empty Trash'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isProcessing = true);
      try {
        final scope = KeyNestVaultScope.instance;
        final currentFolder = scope.getCurrentFolder(kdbxBloc);
        if (currentFolder != null && currentFolder.isInRecycleBin()) {
          scope.setCurrentFolder(kdbxFile.body.rootGroup);
        }

        List<KdbxGroup>.from(
          recycleBin.groups,
        ).forEach(kdbxFile.deletePermanently);
        List<KdbxEntry>.from(
          recycleBin.entries,
        ).forEach(kdbxFile.deletePermanently);

        await kdbxBloc.saveFile(kdbxFile);
        if (mounted) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Trash emptied permanently.',
                style: TextStyle(
                  color: isDark ? const Color(0xFF00315D) : Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              backgroundColor: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Failed to empty trash: $e',
          );
        }
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }
  }

  // Vault Creation and Open Dialogs
  void _showAddVaultSheet(BuildContext context) {
    KeyNestBottomSheet.show(
      context: context,
      title: 'Add KDBX Vault',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          KeyNestCompactCard(
            leading: KeyNestCompactIconTile(
              icon: Icons.create_new_folder_rounded,
              tint: Theme.of(context).brightness == Brightness.dark
                  ? KeyNestPalette.primaryDark
                  : KeyNestTokens.primary,
            ),
            title: 'Create New Vault',
            subtitle:
                'Set up a new encrypted KDBX database with a master password',
            onTap: () {
              Navigator.of(context).pop();
              _showCreateVaultDialog(context, context.read<KdbxBloc>());
            },
          ),
          const SizedBox(height: 10),
          KeyNestCompactCard(
            leading: KeyNestCompactIconTile(
              icon: Icons.folder_open_rounded,
              tint: KeyNestTokens.accent,
            ),
            title: 'Open Existing Vault',
            subtitle:
                'Choose a .kdbx file from your device and unlock with master password',
            onTap: () {
              Navigator.of(context).pop();
              _openExistingVault(context);
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Future<void> _openExistingVault(BuildContext context) async {
    final kdbxBloc = context.read<KdbxBloc>();
    if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
      try {
        await FilePickerWritable().openFile((fileInfo, file) async {
          final bytes = await file.readAsBytes();
          if (bytes.isEmpty) {
            if (mounted) {
              DialogUtils.showSimpleAlertDialog(
                context,
                'Empty File',
                'The selected file "${fileInfo.fileName ?? 'database'}" is empty (0 bytes).',
                routeAppend: 'emptyFile',
              );
            }
            return;
          }
          if (!SelectFileScreen.isValidKdbxHeader(bytes)) {
            if (mounted) {
              DialogUtils.showSimpleAlertDialog(
                context,
                'Invalid File',
                'The file "${fileInfo.fileName ?? 'database'}" is not a valid KeePass (.kdbx) database.',
                routeAppend: 'invalidKdbx',
              );
            }
            return;
          }

          // Check if already open by uri or file path
          final existing = kdbxBloc.openedFiles.values.firstWhereOrNull((of) {
            final fs = of.fileSource;
            if (fs is FileSourceLocal) {
              if (fs.filePickerInfo?.uri != null &&
                  fs.filePickerInfo?.uri == fileInfo.uri) {
                return true;
              }
              if (fs.displayPath == fileInfo.uri.toString() ||
                  fs.file.path == file.path) {
                return true;
              }
            }
            return false;
          });

          if (existing != null) {
            if (mounted) {
              final isDark = Theme.of(context).brightness == Brightness.dark;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Vault "${existing.fileSource.displayName}" is already open.',
                    style: TextStyle(
                      color: isDark ? const Color(0xFF00315D) : Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  backgroundColor: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                ),
              );
              Navigator.of(context).pop(existing.kdbxFile.body.rootGroup);
            }
            return;
          }

          final cleanName = fileInfo.fileName != null
              ? p.basenameWithoutExtension(fileInfo.fileName!)
              : 'vault';

          final source = FileSourceLocal(
            FileSourceLocal.localFile(file.path),
            databaseName: cleanName,
            uuid: AppDataBloc.createUuid(),
            filePickerIdentifier: fileInfo.toJsonString(),
            initialCachedContent: FileContent(bytes),
          );

          if (mounted) {
            await Navigator.of(context).push(CredentialsScreen.route(source));
          }
        });
      } catch (e) {
        _logger.warning('Failed to open mobile file picker: $e');
        if (mounted) {
          await Navigator.of(context).push(SelectFileScreen.route());
        }
      }
    } else {
      // Desktop / Web
      try {
        const typeGroup = XTypeGroup(
          label: 'KeePass Database (*.kdbx)',
          extensions: ['kdbx'],
        );
        final file = await openFile(acceptedTypeGroups: [typeGroup]);
        if (file == null) return;

        final bytes = await file.readAsBytes();
        if (!SelectFileScreen.isValidKdbxHeader(bytes)) {
          if (mounted) {
            DialogUtils.showSimpleAlertDialog(
              context,
              'Invalid File',
              'The selected file is not a valid KeePass (.kdbx) database.',
              routeAppend: 'invalidKdbx',
            );
          }
          return;
        }

        final existing = kdbxBloc.openedFiles.values.firstWhereOrNull((of) {
          final fs = of.fileSource;
          return fs is FileSourceLocal && fs.file.path == file.path;
        });

        if (existing != null) {
          if (mounted) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Vault "${existing.fileSource.displayName}" is already open.',
                  style: TextStyle(
                    color: isDark ? const Color(0xFF00315D) : Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                backgroundColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
              ),
            );
            Navigator.of(context).pop(existing.kdbxFile.body.rootGroup);
          }
          return;
        }

        String? macOsBookmark;
        if (KeyNestPlatform.isMacOS) {
          macOsBookmark = await SecureBookmarks().bookmark(io.File(file.path));
        }

        final cleanName = p.basenameWithoutExtension(file.name);
        final source = FileSourceLocal(
          FileSourceLocal.localFile(file.path),
          databaseName: cleanName,
          uuid: AppDataBloc.createUuid(),
          macOsSecureBookmark: macOsBookmark,
          initialCachedContent: FileContent(bytes),
        );

        if (mounted) {
          await Navigator.of(context).push(CredentialsScreen.route(source));
        }
      } catch (e) {
        _logger.warning('Failed to open desktop file picker: $e');
        if (mounted) {
          await Navigator.of(context).push(SelectFileScreen.route());
        }
      }
    }
  }

  Future<void> _showCreateVaultDialog(
    BuildContext context,
    KdbxBloc kdbxBloc,
  ) async {
    final defaultVaultName = kdbxBloc.openedFilesKdbx.isEmpty
        ? 'Vault'
        : 'Vault${kdbxBloc.openedFilesKdbx.length + 1}';
    final nameController = TextEditingController(text: defaultVaultName);
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    bool useCustomPath = false;
    FileSource? customFileSource;
    String? customPathLabel;

    final biometricSupported = await kdbxBloc.quickUnlockStorage
        .supportsBiometricKeyStore();
    bool biometricEnabled = biometricSupported;
    final keyFileController = KeyNestKeyFileCreationController();

    try {
      final created = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            Future<void> pickLocation() async {
              final dbName = nameController.text.trim().isNotEmpty
                  ? nameController.text.trim()
                  : 'vault';
              final fileName = '$dbName.kdbx';
              try {
                if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
                  final fileInfo =
                      await FileSourceLocal.createFileInNewTempDirectory(
                        fileName,
                        (tempFile) async {
                          return await FilePickerWritable().openFileForCreate(
                            fileName: fileName,
                            writer: (file) async {
                              await file.writeAsBytes(const [0], flush: true);
                            },
                          );
                        },
                      );
                  if (fileInfo != null) {
                    setDialogState(() {
                      useCustomPath = true;
                      customFileSource = FileSourceLocal(
                        FileSourceLocal.localFile(
                          fileInfo.fileName ?? fileName,
                        ),
                        databaseName: dbName,
                        uuid: AppDataBloc.createUuid(),
                        filePickerIdentifier: fileInfo.toJsonString(),
                      );
                      customPathLabel =
                          fileInfo.fileName ?? fileInfo.uri.toString();
                    });
                  }
                } else if (!KeyNestPlatform.isWeb) {
                  const typeGroup = XTypeGroup(
                    label: 'KeePass Database (*.kdbx)',
                    extensions: ['kdbx'],
                  );
                  final pathFile = await getSaveLocation(
                    suggestedName: fileName,
                    acceptedTypeGroups: [typeGroup],
                  );
                  if (pathFile != null) {
                    String? macOsBookmark;
                    if (KeyNestPlatform.isMacOS) {
                      macOsBookmark = await SecureBookmarks().bookmark(
                        io.File(pathFile.path),
                      );
                    }
                    setDialogState(() {
                      useCustomPath = true;
                      customFileSource = FileSourceLocal(
                        FileSourceLocal.localFile(pathFile.path),
                        databaseName: dbName,
                        uuid: AppDataBloc.createUuid(),
                        macOsSecureBookmark: macOsBookmark,
                      );
                      customPathLabel = pathFile.path;
                    });
                  }
                }
              } catch (e) {
                _logger.warning('Error choosing file location: $e');
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
              ),
              title: Row(
                children: [
                  Icon(
                    Icons.shield_rounded,
                    color: Theme.of(ctx).brightness == Brightness.dark
                        ? KeyNestPalette.primaryDark
                        : KeyNestTokens.primary,
                  ),
                  const SizedBox(width: 8),
                  const Text('Create KDBX Vault'),
                ],
              ),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: KeyNestPlatform.isDesktopOrWeb
                      ? 520
                      : double.infinity,
                ),
                child: SingleChildScrollView(
                  child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Vault Name',
                          suffixText: '.kdbx',
                          filled: true,
                        ),
                        validator: (val) {
                          if (val == null || val.trim().isEmpty) {
                            return 'Please enter a vault name';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      PasswordInputField(
                        controller: passwordController,
                        labelText: 'Master Password',
                        validator: (val) {
                          if (val == null || val.isEmpty) {
                            return 'Please enter a master password';
                          }
                          if (val.length < 6) {
                            return 'Password must be at least 6 characters';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      PasswordInputField(
                        controller: confirmController,
                        labelText: 'Confirm Master Password',
                        validator: (val) {
                          if (val != passwordController.text) {
                            return 'Passwords do not match';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      // Key File Creation Section
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).brightness == Brightness.dark
                              ? KeyNestTokens.surfaceContainerDark
                              : KeyNestTokens.surfaceLight,
                          borderRadius: BorderRadius.circular(
                            KeyNestTokens.radiusCard,
                          ),
                          border: Border.all(
                            color: Theme.of(ctx).brightness == Brightness.dark
                                ? KeyNestTokens.borderDark
                                : KeyNestTokens.borderLight,
                          ),
                        ),
                        child: KeyNestKeyFileCreationSection(
                          controller: keyFileController,
                          getVaultName: () => nameController.text,
                        ),
                      ),
                      if (biometricSupported) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(ctx).brightness == Brightness.dark
                                ? KeyNestTokens.surfaceContainerDark
                                : KeyNestTokens.surfaceLight,
                            borderRadius: BorderRadius.circular(
                              KeyNestTokens.radiusCard,
                            ),
                            border: Border.all(
                              color: Theme.of(ctx).brightness == Brightness.dark
                                  ? KeyNestTokens.borderDark
                                  : KeyNestTokens.borderLight,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.fingerprint_rounded,
                                size: 22,
                                color:
                                    Theme.of(ctx).brightness == Brightness.dark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestTokens.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      AppLocalizations.of(
                                        ctx,
                                      ).saveMasterPasswordBiometric,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    Text(
                                      'Unlock this vault quickly with biometrics',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color:
                                            Theme.of(ctx).brightness ==
                                                Brightness.dark
                                            ? KeyNestTokens.textSecondaryDark
                                            : KeyNestTokens.textSecondaryLight,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch.adaptive(
                                value: biometricEnabled,
                                onChanged: (val) {
                                  setDialogState(() {
                                    biometricEnabled = val;
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      // Storage Location Section
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).brightness == Brightness.dark
                              ? KeyNestTokens.surfaceContainerDark
                              : KeyNestTokens.surfaceLight,
                          borderRadius: BorderRadius.circular(
                            KeyNestTokens.radiusCard,
                          ),
                          border: Border.all(
                            color: Theme.of(ctx).brightness == Brightness.dark
                                ? KeyNestTokens.borderDark
                                : KeyNestTokens.borderLight,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.folder_special_rounded,
                                  size: 18,
                                  color:
                                      Theme.of(ctx).brightness ==
                                          Brightness.dark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestTokens.primary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Save Location',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              useCustomPath && customPathLabel != null
                                  ? customPathLabel!
                                  : 'App Storage (Default)',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    Theme.of(ctx).brightness == Brightness.dark
                                    ? KeyNestTokens.textSecondaryDark
                                    : KeyNestTokens.textSecondaryLight,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  icon: const Icon(
                                    Icons.folder_open_rounded,
                                    size: 16,
                                  ),
                                  label: Text(
                                    useCustomPath
                                        ? 'Change Location'
                                        : 'Choose Custom Location',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  onPressed: pickLocation,
                                ),
                                if (useCustomPath) ...[
                                  const SizedBox(width: 8),
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 6,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      foregroundColor: Colors.grey,
                                    ),
                                    child: const Text(
                                      'Reset',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    onPressed: () {
                                      setDialogState(() {
                                        useCustomPath = false;
                                        customFileSource = null;
                                        customPathLabel = null;
                                      });
                                    },
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'This creates a 100% standard KDBX file with Argon2/AES encryption, compatible with all KeePass applications.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(ctx).brightness == Brightness.dark
                        ? KeyNestPalette.primaryDark
                        : KeyNestTokens.primary,
                    foregroundColor: Theme.of(ctx).brightness == Brightness.dark
                        ? const Color(0xFF00315D)
                        : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        KeyNestTokens.radiusCard,
                      ),
                    ),
                  ),
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) {
                      return;
                    }
                    final ok = await keyFileController.validateAndEnsureSaved(
                      context: ctx,
                      defaultBaseName: nameController.text,
                    );
                    if (!ok) {
                      return;
                    }
                    if (ctx.mounted) {
                      Navigator.of(ctx).pop(true);
                    }
                  },
                  child: Text(
                    'Create Vault',
                    style: TextStyle(
                      color: Theme.of(ctx).brightness == Brightness.dark
                          ? const Color(0xFF00315D)
                          : Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );

      if (created == true && mounted) {
        setState(() => _isProcessing = true);
        try {
          final cleanName = nameController.text.trim().replaceAll(
            RegExp(r'\.kdbx$', caseSensitive: false),
            '',
          );
          final createdFile = await kdbxBloc.createFile(
            password: passwordController.text,
            databaseName: cleanName,
            keyFileBytes: keyFileController.effectiveKeyFileBytes,
            openAfterCreate: true,
            customFileSource: useCustomPath ? customFileSource : null,
            addToQuickUnlock: biometricEnabled,
          );
          await keyFileController.saveReferenceForVault(createdFile.uuid);
          await KeyNestPreferencesService.setCompletedOnboarding(true);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Vault "$cleanName.kdbx" created and opened!'),
                backgroundColor: KeyNestPalette.success,
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            DialogUtils.showErrorDialog(
              context,
              'Creation Failed',
              'Failed to create vault: $e',
            );
          }
        } finally {
          if (mounted) setState(() => _isProcessing = false);
        }
      }
    } finally {
      keyFileController.dispose();
    }
  }
}

enum _VaultAction {
  addRootFolder,
  syncVault,
  filterEntries,
  moveVault,
  closeVault,
  disconnectVault,
}

enum _FolderAction {
  viewEntries,
  addSubfolder,
  rename,
  moveFolder,
  delete,
  deletePermanently,
  restore,
  emptyTrash,
}
