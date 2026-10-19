// ignore_for_file: use_build_context_synchronously

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/kdbx/file_source_ui.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/ui/screens/group_edit.dart';
import 'package:keynest/ui/widgets/link_button.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/error_utils.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:keynest/utils/format_utils.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/predefined_icons.dart';
import 'package:keynest/utils/theme_utils.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';

final _logger = Logger('group_list');

class GroupViewModel {
  GroupViewModel(this.group, this.file, this.kdbxBloc);

  final KdbxGroup group;
  final KdbxFile file;
  final KdbxBloc kdbxBloc;

  bool get isRoot => group.parent == null;

  IconDataWrapperBase get icon => group.icon.get() != null
      ? FaIconDataWrapper(
          faIconData: PredefinedIcons.iconForGroup(group.icon.get()!),
        )
      : kdbxBloc.fileForKdbxFile(file).fileSource.displayIcon.iconData;

  String? get nameOrNull =>
      (isRoot
              ? KeyNestVaultScope.cleanVaultName(kdbxBloc, file)
              : group.name.get())
          ?.nullIfBlank();

  String name(AppLocalizations loc) =>
      nameOrNull ?? loc.unnamedGroupPlaceholder;
}

enum GroupListLongPressAction {
  filter,
  delete,
}

class GroupList extends StatelessWidget {
  const GroupList({super.key, this.parent});

  static Route<KdbxGroup> route(KdbxGroup? parent) => MaterialPageRoute(
    settings: RouteSettings(name: '/groupList${parent == null ? '' : 'Child'}'),
    builder: (context) => GroupList(
      parent: parent,
    ),
  );

  final KdbxGroup? parent;

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = Provider.of<KdbxBloc>(context);
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(parent == null ? loc.files : parent!.name.get()!),
        actions: parent == null
            ? null
            : <Widget>[
                IconButton(
                  icon: const FaIcon(FontAwesomeIcons.folderPlus),
                  onPressed: () async {
                    final newName = await SimplePromptDialog(
                      title: loc.newGroupDialogTitle,
                      labelText: loc.newGroupDialogInputLabel,
                    ).show(context);
                    if (newName != null) {
                      parent!.file.createGroup(parent: parent!, name: newName);
                    }
                  },
                ),
              ],
      ),
      body: StreamBuilder<ChangeEvent<KdbxNode>>(
        stream: parent?.changes,
        builder: (context, snapshot) {
          _logger.finer('snapshot: $snapshot ${parent?.groups.length}');
          final rootGroups = _createViewModel(kdbxBloc);
          return ListView.builder(
            itemCount: rootGroups.length,
            itemBuilder: (context, index) {
              final group = rootGroups[index];
              return ListTile(
                leading: group.icon.widget(),
                title: Text(group.name(loc)),
                onTap: () async {
                  final result = await Navigator.of(
                    context,
                  ).push(GroupList.route(group.group));
                  if (result != null) {
                    Navigator.of(context).pop(result);
                  }
                },
                onLongPress: () async {
                  final action = await showDialog<GroupListLongPressAction>(
                    context: context,
                    builder: (context) => SimpleDialog(
                      title: Text(group.name(loc)),
                      children: <Widget>[
                        SimpleDialogOption(
                          onPressed: () => Navigator.of(
                            context,
                          ).pop(GroupListLongPressAction.filter),
                          child: ListTile(
                            leading: const FaIcon(FontAwesomeIcons.filter),
                            title: Text(loc.groupActionShowPasswords),
                          ),
                        ),
                        SimpleDialogOption(
                          onPressed: () => Navigator.of(
                            context,
                          ).pop(GroupListLongPressAction.delete),
                          child: ListTile(
                            leading: const Icon(Icons.delete),
                            title: Text(loc.groupActionDelete),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (action == null) {
                    return;
                  }
                  switch (action) {
                    case GroupListLongPressAction.delete:
                      _logger.fine('We should delete ${group.name(loc)}');
                      final oldParent = group.group.parent;
                      group.file.deleteGroup(group.group);
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(
                          SnackBar(
                            content: Text(loc.successfullyDeletedGroup),
                            duration: const Duration(milliseconds: 2500),
                            action: SnackBarAction(
                              label: loc.undoButtonLabel,
                              onPressed: () {
                                oldParent!.file.move(group.group, oldParent);
                              },
                            ),
                          ),
                        );
                      break;
                    case GroupListLongPressAction.filter:
                      Navigator.of(context).pop(group.group);
                      break;
                  }
                },
              );
            },
          );
        },
      ),
    );
  }

  List<GroupViewModel> _createViewModel(KdbxBloc kdbxBloc) {
    final ret = parent == null
        ? kdbxBloc.openedFilesKdbx
              .map((e) => GroupViewModel(e.body.rootGroup, e, kdbxBloc))
              .toList()
        : parent!.groups
              .map((e) => GroupViewModel(e, e.file, kdbxBloc))
              .toList();
    ret.sort((a, b) {
      final aTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(a.group);
      final bTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(b.group);
      if (aTrash != bTrash) {
        return aTrash ? 1 : -1;
      }
      return compareStringsIgnoreCase(a.nameOrNull, b.nameOrNull);
    });
    return ret;
  }
}

class _GroupViewModel {
  _GroupViewModel(
    this.kdbxBloc,
    this.file,
    this.group,
    this.level, {
    required this.isRecycleBin,
    required this.inRecycleBin,
  });

  final KdbxBloc kdbxBloc;
  final KdbxOpenedFile file;
  final KdbxGroup group;
  final int level;
  final bool isRecycleBin;
  final bool inRecycleBin;

  bool get isOrInRecycleBin => isRecycleBin || inRecycleBin;

  bool get isRoot => group.parent == null;

  IconDataWrapperBase get icon => group.icon.get() != null
      ? .faIconData(PredefinedIcons.iconForGroup(group.icon.get()!))
      : file.fileSource.displayIcon.iconData;

  String? get nameOrNull =>
      (isRoot ? file.fileSource.displayName : group.name.get())?.nullIfBlank();

  String name(AppLocalizations loc) =>
      nameOrNull ?? loc.unnamedGroupPlaceholder;

  Color? get color => file.openedFile.color;

  @override
  bool operator ==(Object other) {
    return other is _GroupViewModel && other.group == group;
  }

  @override
  int get hashCode => group.hashCode;

  @override
  String toString() {
    return group.toString();
  }
}

enum GroupListMode {
  multiSelectForFilter,
  singleSelect,
  manage,
}

extension on GroupListMode {
  bool get isSelection =>
      this == GroupListMode.multiSelectForFilter ||
      this == GroupListMode.singleSelect;
}

class GroupListFlat extends StatelessWidget {
  const GroupListFlat({
    super.key,
    this.initialSelection,
    this.groupListMode = GroupListMode.multiSelectForFilter,
    this.rootGroup,
  });

  static MaterialPageRoute<Set<KdbxGroup>> route(
    Set<KdbxGroup> selection, {
    GroupListMode groupListMode = GroupListMode.multiSelectForFilter,
    KdbxGroup? rootGroup,
  }) => MaterialPageRoute<Set<KdbxGroup>>(
    settings: const RouteSettings(name: '/group_list_flat/}'),
    builder: (_) => GroupListFlat(
      initialSelection: selection,
      groupListMode: groupListMode,
      rootGroup: rootGroup,
    ),
  );

  /// if defined only groups within this group will be shown,
  /// otherwise all groups in all files are shown.
  final KdbxGroup? rootGroup;
  final Set<KdbxGroup>? initialSelection;
  final GroupListMode groupListMode;

  @override
  Widget build(BuildContext context) {
    return GroupListBuilder(
      rootGroup: rootGroup,
      builder: (context, groups) {
        return GroupListFlatContent(
          groups: groups,
          initialSelection: initialSelection ?? {},
          groupListMode: groupListMode,
          rootGroup: rootGroup,
        );
      },
    );
  }
}

class GroupListBuilder extends StatelessWidget {
  const GroupListBuilder({super.key, this.rootGroup, required this.builder});

  /// if defined only groups within this group will be shown,
  /// otherwise all groups in all files are shown.
  final KdbxGroup? rootGroup;
  final Widget Function(BuildContext context, List<_GroupViewModel> groups)
  builder;

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = Provider.of<KdbxBloc>(context);
    final file = rootGroup == null
        ? null
        : kdbxBloc.fileForKdbxFile(rootGroup!.file);

    final streams = kdbxBloc.openedFilesKdbx.map(
      (file) => file.dirtyObjectsChanged,
    );
    return StreamBuilder<bool>(
      stream: Rx.merge(streams).map((x) => true),
      builder: (context, snapshot) {
        _logger.info('Rebuilding flat group list.');
        final groups = createViewModel(kdbxBloc, file, rootGroup, 0);
        return builder(context, groups);
      },
    );
  }

  static List<_GroupViewModel> createViewModel(
    KdbxBloc kdbxBloc,
    KdbxOpenedFile? file,
    KdbxGroup? group,
    int depth, {
    bool inRecycleBin = false,
  }) {
    if (file == null || group == null) {
      return kdbxBloc.openedFiles.values
          .expand(
            (file) => createViewModel(
              kdbxBloc,
              file,
              file.kdbxFile.body.rootGroup,
              depth,
            ),
          )
          .toList();
    } else {
      final isRecycleBin = group.file.recycleBin == group;
      final groups = group.groups
          .map(
            (g) => createViewModel(
              kdbxBloc,
              file,
              g,
              depth + 1,
              inRecycleBin: inRecycleBin || isRecycleBin,
            ),
          )
          .sorted((aVm, bVm) {
            final a = aVm.first;
            final b = bVm.first;
            final aTrash =
                a.isRecycleBin ||
                KeyNestItemTypeHelper.isTrashOrRecycleBin(a.group);
            final bTrash =
                b.isRecycleBin ||
                KeyNestItemTypeHelper.isTrashOrRecycleBin(b.group);
            // Move recycle bin to the bottom.
            if (aTrash != bTrash) {
              return aTrash ? 1 : -1;
            }
            return compareStringsIgnoreCase(a.nameOrNull, b.nameOrNull);
          })
          .flattened;
      return [
        _GroupViewModel(
          kdbxBloc,
          file,
          group,
          depth,
          isRecycleBin: isRecycleBin,
          inRecycleBin: inRecycleBin,
        ),
        ...groups,
      ];
    }
  }
}

class GroupFilter {
  GroupFilter({
    required this.groups,
    Set<_GroupViewModel>? groupFilter,
    Set<_GroupViewModel>? groupFilterRecursive,
  }) : vmByGroup = Map.fromEntries(groups.map((e) => MapEntry(e.group, e))),
       groupFilter = groupFilter ?? {},
       groupFilterRecursive = groupFilterRecursive ?? {};
  final List<_GroupViewModel> groups;
  final Map<KdbxGroup, _GroupViewModel> vmByGroup;
  final Set<_GroupViewModel> groupFilter;
  final Set<_GroupViewModel> groupFilterRecursive;

  _GroupViewModel _vmByGroup(KdbxGroup group) =>
      vmByGroup[group] ?? throws(StateError('no view model for group $group'));

  void add(_GroupViewModel group) {
    groupFilter.add(group);
    groupFilterRecursive.addAll(
      group.group
          .getAllGroups()
          .map((e) => _vmByGroup(e))
          .where((group) => !group.isOrInRecycleBin),
    );
  }

  void addAll(Iterable<_GroupViewModel> groups) {
    groupFilter.addAll(groups);
    groupFilterRecursive.addAll(
      groups
          .expand((element) => element.group.getAllGroups())
          .map((e) => _vmByGroup(e))
          .where((group) => !group.isOrInRecycleBin),
    );
  }

  void remove(_GroupViewModel group) {
    groupFilter.remove(group);
    KdbxGroup? parent = group.group.parent;
    while (parent != null) {
      final parentVm = vmByGroup[parent];
      if (parentVm != null && groupFilter.contains(parentVm)) {
        groupFilter.remove(parentVm);
        groupFilterRecursive.removeAll(
          parent.getAllGroups().map((e) => _vmByGroup(e)),
        );
      }
      parent = parent.parent;
    }
    groupFilterRecursive.removeAll(
      group.group.getAllGroups().map((e) => _vmByGroup(e)),
    );
  }

  void clear() {
    groupFilter.clear();
    groupFilterRecursive.clear();
  }
}

class GroupListFlatContent extends StatefulWidget {
  const GroupListFlatContent({
    super.key,
    required this.groups,
    required this.initialSelection,
    required this.groupListMode,
    this.rootGroup,
  });

  final Set<KdbxGroup?> initialSelection;
  final List<_GroupViewModel> groups;
  final GroupListMode groupListMode;
  final KdbxGroup? rootGroup;

  @override
  _GroupListFlatContentState createState() => _GroupListFlatContentState();
}

class _GroupListFlatContentState extends State<GroupListFlatContent> {
  late GroupFilter _groupFilter;
  late List<_GroupViewModel> _groups;

  @override
  void initState() {
    super.initState();
    _groups = List.of(widget.groups);
    _initSelection();
  }

  @override
  void didUpdateWidget(GroupListFlatContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groups != widget.groups) {
      _groups = List.of(widget.groups);
      _initSelection();
    }
  }

  void _initSelection() {
    _groupFilter = GroupFilter(
      groups: _groups,
      groupFilter: {},
      groupFilterRecursive: {},
    );
    _groupFilter.addAll(
      _groups.where(
        (element) => widget.initialSelection.contains(element.group),
      ),
    );
  }

  void _refreshGroups() {
    final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
    final file = widget.rootGroup == null
        ? null
        : kdbxBloc.fileForKdbxFile(widget.rootGroup!.file);
    final freshGroups = GroupListBuilder.createViewModel(
      kdbxBloc,
      file,
      widget.rootGroup,
      0,
    );
    setState(() {
      _groups = freshGroups;
      final selectedGroups = _groupFilter.groupFilter
          .map((e) => e.group)
          .toSet();
      _groupFilter = GroupFilter(groups: _groups);
      _groupFilter.addAll(
        _groups.where((e) => selectedGroups.contains(e.group)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = Provider.of<KdbxBloc>(context);
    final isDirty = kdbxBloc.openedFiles.entries.any(
      (element) =>
          element.key.supportsWrite &&
          element.value.kdbxFile.dirtyObjects.isNotEmpty,
    );
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            Icons.close,
            semanticLabel: loc.close,
          ),
          tooltip: loc.close,
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
        title: Text(
          widget.groupListMode == GroupListMode.multiSelectForFilter
              ? loc.groupListFilterAppbarTitle
              : loc.groupListAppBarTitle,
        ),
        actions: <Widget>[
          ...?!isDirty
              ? null
              : [
                  Builder(
                    builder: (context) => IconButton(
                      icon: Icon(
                        Icons.save,
                        semanticLabel: loc.saveButtonLabel,
                      ),
                      tooltip: loc.saveButtonLabel,
                      onPressed: () async {
                        final scaffold = ScaffoldMessenger.of(context);
                        final savedFiles = <String>[];
                        for (final entry in kdbxBloc.openedFiles.entries) {
                          if (entry.key.supportsWrite &&
                              entry.value.kdbxFile.dirtyObjects.isNotEmpty) {
                            await kdbxBloc.saveFile(entry.value.kdbxFile);
                            savedFiles.add(entry.key.displayName);
                          }
                        }
                        scaffold
                          ..clearSnackBars()
                          ..showSnackBar(
                            SnackBar(
                              content: Text(
                                loc.savedFiles(
                                  savedFiles.length,
                                  savedFiles.join(Nls.COMMA_SPACE),
                                ),
                              ),
                              duration: const Duration(milliseconds: 1800),
                            ),
                          );
                      },
                    ),
                  ),
                ],
          ...?widget.groupListMode.isSelection
              ? [
                  IconButton(
                    icon: Icon(
                      Icons.check,
                      semanticLabel: loc.selectItem,
                    ),
                    onPressed: () {
                      _popResult();
                    },
                  ),
                ]
              : null,
        ],
      ),
      body: GroupListFlatList(
        groupFilter: _groupFilter,
        groups: _groups,
        groupListMode: widget.groupListMode,
        onRefresh: _refreshGroups,
        onChanged: (group, value) async {
          switch (widget.groupListMode) {
            case GroupListMode.multiSelectForFilter:
              if (value) {
                _groupFilter.add(group);
              } else {
                _groupFilter.remove(group);
              }
              break;
            case GroupListMode.singleSelect:
              _groupFilter.clear();
              _groupFilter.add(group);
              _popResult();
              break;
            case GroupListMode.manage:
              final saved = await Navigator.of(
                context,
              ).push(GroupEditScreen.route(group.group));
              if (saved == true) {
                _refreshGroups();
              }
              break;
          }
          setState(() {});
        },
        onChangedAll: (bool selected) {
          setState(() {
            if (selected) {
              _groupFilter.addAll(_groups.map((e) => e));
            } else {
              _groupFilter.clear();
            }
          });
        },
      ),
    );
  }

  void _popResult() {
    Navigator.of(
      context,
    ).pop(_groupFilter.groupFilter.map((e) => e.group).toSet());
  }
}

enum GroupAction {
  create,
  edit,
  delete,
  deletePermanently,
}

class GroupListFlatList extends StatelessWidget {
  const GroupListFlatList({
    super.key,
    required this.groupFilter,
    required this.groups,
    required this.groupListMode,
    required this.onChanged,
    required this.onChangedAll,
    this.onRefresh,
  });

  final GroupFilter groupFilter;
  final List<_GroupViewModel>? groups;
  final GroupListMode groupListMode;
  final void Function(_GroupViewModel group, bool selected) onChanged;
  final void Function(bool selected) onChangedAll;
  final VoidCallback? onRefresh;

  bool get _allSelected => groupFilter.groupFilter.length == groups!.length;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final child = Scrollbar(
      child: ListView.builder(
        itemBuilder: (context, index) {
          if (index == 0) {
            return _listHeader(loc);
          }
          final group = groups![index - 1];
          return GroupListTile(
            group: group,
            isSelected: groupFilter.groupFilter.contains(group),
            isSelectedInherited: groupFilter.groupFilterRecursive.contains(
              group,
            ),
            groupListMode: groupListMode,
            onChanged: (value) async {
              onChanged(group, value);
            },
            onLongPress: () async {
              final analytics = context.read<Analytics>();
              final action = await showDialog<GroupAction>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: Text(group.name(loc)),
                  children: <Widget>[
                    if (!group.isOrInRecycleBin) ...[
                      SimpleDialogOption(
                        onPressed: () =>
                            Navigator.of(context).pop(GroupAction.create),
                        child: ListTile(
                          leading: const Icon(Icons.create_new_folder),
                          title: Text(loc.createSubgroup),
                        ),
                      ),
                    ],
                    SimpleDialogOption(
                      onPressed: () =>
                          Navigator.of(context).pop(GroupAction.edit),
                      child: ListTile(
                        leading: const FaIcon(FontAwesomeIcons.penToSquare),
                        title: Text(loc.editAction),
                      ),
                    ),
                    if (!group.isRoot &&
                        !group.isRecycleBin &&
                        !group.inRecycleBin) ...[
                      SimpleDialogOption(
                        onPressed: () =>
                            Navigator.of(context).pop(GroupAction.delete),
                        child: ListTile(
                          leading: const Icon(Icons.delete),
                          title: Text(loc.deleteAction),
                        ),
                      ),
                    ],
                    if (group.inRecycleBin) ...[
                      SimpleDialogOption(
                        onPressed: () => Navigator.of(
                          context,
                        ).pop(GroupAction.deletePermanently),
                        child: ListTile(
                          leading: const Icon(Icons.delete_forever),
                          title: Text(loc.deletePermanentlyAction),
                        ),
                      ),
                    ],
                  ],
                ),
              );
              if (action == null) {
                return;
              }
              switch (action) {
                case GroupAction.create:
                  _logger.fine('Creating folder.');
                  final newGroup = group.file.kdbxFile.createGroup(
                    parent: group.group,
                    name: loc.initialNewGroupName,
                  );
                  final saved = await Navigator.of(
                    context,
                  ).push(GroupEditScreen.route(newGroup));
                  if (saved != true) {
                    group.file.kdbxFile.deletePermanently(newGroup);
                  }
                  analytics.events.trackGroupCreate();
                  onRefresh?.call();
                  break;
                case GroupAction.delete:
                  _logger.fine('We should delete ${group.name(loc)}');
                  // for now only allow deleting of empty groups.
                  if (group.group.groups.isNotEmpty) {
                    analytics.events.trackGroupDelete(
                      GroupDeleteResult.hasSubgroups,
                    );
                    await DialogUtils.showSimpleAlertDialog(
                      context,
                      loc.deleteGroupErrorTitle,
                      loc.deleteGroupErrorBodyContainsGroup,
                      routeAppend: 'deleteGroupError',
                    );
                  } else if (group.group.entries.isNotEmpty) {
                    analytics.events.trackGroupDelete(
                      GroupDeleteResult.hasEntries,
                    );
                    await DialogUtils.showSimpleAlertDialog(
                      context,
                      loc.deleteGroupErrorTitle,
                      loc.deleteGroupErrorBodyContainsEntries,
                      routeAppend: 'deleteGroupError',
                    );
                    return;
                  }
                  final oldParent = group.group.parent;
                  group.file.kdbxFile.deleteGroup(group.group);
                  analytics.events.trackGroupDelete(GroupDeleteResult.deleted);
                  onRefresh?.call();
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(loc.successfullyDeletedGroup),
                        duration: const Duration(milliseconds: 2500),
                        action: SnackBarAction(
                          label: loc.undoButtonLabel,
                          onPressed: () {
                            oldParent!.file.move(group.group, oldParent);
                            analytics.events.trackGroupDelete(
                              GroupDeleteResult.undo,
                            );
                            onRefresh?.call();
                          },
                        ),
                      ),
                    );
                  break;
                case GroupAction.edit:
                  final saved = await Navigator.of(
                    context,
                  ).push(GroupEditScreen.route(group.group));
                  if (saved == true) {
                    onRefresh?.call();
                  }
                  break;
                case GroupAction.deletePermanently:
                  final result = await DialogUtils.showConfirmDialog(
                    context: context,
                    params: ConfirmDialogParams(
                      content: loc.permanentlyDeleteEntryConfirm(
                        group.name(loc),
                      ),
                    ),
                  );
                  if (!result) {
                    analytics.events.trackPermanentlyDeleteGroupCancel();
                    return;
                  }
                  group.group.file.deletePermanently(group.group);
                  analytics.events.trackPermanentlyDeleteGroup();
                  context.showSnackBar(loc.permanentlyDeletedEntrySnackBar);
                  onRefresh?.call();
                  break;
              }
            },
          );
        },
        itemCount: groups!.length + 1,
      ),
    );
    if (groupListMode == GroupListMode.singleSelect) {
      final selected = groupFilter.groupFilter.firstOrNull;
      return RadioGroup(
        onChanged: (value) {
          if (value == null) {
            if (selected != null) {
              onChanged(selected, false);
            }
          } else {
            onChanged(value, true);
          }
        },
        groupValue: selected,
        child: child,
      );
    }
    return child;
  }

  Widget _listHeader(AppLocalizations? loc) {
    if (groupListMode != GroupListMode.multiSelectForFilter) {
      return const SizedBox();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(loc!.groupFilterDescription),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LinkButton(
            onPressed: () {
              onChangedAll(!_allSelected);
            },
            child: _allSelected
                ? Text(loc.groupFilterDeselectAll)
                : Text(loc.groupFilterSelectAll),
          ),
        ),
      ],
    );
  }
}

class GroupFilterFlatList extends StatefulWidget {
  const GroupFilterFlatList({
    super.key,
    required this.initialSelection,
    required this.selectionChanged,
    required this.groups,
  });

  final List<_GroupViewModel> groups;
  final Set<KdbxGroup?> initialSelection;
  final void Function(Set<KdbxGroup> selection) selectionChanged;

  @override
  _GroupFilterFlatListState createState() => _GroupFilterFlatListState();
}

class _GroupFilterFlatListState extends State<GroupFilterFlatList> {
  late GroupFilter _groupFilter;

  @override
  void initState() {
    super.initState();
    _groupFilter = GroupFilter(groups: widget.groups);
    _groupFilter.addAll(
      widget.groups.where(
        (element) => widget.initialSelection.contains(element.group),
      ),
    );
  }

  void _initViewModels() {
    final oldGroupFilter = _groupFilter.groupFilter.map((e) => e.group).toSet();
    _groupFilter = GroupFilter(groups: widget.groups);
    _groupFilter.addAll(
      widget.groups.where(
        (element) => oldGroupFilter.contains(element.group),
      ),
    );
  }

  @override
  void didUpdateWidget(GroupFilterFlatList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _initViewModels();
  }

  @override
  Widget build(BuildContext context) {
    return GroupListFlatList(
      groupFilter: _groupFilter,
      groups: widget.groups,
      groupListMode: GroupListMode.multiSelectForFilter,
      onChanged: (group, value) {
        setState(() {
          if (value) {
            _groupFilter.add(group);
          } else {
            _groupFilter.remove(group);
          }
        });
        widget.selectionChanged(
          _groupFilter.groupFilter.map((e) => e.group).toSet(),
        );
      },
      onChangedAll: (value) {
        _logger.fine('changedAll: $value');
        setState(() {
          if (value) {
            _groupFilter.addAll(widget.groups);
          } else {
            _groupFilter.clear();
          }
        });
        widget.selectionChanged(
          _groupFilter.groupFilter.map((e) => e.group).toSet(),
        );
      },
    );
  }
}

class GroupListTile extends StatelessWidget {
  const GroupListTile({
    super.key,
    required this.group,
    required this.isSelected,
    required this.isSelectedInherited,
    required this.groupListMode,
    required this.onChanged,
    this.onLongPress,
  });

  static const _levelIndent = 16.0;

  final _GroupViewModel group;
  final bool isSelected;
  final bool isSelectedInherited;
  final void Function(bool selected) onChanged;
  final GroupListMode groupListMode;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);

    return InkWell(
      onTap: () {
        if (groupListMode == GroupListMode.multiSelectForFilter) {
          onChanged(!isSelected);
        } else {
          onChanged(true);
        }
      },
      onLongPress: onLongPress,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (group.level > 0)
              ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: group.level * _levelIndent,
                  maxWidth: group.level * _levelIndent,
                  minHeight: 48,
                  maxHeight: double.infinity,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ThemeUtil.iconColor(theme, group.color),
                  ),
                ),
              ),
            ..._buildSelectWidget(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SizedBox(
                width: 28,
                height: 28,
                child: Center(
                  child:
                      group.group.customIcon?.let(
                        (customIcon) => Image.memory(
                          customIcon.data,
                          width: 24,
                          height: 24,
                          fit: BoxFit.contain,
                        ),
                      ) ??
                      group.icon.widget(
                        color: ThemeUtil.iconColor(theme, group.color),
                        size: 24,
                      ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  group.name(loc),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: onLongPress,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSelectWidget() {
    switch (groupListMode) {
      case GroupListMode.multiSelectForFilter:
        return [
          Checkbox(
            value: isSelected || isSelectedInherited,
            onChanged: (value) => onChanged(value ?? false),
          ),
        ];
      case GroupListMode.singleSelect:
        return [
          Radio<_GroupViewModel>(
            value: group,
            // ignore: deprecated_member_use
            groupValue: isSelected ? group : null,
            // ignore: deprecated_member_use
            onChanged: (value) => onChanged(true),
          ),
        ];
      case GroupListMode.manage:
        return [const SizedBox(width: 16)];
    }
  }
}
