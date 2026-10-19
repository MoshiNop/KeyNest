import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_import_export_service.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/widgets/keynest_key_file_creation_section.dart';
import 'package:keynest/utils/item_type_helper.dart';

enum KeyNestExportFormat {
  kdbx,
  csv,
  json,
}

class KeyNestExportConfig {
  const KeyNestExportConfig({
    required this.file,
    required this.selection,
    this.newMasterPassword,
    this.newKeyFileBytes,
  });

  final KdbxFile file;
  final KeyNestExportSelection selection;
  final String? newMasterPassword;
  final Uint8List? newKeyFileBytes;
}

/// A bottom sheet that allows users to configure:
/// 1. Vault selection (supports single vault or multi-vault cross-vault selection)
/// 2. Scope: Entire vault, specific folder (and nested subfolders), or selected entries
/// 3. Setting & confirming new master password (for KDBX)
/// 4. Warning banner for unencrypted CSV/JSON exports
class KeyNestExportOptionsSheet extends StatefulWidget {
  const KeyNestExportOptionsSheet({
    super.key,
    required this.kdbxBloc,
    required this.format,
    required this.initialFile,
  });

  final KdbxBloc kdbxBloc;
  final KeyNestExportFormat format;
  final KdbxFile initialFile;

  static Future<KeyNestExportConfig?> show(
    BuildContext context, {
    required KdbxBloc kdbxBloc,
    required KeyNestExportFormat format,
    KdbxFile? initialFile,
  }) {
    final files = kdbxBloc.openedFilesKdbx;
    if (files.isEmpty) {
      return Future.value(null);
    }
    final targetFile = initialFile ?? files.first;

    return showModalBottomSheet<KeyNestExportConfig>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => KeyNestExportOptionsSheet(
        kdbxBloc: kdbxBloc,
        format: format,
        initialFile: targetFile,
      ),
    );
  }

  @override
  State<KeyNestExportOptionsSheet> createState() =>
      _KeyNestExportOptionsSheetState();
}

class _KeyNestExportOptionsSheetState extends State<KeyNestExportOptionsSheet> {
  KdbxFile? _selectedFile;
  KeyNestExportScope _scope = KeyNestExportScope.entireVault;
  KdbxGroup? _selectedFolder;
  final Map<String, KdbxEntry> _selectedEntries = {};
  String _searchQuery = '';

  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  bool _obscureNew = true;
  bool _obscureConfirm = true;
  String? _errorMessage;
  final KeyNestKeyFileCreationController _keyFileController =
      KeyNestKeyFileCreationController();

  static String _entryKey(KdbxEntry e) =>
      '${e.file.body.rootGroup.uuid.uuid}:${e.uuid.uuid}';

  @override
  void initState() {
    super.initState();
    _selectedFile = widget.initialFile;
    _selectedFolder = _selectedFile?.body.rootGroup;
  }

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    _keyFileController.dispose();
    super.dispose();
  }

  void _onVaultChanged(KdbxFile? file) {
    setState(() {
      _selectedFile = file;
      _selectedFolder = file?.body.rootGroup;
      _errorMessage = null;
    });
  }

  List<_FolderItem> _flattenFolders(
    KdbxGroup root, {
    int depth = 0,
    String? vaultName,
  }) {
    final items = <_FolderItem>[];
    if (!KeyNestItemTypeHelper.isTrashOrRecycleBin(root)) {
      items.add(_FolderItem(group: root, depth: depth, vaultName: vaultName));
      final sortedChildren = KeyNestItemTypeHelper.sortGroupsWithTrashLast(
        root.groups,
      );
      for (final child in sortedChildren) {
        if (!KeyNestItemTypeHelper.isTrashOrRecycleBin(child)) {
          items.addAll(
            _flattenFolders(child, depth: depth + 1, vaultName: vaultName),
          );
        }
      }
    }
    return items;
  }

  List<KdbxEntry> _getAllActiveEntries([KdbxFile? target]) {
    if (target != null) {
      return target.body.rootGroup
          .getAllEntries()
          .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
          .toList();
    }
    if (_selectedFile != null) {
      return _selectedFile!.body.rootGroup
          .getAllEntries()
          .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
          .toList();
    }
    return widget.kdbxBloc.openedFilesKdbx
        .expand((f) => f.body.rootGroup.getAllEntries())
        .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
        .toList();
  }

  Future<void> _handleSubmit() async {
    setState(() => _errorMessage = null);

    // Validate Scope Selection
    final KeyNestExportSelection selection;
    switch (_scope) {
      case KeyNestExportScope.entireVault:
        final all = _getAllActiveEntries();
        if (all.isEmpty) {
          setState(
            () => _errorMessage = 'Vault has no eligible entries to export.',
          );
          return;
        }
        if (_selectedFile != null) {
          selection = const KeyNestExportSelection.entireVault();
        } else {
          selection = KeyNestExportSelection.entries(all);
        }
        break;

      case KeyNestExportScope.folder:
        final folder = _selectedFolder;
        if (folder == null) {
          setState(() => _errorMessage = 'Please select a folder to export.');
          return;
        }
        final folderEntries = folder
            .getAllEntries()
            .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
            .toList();
        if (folderEntries.isEmpty) {
          setState(
            () => _errorMessage =
                'Selected folder has no eligible entries to export.',
          );
          return;
        }
        selection = KeyNestExportSelection.folder(folder);
        break;

      case KeyNestExportScope.selectedEntries:
        if (_selectedEntries.isEmpty) {
          setState(
            () => _errorMessage = 'Please select at least one entry to export.',
          );
          return;
        }
        selection = KeyNestExportSelection.entries(
          _selectedEntries.values.toList(),
        );
        break;
    }

    // Validate KDBX Master Passwords and Key File
    String? newPassword;
    if (widget.format == KeyNestExportFormat.kdbx) {
      newPassword = _newPasswordController.text;
      final confirmPass = _confirmPasswordController.text;

      final keyFileOk = await _keyFileController.validateAndEnsureSaved(
        context: context,
        defaultBaseName: _selectedFile != null
            ? KeyNestVaultScope.cleanVaultName(widget.kdbxBloc, _selectedFile!)
            : 'keynest_export',
      );
      if (!keyFileOk) {
        return;
      }

      final effectiveKeyBytes = _keyFileController.effectiveKeyFileBytes;

      if (newPassword.isEmpty && effectiveKeyBytes == null) {
        setState(
          () => _errorMessage =
              'Please set a master password or configure a key file for the exported KDBX vault.',
        );
        return;
      }

      if (newPassword.isNotEmpty && newPassword != confirmPass) {
        setState(
          () => _errorMessage =
              'Export master password and confirmation do not match.',
        );
        return;
      }
    }

    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(
      KeyNestExportConfig(
        file:
            _selectedFile ??
            _selectedFolder?.file ??
            _selectedEntries.values.firstOrNull?.file ??
            widget.initialFile,
        selection: selection,
        newMasterPassword: newPassword,
        newKeyFileBytes: _keyFileController.effectiveKeyFileBytes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final openedFiles = widget.kdbxBloc.openedFilesKdbx;

    final List<_FolderItem> folders;
    if (_selectedFile != null) {
      folders = _flattenFolders(_selectedFile!.body.rootGroup);
    } else {
      folders = openedFiles
          .expand(
            (f) => _flattenFolders(
              f.body.rootGroup,
              vaultName: KeyNestVaultScope.cleanVaultName(widget.kdbxBloc, f),
            ),
          )
          .toList();
    }

    final allEntries = _getAllActiveEntries();

    final filteredEntries = _searchQuery.isEmpty
        ? allEntries
        : allEntries.where((e) {
            final title = e.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
            final user = e.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
            final vaultName = openedFiles.length > 1
                ? KeyNestVaultScope.cleanVaultName(widget.kdbxBloc, e.file)
                : '';
            return title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                user.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                vaultName.toLowerCase().contains(_searchQuery.toLowerCase());
          }).toList();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.surfaceDark
            : KeyNestPalette.surfaceLight,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(KeyNestShapes.radiusSheet),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Sheet Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: widget.format == KeyNestExportFormat.kdbx
                            ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                  .withValues(alpha: isDark ? 0.20 : 0.12)
                            : KeyNestPalette.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        widget.format == KeyNestExportFormat.kdbx
                            ? Icons.shield_rounded
                            : widget.format == KeyNestExportFormat.csv
                            ? Icons.table_chart_rounded
                            : Icons.code_rounded,
                        color: widget.format == KeyNestExportFormat.kdbx
                            ? (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                            : KeyNestPalette.warning,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.format == KeyNestExportFormat.kdbx
                                ? 'Export KeePass (.kdbx)'
                                : widget.format == KeyNestExportFormat.csv
                                ? 'Export CSV Spreadsheet'
                                : 'Export JSON Document',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Configure scope, items, and export security',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),

              // Scrollable Body
              Flexible(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  shrinkWrap: true,
                  children: [
                    // Error Message Banner (if any)
                    if (_errorMessage != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: KeyNestPalette.error.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: KeyNestPalette.error.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: KeyNestPalette.error,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: KeyNestPalette.error,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Multi-vault selection (if more than 1 open vault)
                    if (openedFiles.length > 1) ...[
                      _buildSectionTitle('SOURCE VAULT'),
                      const SizedBox(height: 8),

                      // "All Open Vaults" option
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: InkWell(
                          onTap: () => _onVaultChanged(null),
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: _selectedFile == null
                                  ? (isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary)
                                        .withValues(alpha: isDark ? 0.20 : 0.12)
                                  : (isDark
                                        ? KeyNestPalette.surfaceContainerDark
                                        : KeyNestPalette.surfaceContainerLight),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _selectedFile == null
                                    ? (isDark
                                          ? KeyNestPalette.primaryDark
                                          : KeyNestPalette.primary)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.all_inclusive_rounded,
                                  size: 18,
                                  color: _selectedFile == null
                                      ? (isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary)
                                      : (isDark
                                            ? Colors.white70
                                            : Colors.black54),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'All Open Vaults (${openedFiles.length} vaults${_selectedEntries.isNotEmpty ? ' • ${_selectedEntries.length} selected' : ''})',
                                    style: TextStyle(
                                      fontWeight: _selectedFile == null
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (_selectedFile == null)
                                  Icon(
                                    Icons.check_circle_rounded,
                                    color: isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary,
                                    size: 18,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      ...openedFiles.map((f) {
                        final isSelected = f == _selectedFile;
                        final name = KeyNestVaultScope.cleanVaultName(
                          widget.kdbxBloc,
                          f,
                        );
                        final vaultSelectedCount = _selectedEntries.values
                            .where((e) => e.file == f)
                            .length;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: InkWell(
                            onTap: () => _onVaultChanged(f),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? (isDark
                                              ? KeyNestPalette.primaryDark
                                              : KeyNestPalette.primary)
                                          .withValues(
                                            alpha: isDark ? 0.20 : 0.12,
                                          )
                                    : (isDark
                                          ? KeyNestPalette.surfaceContainerDark
                                          : KeyNestPalette
                                                .surfaceContainerLight),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isSelected
                                      ? (isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.lock_rounded,
                                    size: 18,
                                    color: isSelected
                                        ? (isDark
                                              ? KeyNestPalette.primaryDark
                                              : KeyNestPalette.primary)
                                        : (isDark
                                              ? Colors.white70
                                              : Colors.black54),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      vaultSelectedCount > 0
                                          ? '$name ($vaultSelectedCount selected)'
                                          : name,
                                      style: TextStyle(
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  if (isSelected)
                                    Icon(
                                      Icons.check_circle_rounded,
                                      color: isDark
                                          ? KeyNestPalette.primaryDark
                                          : KeyNestPalette.primary,
                                      size: 18,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 16),
                    ],

                    // Export Scope Selection
                    _buildSectionTitle('EXPORT SCOPE'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _buildScopeOption(
                            scope: KeyNestExportScope.entireVault,
                            title: _selectedFile == null
                                ? 'All Vaults'
                                : 'Entire Vault',
                            subtitle: '${allEntries.length} items',
                            icon: Icons.all_inbox_rounded,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildScopeOption(
                            scope: KeyNestExportScope.folder,
                            title: 'Folder',
                            subtitle: 'Folder & subfolders',
                            icon: Icons.folder_outlined,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildScopeOption(
                            scope: KeyNestExportScope.selectedEntries,
                            title: 'Selected',
                            subtitle: '${_selectedEntries.length} chosen',
                            icon: Icons.checklist_rounded,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Scope: Specific Folder Options
                    if (_scope == KeyNestExportScope.folder) ...[
                      _buildSectionTitle('SELECT FOLDER TO EXPORT'),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: isDark
                              ? KeyNestPalette.surfaceContainerDark
                              : KeyNestPalette.surfaceContainerLight,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<KdbxGroup>(
                            isExpanded: true,
                            value:
                                _selectedFolder ?? folders.firstOrNull?.group,
                            items: folders.map((folderItem) {
                              final g = folderItem.group;
                              final name = g.name.get() ?? 'Root';
                              final prefix = folderItem.vaultName != null
                                  ? '[${folderItem.vaultName}] '
                                  : '';
                              final indent = '  ' * folderItem.depth;
                              final count = g
                                  .getAllEntries()
                                  .where(
                                    (e) =>
                                        !KeyNestItemTypeHelper.isEntryInTrash(
                                          e,
                                        ),
                                  )
                                  .length;
                              return DropdownMenuItem<KdbxGroup>(
                                value: g,
                                child: Text(
                                  '$indent📁 $prefix$name ($count items)',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              );
                            }).toList(),
                            onChanged: (newFolder) {
                              if (newFolder != null) {
                                setState(() => _selectedFolder = newFolder);
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Scope: Selected Entries Options
                    if (_scope == KeyNestExportScope.selectedEntries) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildSectionTitle('SELECT ENTRIES'),
                          Row(
                            children: [
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    for (final e in allEntries) {
                                      _selectedEntries[_entryKey(e)] = e;
                                    }
                                  });
                                },
                                child: const Text(
                                  'Select All',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    if (_selectedFile != null) {
                                      _selectedEntries.removeWhere(
                                        (_, e) => e.file == _selectedFile,
                                      );
                                    } else {
                                      _selectedEntries.clear();
                                    }
                                  });
                                },
                                child: const Text(
                                  'Clear',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      TextField(
                        decoration: InputDecoration(
                          hintText: 'Search entries...',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          isDense: true,
                          filled: true,
                          fillColor: isDark
                              ? KeyNestPalette.surfaceContainerDark
                              : KeyNestPalette.surfaceContainerLight,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (val) =>
                            setState(() => _searchQuery = val.trim()),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        decoration: BoxDecoration(
                          color: isDark
                              ? KeyNestPalette.surfaceContainerDark
                              : KeyNestPalette.surfaceContainerLight,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: filteredEntries.isEmpty
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text('No entries found'),
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: filteredEntries.length,
                                itemBuilder: (ctx, idx) {
                                  final entry = filteredEntries[idx];
                                  final isChecked = _selectedEntries
                                      .containsKey(_entryKey(entry));
                                  final title =
                                      entry
                                          .getString(KdbxKeyCommon.TITLE)
                                          ?.getText() ??
                                      'Untitled';
                                  final user =
                                      entry
                                          .getString(KdbxKeyCommon.USER_NAME)
                                          ?.getText() ??
                                      '';
                                  final vaultName = openedFiles.length > 1
                                      ? KeyNestVaultScope.cleanVaultName(
                                          widget.kdbxBloc,
                                          entry.file,
                                        )
                                      : '';
                                  final subtitle = [
                                    if (vaultName.isNotEmpty) vaultName,
                                    if (user.isNotEmpty) user,
                                  ].join(' • ');

                                  return CheckboxListTile(
                                    dense: true,
                                    value: isChecked,
                                    title: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                    subtitle: subtitle.isNotEmpty
                                        ? Text(
                                            subtitle,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          )
                                        : null,
                                    onChanged: (val) {
                                      setState(() {
                                        if (val == true) {
                                          _selectedEntries[_entryKey(entry)] =
                                              entry;
                                        } else {
                                          _selectedEntries.remove(
                                            _entryKey(entry),
                                          );
                                        }
                                      });
                                    },
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Security Section: CSV/JSON Plaintext Warning
                    if (widget.format != KeyNestExportFormat.kdbx) ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: KeyNestPalette.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: KeyNestPalette.warning.withValues(
                              alpha: 0.35,
                            ),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: KeyNestPalette.warning,
                              size: 22,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'UNENCRYPTED EXPORT WARNING',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.8,
                                      color: KeyNestPalette.warning,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.format == KeyNestExportFormat.csv
                                        ? 'CSV files are completely unencrypted. All usernames, passwords, and 2FA secrets will be stored in plain text readable by any application.'
                                        : 'JSON exports are stored as unencrypted plain text. Keep this file strictly in secure offline storage.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.35,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Security Section: KDBX Master Password Setup
                    if (widget.format == KeyNestExportFormat.kdbx) ...[
                      const Divider(),
                      const SizedBox(height: 8),

                      _buildSectionTitle('SET EXPORT MASTER PASSWORD'),
                      const SizedBox(height: 4),
                      Text(
                        'Create a new master password to encrypt the exported KDBX database. Never reuse credentials blindly.',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _newPasswordController,
                        obscureText: _obscureNew,
                        decoration: InputDecoration(
                          labelText: 'New Master Password for Export',
                          prefixIcon: const Icon(
                            Icons.vpn_key_rounded,
                            size: 20,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureNew
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              size: 20,
                            ),
                            onPressed: () =>
                                setState(() => _obscureNew = !_obscureNew),
                          ),
                          filled: true,
                          fillColor: isDark
                              ? KeyNestPalette.surfaceContainerDark
                              : KeyNestPalette.surfaceContainerLight,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _confirmPasswordController,
                        obscureText: _obscureConfirm,
                        decoration: InputDecoration(
                          labelText: 'Confirm Export Master Password',
                          prefixIcon: const Icon(
                            Icons.check_circle_outline,
                            size: 20,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureConfirm
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              size: 20,
                            ),
                            onPressed: () => setState(
                              () => _obscureConfirm = !_obscureConfirm,
                            ),
                          ),
                          filled: true,
                          fillColor: isDark
                              ? KeyNestPalette.surfaceContainerDark
                              : KeyNestPalette.surfaceContainerLight,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Key File Protection for Export
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark
                              ? KeyNestPalette.surfaceContainerDark
                              : KeyNestPalette.surfaceContainerLight,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: KeyNestKeyFileCreationSection(
                          controller: _keyFileController,
                          getVaultName: () => _selectedFile != null
                              ? KeyNestVaultScope.cleanVaultName(
                                  widget.kdbxBloc,
                                  _selectedFile!,
                                )
                              : 'keynest_export',
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),

              // Bottom Action Buttons
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _handleSubmit,
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              widget.format == KeyNestExportFormat.kdbx
                              ? (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary)
                              : KeyNestPalette.warning,
                          foregroundColor:
                              widget.format == KeyNestExportFormat.kdbx
                              ? (isDark
                                    ? const Color(0xFF00315D)
                                    : Colors.white)
                              : Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: Text(
                          widget.format == KeyNestExportFormat.kdbx
                              ? 'Export KDBX'
                              : widget.format == KeyNestExportFormat.csv
                              ? 'Export CSV'
                              : 'Export JSON',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: widget.format == KeyNestExportFormat.kdbx
                                ? (isDark
                                      ? const Color(0xFF00315D)
                                      : Colors.white)
                                : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      title,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.8,
        color: isDark
            ? KeyNestPalette.textSecondaryDark
            : KeyNestPalette.textSecondaryLight,
      ),
    );
  }

  Widget _buildScopeOption({
    required KeyNestExportScope scope,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = _scope == scope;

    return InkWell(
      onTap: () => setState(() => _scope = scope),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                    .withValues(alpha: isDark ? 0.22 : 0.12)
              : (isDark
                    ? KeyNestPalette.surfaceContainerDark
                    : KeyNestPalette.surfaceContainerLight),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 22,
              color: isSelected
                  ? (isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary)
                  : (isDark ? Colors.white70 : Colors.black54),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                color: isSelected
                    ? (isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary)
                    : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderItem {
  _FolderItem({
    required this.group,
    required this.depth,
    this.vaultName,
  });

  final KdbxGroup group;
  final int depth;
  final String? vaultName;
}
