import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:provider/provider.dart';

class KeyNestDestination {
  const KeyNestDestination({
    required this.file,
    required this.group,
  });

  final KdbxFile file;
  final KdbxGroup group;
}

class KeyNestDestinationPickerSheet extends StatefulWidget {
  const KeyNestDestinationPickerSheet({
    super.key,
    required this.initialFile,
    required this.initialGroup,
  });

  final KdbxFile initialFile;
  final KdbxGroup initialGroup;

  static Future<KeyNestDestination?> show(
    BuildContext context, {
    KdbxFile? initialFile,
    KdbxGroup? initialGroup,
  }) {
    final bloc = context.read<KdbxBloc>();
    final files = bloc.openedFilesKdbx;
    if (files.isEmpty) {
      return Future.value(null);
    }
    final targetFile = initialFile ?? files.first;
    final targetGroup = initialGroup ?? targetFile.body.rootGroup;

    return showModalBottomSheet<KeyNestDestination>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => KeyNestDestinationPickerSheet(
        initialFile: targetFile,
        initialGroup: targetGroup,
      ),
    );
  }

  @override
  State<KeyNestDestinationPickerSheet> createState() =>
      _KeyNestDestinationPickerSheetState();
}

class _KeyNestDestinationPickerSheetState
    extends State<KeyNestDestinationPickerSheet> {
  late KdbxFile _selectedFile;
  late KdbxGroup _selectedGroup;

  @override
  void initState() {
    super.initState();
    _selectedFile = widget.initialFile;
    _selectedGroup = widget.initialGroup;
  }

  void _onVaultChanged(KdbxFile file) {
    setState(() {
      _selectedFile = file;
      _selectedGroup = file.body.rootGroup;
    });
  }

  Future<void> _createNewFolder(BuildContext context, KdbxGroup parent) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final name = await const SimplePromptDialog(
      title: 'New Folder',
      labelText: 'Folder Name',
    ).show(context);

    if (name != null && name.trim().isNotEmpty && mounted) {
      final newFolder = parent.file.createGroup(
        parent: parent,
        name: name.trim(),
      );
      await kdbxBloc.saveFile(_selectedFile);
      setState(() {
        _selectedGroup = newFolder;
      });
    }
  }

  List<_FolderItem> _flattenFolders(KdbxGroup root, [int depth = 0]) {
    final items = <_FolderItem>[];
    if (!KeyNestItemTypeHelper.isTrashOrRecycleBin(root)) {
      items.add(_FolderItem(group: root, depth: depth));
      final sortedChildren = KeyNestItemTypeHelper.sortGroupsWithTrashLast(
        root.groups,
      );
      for (final child in sortedChildren) {
        if (!KeyNestItemTypeHelper.isTrashOrRecycleBin(child)) {
          items.addAll(_flattenFolders(child, depth + 1));
        }
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;

    final folders = _flattenFolders(_selectedFile.body.rootGroup);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle bar
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

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                              .withValues(alpha: isDark ? 0.20 : 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.drive_file_move_rounded,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Select Save Destination',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Choose the destination vault and folder',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            Flexible(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                shrinkWrap: true,
                children: [
                  // Vault Selector Section: Dynamically lists all available vaults without limit
                  if (openedFiles.isNotEmpty) ...[
                    Text(
                      'DESTINATION VAULT',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...openedFiles.map((f) {
                      final isSelected = f == _selectedFile;
                      final vaultName = KeyNestVaultScope.cleanVaultName(
                        kdbxBloc,
                        f,
                      );
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: isSelected
                              ? (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary)
                                    .withValues(alpha: isDark ? 0.20 : 0.12)
                              : (isDark
                                    ? KeyNestPalette.cardDark
                                    : KeyNestPalette.surfaceContainerLight),
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _onVaultChanged(f),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.shield_rounded,
                                    size: 18,
                                    color: isSelected
                                        ? (isDark
                                              ? KeyNestPalette.primaryDark
                                              : KeyNestPalette.primary)
                                        : (isDark
                                              ? Colors.white54
                                              : Colors.black45),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      vaultName,
                                      style: TextStyle(
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        color: isSelected
                                            ? (isDark
                                                  ? KeyNestPalette.primaryDark
                                                  : KeyNestPalette.primary)
                                            : null,
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
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                  ],

                  // Folder Hierarchy Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'DESTINATION FOLDER',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                          color: isDark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                        ),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(
                          Icons.create_new_folder_rounded,
                          size: 16,
                        ),
                        label: const Text(
                          'New Folder',
                          style: TextStyle(fontSize: 12),
                        ),
                        onPressed: () =>
                            _createNewFolder(context, _selectedGroup),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  ...folders.map((item) {
                    final isSelected = item.group == _selectedGroup;
                    final isRoot = item.group.parent == null;
                    final folderName = isRoot
                        ? 'Root Folder'
                        : (item.group.name.get() ?? 'Folder');

                    return Padding(
                      padding: EdgeInsets.only(
                        left: (item.depth * 18.0).clamp(0.0, 72.0),
                        bottom: 4,
                      ),
                      child: Material(
                        color: isSelected
                            ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                  .withValues(alpha: isDark ? 0.20 : 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            setState(() {
                              _selectedGroup = item.group;
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isRoot
                                      ? Icons.folder_special_rounded
                                      : Icons.folder_rounded,
                                  size: 18,
                                  color: isSelected
                                      ? (isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary)
                                      : (isDark
                                            ? KeyNestPalette.textSecondaryDark
                                            : KeyNestPalette
                                                  .textSecondaryLight),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    folderName,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: isSelected
                                          ? (isDark
                                                ? KeyNestPalette.primaryDark
                                                : KeyNestPalette.primary)
                                          : null,
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Icon(
                                    Icons.check_rounded,
                                    color: isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary,
                                    size: 16,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),

            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                  foregroundColor: isDark
                      ? const Color(0xFF00315D)
                      : Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.check_rounded, size: 20),
                label: const Text(
                  'Confirm Destination',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                onPressed: () {
                  Navigator.of(context).pop(
                    KeyNestDestination(
                      file: _selectedFile,
                      group: _selectedGroup,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderItem {
  _FolderItem({required this.group, required this.depth});
  final KdbxGroup group;
  final int depth;
}

/// A clear and explicit widget displayed at the top of entry creation/editing
/// screens showing exactly which vault and folder this item will be saved in.
class KeyNestDestinationTile extends StatelessWidget {
  const KeyNestDestinationTile({
    super.key,
    required this.file,
    required this.group,
    required this.onChangeDestination,
  });

  final KdbxFile file;
  final KdbxGroup? group;
  final VoidCallback onChangeDestination;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.read<KdbxBloc>();

    final vaultName = KeyNestVaultScope.cleanVaultName(kdbxBloc, file);
    final folderName = (group?.parent == null)
        ? 'Root Folder'
        : (group?.name.get() ?? 'Root Folder');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.surfaceContainerDark
            : KeyNestPalette.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? KeyNestPalette.entryBorderDark
              : KeyNestPalette.entryBorderLight,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color:
                  (isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.lightIcon)
                      .withValues(alpha: isDark ? 0.20 : 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.drive_file_move_rounded,
              size: 18,
              color: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.lightIcon,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'SAVE DESTINATION',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.7,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 2),
                RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13,
                      color: isDark
                          ? KeyNestPalette.textPrimaryDark
                          : KeyNestPalette.textPrimaryLight,
                    ),
                    children: [
                      TextSpan(
                        text: vaultName,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const TextSpan(text: ' • '),
                      TextSpan(
                        text: folderName,
                        style: TextStyle(
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onChangeDestination,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
            ),
            child: const Text(
              'Change',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
