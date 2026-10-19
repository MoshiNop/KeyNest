import 'package:flutter/material.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/storage_exception.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/app_bar_menu.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/screens/group_list.dart';
import 'package:keynest/ui/widgets/icon_selector.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

final _logger = Logger('group_edit');

class GroupEditScreen extends StatefulWidget {
  const GroupEditScreen({super.key, required this.group});

  static MaterialPageRoute<bool> route(KdbxGroup group) =>
      MaterialPageRoute<bool>(
        settings: const RouteSettings(name: '/group_edit/'),
        builder: (_) => GroupEditScreen(group: group),
      );

  final KdbxGroup group;

  @override
  _GroupEditScreenState createState() => _GroupEditScreenState();
}

class _GroupEditScreenState extends State<GroupEditScreen>
    with
        StreamSubscriberMixin<GroupEditScreen>,
        TaskStateMixin<GroupEditScreen>,
        KdbxObjectSavableStateMixin<GroupEditScreen> {
  @override
  final formKey = GlobalKey<FormState>();

  @override
  KdbxFile get file => widget.group.file;

  @override
  Changeable<KdbxNode> get kdbxObject => widget.group;

  late final TextEditingController _nameController;
  late SelectedIcon _selectedIcon;
  bool _isSaving = false;
  bool _hasModified = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.group.name.get() ?? '',
    );
    _nameController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _nameController.text.length,
    );
    _selectedIcon = SelectedIcon.fromObject(widget.group);
    if (widget.group.isDirty) {
      isFormDirty = true;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Future<void> onFileSaved() async {
    if (mounted) {
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              loc.savedFiles(
                1,
                KeyNestVaultScope.cleanVaultName(
                  Provider.of<KdbxBloc>(context, listen: false),
                  file,
                ),
              ),
            ),
            duration: const Duration(milliseconds: 1800),
          ),
        );
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _saveGroup() async {
    if (_isSaving) {
      return;
    }
    final form = formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }
    form.save();
    setState(() => _isSaving = true);

    widget.group.name.set(_nameController.text.trim());
    _selectedIcon.when(
      predefined: (predefined) {
        widget.group.customIcon = null;
        widget.group.icon.set(predefined);
      },
      custom: (custom) {
        widget.group.customIcon = custom;
      },
    );

    final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
    try {
      if (kdbxBloc.fileForKdbxFile(file).fileSource.supportsWrite) {
        await kdbxBloc.saveFile(file);
        await onFileSaved();
      } else {
        if (mounted) {
          final loc = AppLocalizations.of(context);
          await DialogUtils.showSimpleAlertDialog(
            context,
            null,
            loc.databaseDoesNotSupportSaving,
            routeAppend: 'databaseNoSupportSaving',
          );
        }
      }
    } on StorageException catch (e, stackTrace) {
      _logger.warning('Error while saving database.', e, stackTrace);
      if (mounted) {
        final loc = AppLocalizations.of(context);
        await DialogUtils.showErrorDialog(
          context,
          loc.errorWhileSavingTitle,
          loc.errorWhileSavingBody(e),
        );
      }
    } catch (e, stackTrace) {
      _logger.severe('Error while saving database.', e, stackTrace);
      if (mounted) {
        final loc = AppLocalizations.of(context);
        await DialogUtils.showErrorDialog(
          context,
          loc.errorWhileSavingTitle,
          loc.errorWhileSavingBody(e),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final canPopWithoutWarning = !_hasModified && !isDirty && !isFormDirty;

    return PopScope(
      canPop: canPopWithoutWarning,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        final navigator = Navigator.of(context);
        final discard = await DialogUtils.showConfirmDialog(
          context: context,
          params: ConfirmDialogParams(
            title: loc.unsavedChangesWarningTitle,
            content: loc.unsavedChangesWarningBody,
            positiveButtonText: loc.unsavedChangesDiscardActionLabel,
          ),
        );
        if (discard) {
          navigator.pop(false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(loc.editGroupScreenTitle),
          actions: [
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: loc.saveButtonLabel,
              onPressed: _saveGroup,
            ),
            AppBarMenu.createOverflowMenuButton(context),
          ],
        ),
        body: SingleChildScrollView(
          child: SafeArea(
            top: false,
            child: GroupEdit(
              group: widget.group,
              formKey: formKey,
              nameController: _nameController,
              selectedIcon: _selectedIcon,
              onIconChanged: (icon) {
                _selectedIcon = icon;
                _hasModified = true;
                setState(() => isFormDirty = true);
              },
              onChanged: () {
                _hasModified = true;
                if (!isFormDirty) {
                  setState(() => isFormDirty = true);
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}

class GroupEdit extends StatefulWidget {
  const GroupEdit({
    super.key,
    required this.group,
    this.formKey,
    required this.nameController,
    required this.selectedIcon,
    required this.onIconChanged,
    required this.onChanged,
  });

  final KdbxGroup group;
  final GlobalKey<FormState>? formKey;
  final TextEditingController nameController;
  final SelectedIcon selectedIcon;
  final void Function(SelectedIcon icon) onIconChanged;
  final VoidCallback onChanged;

  @override
  _GroupEditState createState() => _GroupEditState();
}

class _GroupEditState extends State<GroupEdit> {
  Iterable<String?> _breadcrumbNames() =>
      widget.group.breadcrumbs.map((e) => e.name.get());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final loc = AppLocalizations.of(context);
    final parentGroup = widget.group.parent;

    return Form(
      key: widget.formKey,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Icon Selector Card
            KeyNestSurfaceCard(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                children: [
                  IconSelectorFormField(
                    initialValue: widget.selectedIcon,
                    onSaved: (icon) {
                      if (icon != null) {
                        widget.onIconChanged(icon);
                      }
                    },
                    onChanged: (icon) {
                      widget.onIconChanged(icon);
                    },
                    kdbxFile: widget.group.file,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Folder Glyph / Icon',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: isDark
                          ? KeyNestTokens.textSecondaryDark
                          : KeyNestTokens.textSecondaryLight,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Group Name Input Card
            KeyNestSurfaceCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loc.editGroupGroupNameLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? KeyNestTokens.textSecondaryDark
                          : KeyNestTokens.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 8),
                  KeyNestTextField(
                    controller: widget.nameController,
                    placeholder: loc.editGroupGroupNameLabel,
                    prefixIcon: Icons.folder_rounded,
                    autofocus: true,
                    onChanged: (value) {
                      widget.onChanged();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Parent Group Selector Card
            if (parentGroup != null)
              KeyNestSurfaceCard(
                onClick: () async {
                  final file = widget.group.file;
                  final newGroupList = await Navigator.of(context).push(
                    GroupListFlat.route(
                      {parentGroup},
                      groupListMode: GroupListMode.singleSelect,
                      rootGroup: file.body.rootGroup,
                    ),
                  );
                  final newGroup = newGroupList?.firstOrNull;
                  if (newGroup != null && newGroup != parentGroup) {
                    // Prevent circular hierarchy
                    if (newGroup == widget.group ||
                        widget.group.getAllGroups().contains(newGroup)) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              loc.deleteGroupErrorBodyContainsGroup,
                            ),
                          ),
                        );
                      }
                      return;
                    }
                    final oldGroup = parentGroup;
                    file.move(widget.group, newGroup);
                    widget.onChanged();
                    setState(() {});
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(
                          SnackBar(
                            content: Text(
                              loc.movedEntryToGroup(
                                newGroup.name.get().toString(),
                              ),
                            ),
                            action: SnackBarAction(
                              label: loc.undoButtonLabel,
                              onPressed: () {
                                file.move(widget.group, oldGroup);
                                widget.onChanged();
                                setState(() {});
                              },
                            ),
                          ),
                        );
                    }
                  }
                },
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    KeyNestCompactIconTile(
                      icon: Icons.account_tree_rounded,
                      tint: isDark
                          ? KeyNestTokens.darkPrimary
                          : KeyNestTokens.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            loc.entryInfoGroup,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: isDark
                                  ? KeyNestTokens.textSecondaryDark
                                  : KeyNestTokens.textSecondaryLight,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _breadcrumbNames().join('  ›  '),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: Colors.grey,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
