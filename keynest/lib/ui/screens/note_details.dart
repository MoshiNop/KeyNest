import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_entry.dart'; // ignore: implementation_imports
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/screens/group_list.dart';
import 'package:keynest/ui/widgets/keynest_custom_field_sheet.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:keynest/ui/widgets/keynest_password_history_sheet.dart';
import 'package:keynest/ui/widgets/keynest_popup_menu.dart';
import 'package:keynest/ui/widgets/keynest_totp_tile.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

final _logger = Logger('note_details');

class NoteDetailsScreen extends StatefulWidget {
  const NoteDetailsScreen({
    super.key,
    this.entry,
    this.isEditing = false,
    this.initialFile,
    this.initialGroup,
  });

  static Route<void> route({
    KdbxEntry? entry,
    bool isEditing = false,
    KdbxFile? initialFile,
    KdbxGroup? initialGroup,
  }) => KeyNestPageRoute(
    settings: const RouteSettings(name: '/noteDetails'),
    builder: (context) => NoteDetailsScreen(
      entry: entry,
      isEditing: isEditing,
      initialFile: initialFile,
      initialGroup: initialGroup,
    ),
  );

  final KdbxEntry? entry;
  final bool isEditing;
  final KdbxFile? initialFile;
  final KdbxGroup? initialGroup;

  @override
  State<NoteDetailsScreen> createState() => _NoteDetailsScreenState();
}

class _NoteDetailsScreenState extends State<NoteDetailsScreen> {
  late bool _isEditing;
  bool _isDirty = false;
  bool _showNotes = false;
  final Set<String> _revealedCustomFields = <String>{};

  late TextEditingController _titleController;
  late TextEditingController _bodyController;
  final List<CustomFieldModel> _customFields = [];

  KdbxFile? _selectedFile;
  KdbxGroup? _selectedGroup;
  KdbxEntry? _currentEntry;

  static bool _isInternalMetadataKey(String key) {
    const hidden = {
      'Title',
      'Notes',
      'UserName',
      'Password',
      'URL',
      'RecordType',
      'ItemCategory',
      'KeyNest.ItemType',
      'IsDeleted',
      'CardColorHex',
      'CardFinish',
      'CardNetwork',
      'Cardholder',
      'OTPAuth',
      'is_favorite',
      'IsFavorite',
    };
    return hidden.contains(key);
  }

  @override
  void initState() {
    super.initState();
    _currentEntry = widget.entry;
    _isEditing = widget.isEditing || widget.entry == null;

    _titleController = TextEditingController();
    _bodyController = TextEditingController();

    _titleController.addListener(_onTextChanged);
    _bodyController.addListener(_onTextChanged);

    _populateFromEntry();
  }

  void _onTextChanged() {
    if (!_isDirty && _isEditing) {
      setState(() => _isDirty = true);
    }
  }

  void _populateFromEntry() {
    final entry = _currentEntry;
    _selectedFile = entry?.file ?? widget.initialFile;
    _selectedGroup = entry?.parent ?? widget.initialGroup;

    if (entry != null) {
      _titleController.text = entry.label ?? '';
      _bodyController.text = entry.getString(KdbxKey('Notes'))?.getText() ?? '';

      _customFields.clear();
      for (final s in entry.stringEntries) {
        final k = s.key.key;
        if (!_isInternalMetadataKey(k) &&
            s.value?.getText()?.isNotEmpty == true) {
          final val = s.value!.getText() ?? '';
          final kind = KeyNestCustomFieldSheet.resolveFieldKind(
            entry,
            k,
            value: val,
            isProtected: s.value is ProtectedValue,
          );
          _customFields.add(CustomFieldModel(key: k, value: val, kind: kind));
        }
      }
    } else {
      _titleController.clear();
      _bodyController.clear();
      _customFields.clear();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectedFile == null) {
      try {
        final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
        _selectedFile =
            widget.initialFile ?? kdbxBloc.openedFilesKdbx.firstOrNull;
        _selectedGroup = widget.initialGroup ?? _selectedFile?.body.rootGroup;
      } catch (_) {
        _selectedFile = widget.initialFile;
        _selectedGroup = widget.initialGroup;
      }
    }
  }

  @override
  void dispose() {
    _titleController.removeListener(_onTextChanged);
    _bodyController.removeListener(_onTextChanged);
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _copyToClipboard(String label, String value) {
    if (value.isEmpty) {
      return;
    }
    HapticFeedback.lightImpact();
    final isSensitive =
        label == 'Secure Note' ||
        KeyNestItemTypeHelper.isSensitiveFieldKey(label);
    if (isSensitive) {
      SecurityService.copySensitive(context, value, label: label);
    } else {
      SecurityService.copyNonSensitive(context, value, label: label);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_isDirty) {
      return true;
    }
    final confirm = await DialogUtils.showConfirmDialog(
      context: context,
      params: ConfirmDialogParams(
        title: 'Discard Changes?',
        content: 'You have unsaved changes that will be lost. Discard them?',
        positiveButtonText: 'Discard',
        negativeButtonText: 'Keep Editing',
      ),
    );
    return confirm == true;
  }

  Future<void> _handleBack() async {
    if (_isEditing && _isDirty) {
      final discard = await _confirmDiscard();
      if (!discard || !mounted) {
        return;
      }
    }

    if (!mounted) {
      return;
    }

    if (widget.entry == null) {
      Navigator.of(context).pop();
    } else if (_isEditing) {
      setState(() {
        _isEditing = false;
        _isDirty = false;
        _populateFromEntry();
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _saveNote() async {
    final title = _titleController.text.trim();
    final body = _bodyController.text.trim();

    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Note title is required.'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }

    if (body.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Note content is required.'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }

    final kdbxBloc = context.read<KdbxBloc>();
    final isNew = _currentEntry == null;

    final entry =
        _currentEntry ??
        kdbxBloc.createEntry(
          file: _selectedFile,
          group: _selectedGroup,
        );

    // If existing entry, preserve complete historical snapshot
    if (!isNew && entry.parent != null) {
      final historyClone = entry.cloneInto(entry.parent!, toHistoryEntry: true);
      entry.history.add(historyClone);
    }

    // Move folder if updated
    if (!isNew && _selectedGroup != null && entry.parent != _selectedGroup) {
      entry.file.move(entry, _selectedGroup!);
    }

    entry.setString(KdbxKeyCommon.TITLE, PlainValue(title));
    KeyNestItemTypeHelper.setItemType(entry, KeyNestItemType.note);
    if (entry.getString(KdbxKey('ItemCategory')) == null) {
      entry.setString(KdbxKey('ItemCategory'), PlainValue('Note'));
    }
    entry.setString(
      KdbxKey('Notes'),
      PlainValue(_bodyController.text),
    );

    // Sync custom fields: delete removed
    final currentCustomKeys = _customFields.map((f) => f.key).toSet();
    for (final s in entry.stringEntries.toList()) {
      final k = s.key.key;
      if (!_isInternalMetadataKey(k) && !currentCustomKeys.contains(k)) {
        entry.removeString(s.key);
        entry.customData['FieldType_$k'] = '';
      }
    }

    // Set updated custom fields
    for (final custom in _customFields) {
      final isSensitive =
          custom.kind == CustomFieldKind.hidden ||
          custom.kind == CustomFieldKind.pin ||
          custom.kind == CustomFieldKind.authenticator ||
          KeyNestItemTypeHelper.isSensitiveFieldKey(
            custom.key,
            kind: custom.kind,
          );
      entry.setString(
        KdbxKey(custom.key),
        isSensitive
            ? ProtectedValue.fromString(custom.value)
            : PlainValue(custom.value),
      );
      entry.customData['FieldType_${custom.key}'] = custom.kind.name;
    }

    KeyNestItemTypeHelper.upgradeEntrySensitiveFields(entry);
    entry.times.lastModificationTime.set(DateTime.now().toUtc());

    try {
      await kdbxBloc.saveFile(entry.file);

      if (mounted) {
        _currentEntry = entry;
        _isDirty = false;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('Note saved to encrypted vault'),
              duration: Duration(milliseconds: 1800),
            ),
          );

        if (widget.entry == null) {
          // If this was a newly created note from FAB, pop back or show details
          Navigator.of(context).pop();
        } else {
          setState(() {
            _isEditing = false;
            _populateFromEntry();
          });
        }
      }
    } catch (e, stack) {
      _logger.severe('Failed to save note to encrypted vault', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('Error saving note: $e'),
              backgroundColor: KeyNestPalette.error,
            ),
          );
      }
    }
  }

  Future<void> _attachFile() async {
    final entry = _currentEntry;
    if (entry == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please save the note before adding attachments.'),
        ),
      );
      return;
    }

    try {
      if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
        await FilePickerWritable().openFile((fileInfo, file) async {
          final fileName = fileInfo.fileName ?? p.basename(file.path);
          final bytes = await file.readAsBytes();
          await _attachFileContent(entry, fileName, bytes);
          return fileInfo;
        });
      } else {
        final file = await openFile(acceptedTypeGroups: const []);
        if (file != null) {
          final fileName = p.basename(file.path);
          final bytes = await file.readAsBytes();
          await _attachFileContent(entry, fileName, bytes);
        }
      }
    } catch (e, stack) {
      _logger.warning('Failed to pick attachment', e, stack);
    }
  }

  Future<void> _attachFileContent(
    KdbxEntry entry,
    String fileName,
    Uint8List bytes,
  ) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final attachmentProvider = await kdbxBloc.attachmentProviderForFileSource(
      entry.file,
    );

    await attachmentProvider.attachFile(
      entry: entry,
      fileName: fileName,
      bytes: bytes,
    );
    await kdbxBloc.saveFile(entry.file);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('Attached "$fileName"'),
            duration: const Duration(milliseconds: 1800),
          ),
        );
    }
  }

  Future<KdbxGroup?> _showMoveToGroup(KdbxEntry entry) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final newGroup = (await Navigator.of(context).push(
      GroupListFlat.route(
        {if (entry.parent != null) entry.parent!},
        groupListMode: GroupListMode.singleSelect,
      ),
    ))?.firstOrNull;
    if (newGroup != null && newGroup != entry.parent) {
      if (!mounted) {
        return null;
      }
      final isCrossVault = newGroup.file != entry.file;
      final moved = await KeyNestItemTypeHelper.promptAndMoveOrCopyEntry(
        context: context,
        entry: entry,
        targetGroup: newGroup,
        kdbxBloc: kdbxBloc,
      );
      if (mounted) {
        if (moved && isCrossVault) {
          Navigator.of(context).pop();
        } else {
          setState(() {
            _selectedGroup = newGroup;
          });
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text('Placed in "${newGroup.name.get() ?? 'Folder'}"'),
                duration: const Duration(milliseconds: 2000),
              ),
            );
        }
      }
    }
    return newGroup;
  }

  Future<void> _showDuplicateToGroup(KdbxEntry entry) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final targetGroup = (await Navigator.of(context).push(
      GroupListFlat.route(
        {if (entry.parent != null) entry.parent!},
        groupListMode: GroupListMode.singleSelect,
      ),
    ))?.firstOrNull;
    if (targetGroup != null && mounted) {
      final cloned = await KeyNestItemTypeHelper.copyEntryToGroup(
        sourceEntry: entry,
        targetGroup: targetGroup,
        kdbxBloc: kdbxBloc,
      );
      if (mounted) {
        final targetVaultName = KeyNestVaultScope.cleanVaultName(
          kdbxBloc,
          targetGroup.file,
        );
        final targetFolderName = targetGroup.name.get() ?? 'Folder';
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'Duplicated "${cloned.label ?? 'Note'}" into $targetVaultName » $targetFolderName',
              ),
              duration: const Duration(milliseconds: 2000),
            ),
          );
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final entry = _currentEntry;

    return PopScope(
      canPop: !_isEditing || !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: isDark
            ? KeyNestPalette.bgDark
            : KeyNestPalette.bgLight,
        appBar: _buildAppBar(context, isDark),
        body: _isEditing
            ? _buildEditModeBody(context, isDark, theme)
            : _buildViewModeBody(context, isDark, theme, entry!),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, bool isDark) {
    final entry = _currentEntry;
    final isNew = entry == null;

    if (_isEditing) {
      return AppBar(
        title: Text(
          isNew ? 'New Note' : 'Edit Note',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Cancel',
          onPressed: _handleBack,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: KeyNestActionPillButton(
                tone: KeyNestActionPillTone.primary,
                icon: const Icon(Icons.check_rounded, size: 16),
                label: 'Save',
                onClick: _saveNote,
              ),
            ),
          ),
        ],
      );
    }

    final title = entry?.label?.isNotEmpty == true
        ? entry!.label!
        : 'Untitled Note';

    return AppBar(
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        tooltip: 'Back',
        onPressed: _handleBack,
      ),
      actions: [
        // View -> Edit toggle
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Center(
            child: KeyNestActionPillButton(
              icon: const Icon(Icons.edit_rounded, size: 16),
              label: 'Edit',
              onClick: () {
                setState(() {
                  _isEditing = true;
                  _isDirty = false;
                  _populateFromEntry();
                });
              },
            ),
          ),
        ),
        KeyNestPopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (val) async {
            if (val == 'move' && entry != null) {
              await _showMoveToGroup(entry);
            } else if (val == 'duplicate' && entry != null) {
              await _showDuplicateToGroup(entry);
            } else if (val == 'delete' && entry != null) {
              final kdbxBloc = context.read<KdbxBloc>();
              final navigator = Navigator.of(context);
              final scaffoldMessenger = ScaffoldMessenger.of(context);
              final confirm = await DialogUtils.showConfirmDialog(
                context: context,
                params: ConfirmDialogParams(
                  title: 'Delete Note',
                  content: 'Are you sure you want to delete this note?',
                  positiveButtonText: 'Delete',
                ),
              );
              if (confirm == true && mounted) {
                if (KeyNestItemTypeHelper.isEntryInTrash(entry)) {
                  entry.file.deletePermanently(entry);
                } else {
                  entry.file.deleteEntry(entry);
                }
                KeyNestItemTypeHelper.invalidateCache(entry);
                await kdbxBloc.saveFile(entry.file);
                KeyNestVaultScope.instance.notifyScopeChanged();
                if (mounted) {
                  navigator.pop();
                  scaffoldMessenger.clearSnackBars();
                  scaffoldMessenger.showSnackBar(
                    const SnackBar(
                      content: Text('Note deleted successfully'),
                      duration: Duration(milliseconds: 1800),
                    ),
                  );
                }
              }
            } else if (val == 'history' && entry != null) {
              await KeyNestPasswordHistorySheet.show(context, entry);
              if (mounted) {
                setState(() {});
              }
            }
          },
          itemBuilder: (ctx) => [
            const PopupMenuItem(
              value: 'move',
              child: Row(
                children: [
                  Icon(Icons.drive_file_move_rounded, size: 20),
                  SizedBox(width: 10),
                  Text('Move to Folder'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'duplicate',
              child: Row(
                children: [
                  Icon(Icons.copy_rounded, size: 20),
                  SizedBox(width: 10),
                  Text('Duplicate'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(
                    Icons.delete_outline_rounded,
                    color: KeyNestPalette.error,
                    size: 20,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Delete',
                    style: TextStyle(color: KeyNestPalette.error),
                  ),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'history',
              child: Row(
                children: [
                  const Icon(Icons.history_rounded, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    (entry?.history.isNotEmpty == true)
                        ? 'History (${entry!.history.length})'
                        : 'History',
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildViewModeBody(
    BuildContext context,
    bool isDark,
    ThemeData theme,
    KdbxEntry entry,
  ) {
    final title = entry.label?.isNotEmpty == true
        ? entry.label!
        : 'Untitled Note';
    final isNotesProtected =
        entry.getString(KdbxKey('Notes')) is ProtectedValue;
    final isNotesMasked = isNotesProtected && !_showNotes;
    final body = entry.getString(KdbxKey('Notes'))?.getText() ?? '';
    final folderName = entry.parent?.name.get() ?? 'Root Folder';

    final modifiedTime = entry.times.lastModificationTime.get();
    final formattedDate = modifiedTime != null
        ? DateFormat('MMMM d, y • h:mm a').format(modifiedTime)
        : null;

    final customFields = entry.stringEntries
        .where(
          (e) =>
              !_isInternalMetadataKey(e.key.key) &&
              e.value?.getText()?.isNotEmpty == true,
        )
        .toList();

    final binaryEntries = entry.binaryEntries.toList();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: KeyNestTokens.contentMaxWidth,
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          children: [
            // Folder Location Header Tile
            Container(
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
                  Icon(
                    Icons.folder_rounded,
                    size: 18,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.lightIcon,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Folder / Group',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight,
                          ),
                        ),
                        Text(
                          folderName,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showMoveToGroup(entry),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      foregroundColor: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                    ),
                    child: const Text(
                      'Move',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Title Display Card (Clickable to Copy)
            Material(
              color: isDark
                  ? KeyNestPalette.cardDark
                  : KeyNestPalette.surfaceLight,
              borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
              child: InkWell(
                onTap: () => _copyToClipboard('Title', title),
                borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      KeyNestShapes.radiusCard,
                    ),
                    border: Border.all(
                      color: isDark
                          ? KeyNestPalette.entryBorderDark
                          : KeyNestPalette.entryBorderLight,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color:
                              (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.lightIcon)
                                  .withValues(alpha: isDark ? 0.20 : 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.sticky_note_2_rounded,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Title',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? KeyNestPalette.textSecondaryDark
                                    : KeyNestPalette.textSecondaryLight,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: isDark
                                    ? KeyNestPalette.textPrimaryDark
                                    : KeyNestPalette.textPrimaryLight,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Note Content Area (Clickable to Copy)
            Text(
              'Note Content',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: isDark
                    ? KeyNestPalette.textPrimaryDark
                    : KeyNestPalette.textPrimaryLight,
              ),
            ),
            const SizedBox(height: 8),

            Material(
              color: isDark
                  ? KeyNestPalette.cardDark
                  : KeyNestPalette.surfaceLight,
              borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
              child: InkWell(
                onTap: body.isNotEmpty
                    ? () => _copyToClipboard('Note content', body)
                    : null,
                borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  constraints: const BoxConstraints(minHeight: 180),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      KeyNestShapes.radiusCard,
                    ),
                    border: Border.all(
                      color: isDark
                          ? KeyNestPalette.entryBorderDark
                          : KeyNestPalette.entryBorderLight,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isNotesMasked
                                ? 'Protected note (tap eye to reveal)'
                                : 'Tap anywhere to copy note',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark.withValues(
                                      alpha: 0.7,
                                    )
                                  : KeyNestPalette.textSecondaryLight
                                        .withValues(alpha: 0.7),
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isNotesProtected)
                                IconButton(
                                  icon: Icon(
                                    isNotesMasked
                                        ? Icons.visibility_off_rounded
                                        : Icons.visibility_rounded,
                                    size: 18,
                                    color: isDark
                                        ? KeyNestPalette.textSecondaryDark
                                        : KeyNestPalette.textSecondaryLight,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  tooltip: isNotesMasked
                                      ? 'Reveal note'
                                      : 'Hide note',
                                  onPressed: () =>
                                      setState(() => _showNotes = !_showNotes),
                                ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        isNotesMasked
                            ? '••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••'
                            : (body.isNotEmpty ? body : 'This note is empty.'),
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          letterSpacing: isNotesMasked ? 2.0 : 0,
                          color: body.isNotEmpty
                              ? (isDark
                                    ? KeyNestPalette.textPrimaryDark
                                    : KeyNestPalette.textPrimaryLight)
                              : (isDark
                                    ? KeyNestPalette.textSecondaryDark
                                    : KeyNestPalette.textSecondaryLight),
                        ),
                        onTap: () => _copyToClipboard('Note content', body),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Tags Section
            if ((entry.getString(KdbxKey('Tags'))?.getText()?.trim().isNotEmpty == true) ||
                (entry.tags.get()?.trim().isNotEmpty == true)) ...[
              const SizedBox(height: 16),
              Text(
                'Tags',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  final tagsStr = (entry.getString(KdbxKey('Tags'))?.getText()?.trim().isNotEmpty == true)
                      ? entry.getString(KdbxKey('Tags'))!.getText()!.trim()
                      : entry.tags.get()!.trim();
                  final tagList = tagsStr
                      .split(RegExp(r'[;,]'))
                      .map((t) => t.trim())
                      .where((t) => t.isNotEmpty)
                      .toList();
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? KeyNestPalette.cardDark
                          : KeyNestPalette.surfaceLight,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? KeyNestPalette.entryBorderDark
                            : KeyNestPalette.entryBorderLight,
                      ),
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Icon(
                          Icons.tag_rounded,
                          size: 18,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        ),
                        ...tagList.map(
                          (tag) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                  .withValues(alpha: isDark ? 0.20 : 0.12),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary)
                                    .withValues(alpha: 0.35),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],

            // Custom Fields Section
            if (customFields.where((f) => f.key.key != 'Tags').isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Custom Fields',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 8),
              ...customFields.where((f) => f.key.key != 'Tags').map((field) {
                final fieldKey = field.key.key;
                final fieldValue = field.value?.getText() ?? '';
                final isProtected = field.value is ProtectedValue;
                final kind = KeyNestCustomFieldSheet.resolveFieldKind(
                  entry,
                  fieldKey,
                  value: fieldValue,
                  isProtected: isProtected,
                );
                final isRevealed = _revealedCustomFields.contains(fieldKey);
                final isMasked =
                    (kind == CustomFieldKind.hidden ||
                        kind == CustomFieldKind.pin ||
                        kind == CustomFieldKind.authenticator ||
                        isProtected) &&
                    !isRevealed;

                final typeItem = KeyNestCustomFieldSheet.fieldTypes.firstWhere(
                  (t) => t.kind == kind,
                  orElse: () => KeyNestCustomFieldSheet.fieldTypes.first,
                );

                if (kind == CustomFieldKind.authenticator) {
                  final authLabel = fieldKey.toLowerCase() == 'authenticator'
                      ? 'Authenticator (2FA)'
                      : '$fieldKey (Authenticator)';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: KeyNestTotpTile(
                      entry: entry,
                      secret: fieldValue,
                      label: authLabel,
                      isMasked: isMasked,
                      onToggleMask: () {
                        setState(() {
                          if (isRevealed) {
                            _revealedCustomFields.remove(fieldKey);
                          } else {
                            _revealedCustomFields.add(fieldKey);
                          }
                        });
                      },
                    ),
                  );
                }

                String displayVal;
                if (isMasked) {
                  displayVal = kind == CustomFieldKind.pin
                      ? '••••'
                      : '••••••••••••';
                } else {
                  displayVal = fieldValue;
                }

                if (kind == CustomFieldKind.yesNo) {
                  final isTrue =
                      KeyNestCustomFieldSheet.isTruthy(fieldValue);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: isDark
                          ? KeyNestPalette.cardDark
                          : KeyNestPalette.surfaceLight,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        onTap: () => _copyToClipboard(
                          fieldKey,
                          isTrue ? 'Yes' : 'No',
                        ),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isDark
                                  ? KeyNestPalette.entryBorderDark
                                  : KeyNestPalette.entryBorderLight,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                typeItem.icon,
                                size: 18,
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$fieldKey (${typeItem.title})',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isDark
                                            ? KeyNestPalette
                                                .textSecondaryDark
                                            : KeyNestPalette
                                                .textSecondaryLight,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      isTrue
                                          ? 'On (Enabled)'
                                          : 'Off (Disabled)',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? KeyNestPalette
                                                .textPrimaryDark
                                            : KeyNestPalette
                                                .textPrimaryLight,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IgnorePointer(
                                child: Switch.adaptive(
                                  value: isTrue,
                                  activeThumbColor: isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary,
                                  onChanged: null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: isDark
                        ? KeyNestPalette.cardDark
                        : KeyNestPalette.surfaceLight,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: () => _copyToClipboard(fieldKey, fieldValue),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? KeyNestPalette.entryBorderDark
                                : KeyNestPalette.entryBorderLight,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              KeyNestCustomFieldSheet.getIconForField(
                                fieldKey,
                                kind: kind,
                                fallback: typeItem.icon,
                              ),
                              size: 18,
                              color: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.lightIcon,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$fieldKey (${typeItem.title})',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? KeyNestPalette.textSecondaryDark
                                          : KeyNestPalette.textSecondaryLight,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    displayVal,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: isMasked ? 2.0 : 0,
                                      fontFamily: kind == CustomFieldKind.pin
                                          ? 'monospace'
                                          : null,
                                      color: isDark
                                          ? KeyNestPalette.textPrimaryDark
                                          : KeyNestPalette.textPrimaryLight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isProtected ||
                                kind == CustomFieldKind.hidden ||
                                kind == CustomFieldKind.pin ||
                                kind == CustomFieldKind.authenticator)
                              IconButton(
                                icon: Icon(
                                  isMasked
                                      ? Icons.visibility_off_rounded
                                      : Icons.visibility_rounded,
                                  size: 18,
                                  color: isDark
                                      ? KeyNestPalette.textSecondaryDark
                                      : KeyNestPalette.textSecondaryLight,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                constraints: const BoxConstraints(),
                                tooltip: isMasked
                                    ? 'Reveal field'
                                    : 'Hide field',
                                onPressed: () {
                                  setState(() {
                                    if (isRevealed) {
                                      _revealedCustomFields.remove(fieldKey);
                                    } else {
                                      _revealedCustomFields.add(fieldKey);
                                    }
                                  });
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],

            // Binary Attachments Section
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  binaryEntries.isNotEmpty
                      ? 'Attachments (${binaryEntries.length})'
                      : 'Attachments',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                  ),
                ),
                TextButton.icon(
                  onPressed: _attachFile,
                  icon: const Icon(Icons.attach_file_rounded, size: 18),
                  label: const Text(
                    'Add File',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (binaryEntries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No attachments yet.',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
              )
            else
              ...binaryEntries.map((attachment) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: isDark
                        ? KeyNestPalette.cardDark
                        : KeyNestPalette.surfaceLight,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: () async {
                        await showModalBottomSheet<void>(
                          context: context,
                          builder: (ctx) => AttachmentBottomSheet(
                            entry: entry,
                            attachment: attachment,
                          ),
                        );
                        if (mounted) {
                          setState(() {});
                        }
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? KeyNestPalette.entryBorderDark
                                : KeyNestPalette.entryBorderLight,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.attach_file_rounded,
                              color: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.lightIcon,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    attachment.key.key,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                      color: isDark
                                          ? KeyNestPalette.textPrimaryDark
                                          : KeyNestPalette.textPrimaryLight,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _formatBytes(attachment.value.value.length),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? KeyNestPalette.textSecondaryDark
                                          : KeyNestPalette.textSecondaryLight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.more_horiz_rounded, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),

            if (formattedDate != null) ...[
              const SizedBox(height: 28),
              Center(
                child: Text(
                  'Last modified: $formattedDate',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark.withValues(
                            alpha: 0.6,
                          )
                        : KeyNestPalette.textSecondaryLight.withValues(
                            alpha: 0.6,
                          ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEditModeBody(
    BuildContext context,
    bool isDark,
    ThemeData theme,
  ) {
    final entry = _currentEntry;
    final binaryEntries = entry?.binaryEntries.toList() ?? [];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: KeyNestTokens.contentMaxWidth,
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            // Vault & Group picker tile
            if (_selectedFile != null)
              KeyNestDestinationTile(
                file: _selectedFile!,
                group: _selectedGroup,
                onChangeDestination: () async {
                  final dest = await KeyNestDestinationPickerSheet.show(
                    context,
                    initialFile: _selectedFile,
                    initialGroup: _selectedGroup,
                  );
                  if (dest != null && mounted) {
                    setState(() {
                      _selectedFile = dest.file;
                      _selectedGroup = dest.group;
                      _isDirty = true;
                    });
                  }
                },
              ),
            const SizedBox(height: 16),

            // Title Input Field
            Text(
              'Note Title',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _titleController,
              decoration: InputDecoration(
                hintText: 'e.g. Wi-Fi Passwords, Recovery Codes',
                filled: true,
                fillColor: isDark
                    ? KeyNestPalette.cardDark
                    : KeyNestPalette.surfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: isDark
                        ? KeyNestPalette.entryBorderDark
                        : KeyNestPalette.entryBorderLight,
                  ),
                ),
                prefixIcon: Icon(
                  Icons.title_rounded,
                  color: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.lightIcon,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Note Body Input Field
            Text(
              'Note Content',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _bodyController,
              minLines: 8,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: 'Type your secure note here...',
                filled: true,
                fillColor: isDark
                    ? KeyNestPalette.cardDark
                    : KeyNestPalette.surfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: isDark
                        ? KeyNestPalette.cardBorderDark
                        : KeyNestPalette.cardBorderLight,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Custom Fields
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Custom Fields',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final existingKeys = _customFields
                        .map((f) => f.key)
                        .toSet();
                    final field = await KeyNestCustomFieldSheet.promptAddField(
                      context,
                      existingKeys: existingKeys,
                    );
                    if (field != null && mounted) {
                      setState(() {
                        _customFields.add(field);
                        _isDirty = true;
                      });
                    }
                  },
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text(
                    'Add Field',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (_customFields.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No custom fields added yet.',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
              )
            else
              ..._customFields.asMap().entries.map((item) {
                final idx = item.key;
                final field = item.value;
                final typeItem = KeyNestCustomFieldSheet.fieldTypes.firstWhere(
                  (t) => t.kind == field.kind,
                  orElse: () => KeyNestCustomFieldSheet.fieldTypes.first,
                );

                final fieldIcon = KeyNestCustomFieldSheet.getIconForField(
                  field.key,
                  kind: field.kind,
                  fallback: typeItem.icon,
                );

                if (field.kind == CustomFieldKind.yesNo) {
                  final isTrue =
                      KeyNestCustomFieldSheet.isTruthy(field.value);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: isDark
                          ? KeyNestPalette.cardDark
                          : KeyNestPalette.surfaceLight,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          final updated =
                              await KeyNestCustomFieldSheet.promptAddField(
                            context,
                            existing: field,
                          );
                          if (updated != null && mounted) {
                            setState(() {
                              _customFields[idx] = updated;
                              _isDirty = true;
                            });
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isDark
                                  ? KeyNestPalette.cardBorderDark
                                  : KeyNestPalette.cardBorderLight,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                fieldIcon,
                                size: 18,
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${field.key} (${typeItem.title})',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isDark
                                            ? KeyNestPalette.textSecondaryDark
                                            : KeyNestPalette.textSecondaryLight,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      isTrue ? 'On (Enabled)' : 'Off (Disabled)',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? KeyNestPalette.textPrimaryDark
                                            : KeyNestPalette.textPrimaryLight,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch.adaptive(
                                value: isTrue,
                                activeThumbColor: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                                onChanged: (val) {
                                  setState(() {
                                    field.value =
                                        KeyNestCustomFieldSheet.boolToString(
                                      val,
                                      originalValue: field.value,
                                    );
                                    _isDirty = true;
                                  });
                                },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                ),
                                color: KeyNestPalette.error,
                                tooltip: 'Remove field',
                                onPressed: () async {
                                  final confirmed =
                                      await DialogUtils.showConfirmDialog(
                                    context: context,
                                    params: ConfirmDialogParams(
                                      title: 'Delete Field',
                                      content:
                                          'Are you sure you want to delete "${field.key}"?',
                                      positiveButtonText: 'Delete',
                                      negativeButtonText: 'Cancel',
                                    ),
                                  );
                                  if (confirmed == true && mounted) {
                                    setState(() {
                                      _customFields.removeAt(idx);
                                      _isDirty = true;
                                    });
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }

                String displayVal;
                if (field.kind == CustomFieldKind.hidden) {
                  displayVal = '••••••••••••';
                } else if (field.kind == CustomFieldKind.pin) {
                  displayVal = '••••';
                } else {
                  displayVal = field.value;
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: isDark
                        ? KeyNestPalette.cardDark
                        : KeyNestPalette.surfaceLight,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        final updated =
                            await KeyNestCustomFieldSheet.promptAddField(
                          context,
                          existing: field,
                        );
                        if (updated != null && mounted) {
                          setState(() {
                            _customFields[idx] = updated;
                            _isDirty = true;
                          });
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? KeyNestPalette.cardBorderDark
                                : KeyNestPalette.cardBorderLight,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              fieldIcon,
                              size: 18,
                              color: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${field.key} (${typeItem.title})',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? KeyNestPalette.textSecondaryDark
                                          : KeyNestPalette.textSecondaryLight,
                                    ),
                                  ),
                                  Text(
                                    displayVal,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing:
                                          (field.kind == CustomFieldKind.hidden ||
                                                  field.kind == CustomFieldKind.pin)
                                              ? 2.0
                                              : 0,
                                      fontFamily:
                                          field.kind == CustomFieldKind.pin
                                              ? 'monospace'
                                              : null,
                                      color: isDark
                                          ? KeyNestPalette.textPrimaryDark
                                          : KeyNestPalette.textPrimaryLight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                              ),
                              color: KeyNestPalette.error,
                              tooltip: 'Remove field',
                              onPressed: () async {
                                final confirmed =
                                    await DialogUtils.showConfirmDialog(
                                  context: context,
                                  params: ConfirmDialogParams(
                                    title: 'Delete Field',
                                    content:
                                        'Are you sure you want to delete "${field.key}"?',
                                    positiveButtonText: 'Delete',
                                    negativeButtonText: 'Cancel',
                                  ),
                                );
                                if (confirmed == true && mounted) {
                                  setState(() {
                                    _customFields.removeAt(idx);
                                    _isDirty = true;
                                  });
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),

            // Attachments
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  binaryEntries.isNotEmpty
                      ? 'Attachments (${binaryEntries.length})'
                      : 'Attachments',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                  ),
                ),
                TextButton.icon(
                  onPressed: _attachFile,
                  icon: const Icon(Icons.attach_file_rounded, size: 18),
                  label: const Text(
                    'Add File',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (binaryEntries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  entry == null
                      ? 'Save note to attach binary files.'
                      : 'No attachments yet.',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
              )
            else
              ...binaryEntries.map((attachment) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? KeyNestPalette.cardDark
                          : KeyNestPalette.surfaceLight,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? KeyNestPalette.cardBorderDark
                            : KeyNestPalette.cardBorderLight,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.attach_file_rounded,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                attachment.key.key,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: isDark
                                      ? KeyNestPalette.textPrimaryDark
                                      : KeyNestPalette.textPrimaryLight,
                                ),
                              ),
                              Text(
                                _formatBytes(attachment.value.value.length),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark
                                      ? KeyNestPalette.textSecondaryDark
                                      : KeyNestPalette.textSecondaryLight,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                          ),
                          color: KeyNestPalette.error,
                          tooltip: 'Remove attachment',
                          onPressed: () async {
                            final confirm = await DialogUtils.showConfirmDialog(
                              context: context,
                              params: ConfirmDialogParams(
                                title: 'Remove Attachment',
                                content:
                                    'Remove "${attachment.key.key}" from note?',
                                positiveButtonText: 'Remove',
                              ),
                            );
                            if (confirm == true && mounted) {
                              entry!.removeBinary(attachment.key);
                              setState(() => _isDirty = true);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
