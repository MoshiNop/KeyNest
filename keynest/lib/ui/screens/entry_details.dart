// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io' as io;

import 'package:clock/clock.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/storage_exception.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/barcodescan_screen.dart';
import 'package:keynest/ui/screens/entry_totp.dart';
import 'package:keynest/ui/screens/group_list.dart';
import 'package:keynest/ui/screens/hud.dart';
import 'package:keynest/ui/screens/password_generator.dart';
import 'package:keynest/ui/screens/password_list.dart';
import 'package:keynest/ui/widgets/icon_selector.dart';
import 'package:keynest/ui/widgets/keyboard_handler.dart';
import 'package:keynest/ui/widgets/keynest_add_field_sheet.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_category_picker.dart';
import 'package:keynest/ui/widgets/keynest_custom_field_sheet.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:keynest/ui/widgets/keynest_duplicate_warning_sheet.dart';
import 'package:keynest/ui/widgets/keynest_password_history_sheet.dart';
import 'package:keynest/ui/widgets/keynest_popup_menu.dart';
import 'package:keynest/ui/widgets/keynest_totp_tile.dart';
import 'package:keynest/ui/widgets/link_button.dart';
import 'package:keynest/ui/widgets/primary_button.dart';
import 'package:keynest/ui/widgets/shortcut/keynest_intents.dart';
import 'package:keynest/utils/base32utils.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/duplicate_detector.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:keynest/utils/format_utils.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/otpauth.dart';
import 'package:keynest/utils/password_generator.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:open_file/open_file.dart';
import 'package:otp/otp.dart';
import 'package:otpauth_migration/otpauth_migration.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tuple/tuple.dart';

final _logger = Logger('entry_details');

class EntryDetailsScreen extends StatefulWidget {
  const EntryDetailsScreen({
    super.key,
    required this.entry,
    this.isNew = false,
    this.isEditing = false,
  });

  static Route<bool> route({
    required KdbxEntry entry,
    bool isNew = false,
    bool isEditing = false,
  }) => KeyNestPageRoute<bool>(
    settings: const RouteSettings(name: '/entry'),
    builder: (context) => EntryDetailsScreen(
      entry: entry,
      isNew: isNew,
      isEditing: isEditing,
    ),
  );

  final KdbxEntry entry;
  final bool isNew;
  final bool isEditing;

  @override
  _EntryDetailsScreenState createState() => _EntryDetailsScreenState();
}

class _EntrySnapshot {
  _EntrySnapshot({
    required this.strings,
    required this.icon,
    required this.customIcon,
    required this.tags,
    required this.customData,
  });

  factory _EntrySnapshot.capture(KdbxEntry entry) {
    final strings = <KdbxKey, StringValue>{};
    for (final s in entry.stringEntries) {
      if (s.value != null) {
        strings[s.key] = s.value!;
      }
    }
    final customData = <String, String>{};
    for (final cd in entry.customData.entries) {
      customData[cd.key] = cd.value;
    }
    return _EntrySnapshot(
      strings: strings,
      icon: entry.icon.get(),
      customIcon: entry.customIcon,
      tags: entry.tags.get(),
      customData: customData,
    );
  }

  final Map<KdbxKey, StringValue> strings;
  final KdbxIcon? icon;
  final KdbxCustomIcon? customIcon;
  final String? tags;
  final Map<String, String> customData;

  void restore(KdbxEntry entry) {
    final currentKeys = entry.stringEntries.map((e) => e.key).toList();
    for (final k in currentKeys) {
      if (!strings.containsKey(k)) {
        entry.removeString(k);
      }
    }
    for (final e in strings.entries) {
      entry.setString(e.key, e.value);
    }
    if (icon != null) {
      entry.icon.set(icon!);
    }
    entry.customIcon = customIcon;
    if (tags != null) {
      entry.tags.set(tags!);
    } else {
      entry.tags.remove();
    }
    final existingCustomKeys =
        entry.customData.entries.map((e) => e.key).toList();
    for (final k in existingCustomKeys) {
      if (!customData.containsKey(k)) {
        entry.customData[k] = '';
      }
    }
    for (final e in customData.entries) {
      entry.customData[e.key] = e.value;
    }
  }
}

class _EntryDetailsScreenState extends State<EntryDetailsScreen>
    with
        TaskStateMixin<EntryDetailsScreen>,
        StreamSubscriberMixin<EntryDetailsScreen>,
        KdbxObjectSavableStateMixin<EntryDetailsScreen> {
  bool _isSaved = false;
  late bool _isNew;
  late bool _isEditing;
  int _viewVersion = 0;
  _EntrySnapshot? _entrySnapshot;

  @override
  void initState() {
    super.initState();
    _isNew = widget.isNew;
    _isEditing = widget.isNew || widget.isEditing;
    if (_isEditing && !_isNew) {
      _entrySnapshot = _EntrySnapshot.capture(widget.entry);
    }
  }

  void _cancelEditing() {
    final kdbxBloc = context.read<KdbxBloc>();
    setState(() {
      _entrySnapshot?.restore(widget.entry);
      _entrySnapshot = null;
      _isEditing = false;
      isFormDirty = false;
      entryViewModel = EntryViewModel(widget.entry, kdbxBloc);
    });
  }

  @override
  Future<void> onFileSaved() async {
    if (mounted) {
      _isSaved = true;
      _isNew = false;
      _entrySnapshot = null;
      widget.entry.times.lastModificationTime.set(clock.now().toUtc());
      EntryTotpHelper.invalidateCache(widget.entry);
      KeyNestItemTypeHelper.invalidateCache(widget.entry);
      final kdbxBloc = context.read<KdbxBloc>();
      setState(() {
        _viewVersion++;
        _isEditing = false;
        isFormDirty = false;
        entryViewModel = EntryViewModel(widget.entry, kdbxBloc);
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Changes saved'),
            duration: Duration(milliseconds: 1500),
          ),
        );
    }
  }

  bool _isDiscarded = false;

  void _cleanupUnsavedEntry() {
    if (_isDiscarded || _isSaved || !_isNew) {
      return;
    }
    _isDiscarded = true;
    try {
      if (widget.entry.parent != null) {
        widget.entry.file.deletePermanently(widget.entry);
      }
    } catch (e, stack) {
      _logger.warning('Error discarding unsaved new entry', e, stack);
    }
  }

  @override
  void dispose() {
    _cleanupUnsavedEntry();
    super.dispose();
  }

  @override
  KdbxFile get file => widget.entry.file;

  @override
  Changeable<KdbxNode> get kdbxObject => widget.entry;
  @override
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  final entryDetailsKey = GlobalKey<_EntryDetailsState>();
  EntryViewModel? entryViewModel;

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
            entryViewModel = EntryViewModel(entry, kdbxBloc);
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
                'Duplicated "${cloned.label ?? 'Entry'}" into $targetVaultName » $targetFolderName',
              ),
              duration: const Duration(milliseconds: 2000),
            ),
          );
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final kdbxBloc = context.watch<KdbxBloc>();
    if (entryViewModel == null) {
      entryViewModel = EntryViewModel(widget.entry, kdbxBloc);
      handleSubscription(
        widget.entry.file.dirtyObjectsChanged.listen((event) {
          setState(() {
            entryViewModel = EntryViewModel(widget.entry, kdbxBloc);
          });
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = entryViewModel!;
    final entry = widget.entry;
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: BackButton(
          onPressed: () {
            if (_isEditing || (_isNew && !_isSaved)) {
              Navigator.of(context).maybePop();
            } else {
              Navigator.of(context).pop(_isSaved);
            }
          },
        ),
        title: Text(
          entry.label?.isNotEmpty == true
              ? entry.label!
              : (vm.label?.takeUnlessBlank() ?? loc.noTitle),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: isDark
                ? KeyNestPalette.textPrimaryDark
                : KeyNestPalette.textPrimaryLight,
          ),
        ),
        actions: <Widget>[
          if (!_isEditing)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: KeyNestActionPillButton(
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: 'Edit',
                  onClick: () {
                    setState(() {
                      _entrySnapshot = _EntrySnapshot.capture(widget.entry);
                      _isEditing = true;
                    });
                  },
                ),
              ),
            )
          else ...[
            if (!_isNew)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Center(
                  child: KeyNestActionPillButton(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: 'Cancel',
                    onClick: _cancelEditing,
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Center(
                  child: KeyNestActionPillButton(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: 'Cancel',
                    onClick: () {
                      _cleanupUnsavedEntry();
                      Navigator.of(context).pop(false);
                    },
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: KeyNestActionPillButton(
                  tone: KeyNestActionPillTone.primary,
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: 'Save',
                  enabled: saveCallback != null,
                  onClick: () => saveCallback?.call(),
                ),
              ),
            ),
          ],
          KeyNestPopupMenuButton<String>(
            key: const ValueKey('appBarOverflowMenu'),
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (val) async {
              if (val == 'move') {
                await _showMoveToGroup(entry);
              } else if (val == 'duplicate') {
                await _showDuplicateToGroup(entry);
              } else if (val == 'delete') {
                final kdbxBloc = context.read<KdbxBloc>();
                final navigator = Navigator.of(context);
                final scaffoldMessenger = ScaffoldMessenger.of(context);
                final confirm = await DialogUtils.showConfirmDialog(
                  context: context,
                  params: ConfirmDialogParams(
                    title: 'Delete Entry',
                    content: 'Are you sure you want to delete this entry?',
                    positiveButtonText: 'Delete',
                  ),
                );
                if (confirm == true && mounted) {
                  subscriptions.cancelSubscriptions();
                  if (KeyNestItemTypeHelper.isEntryInTrash(entry)) {
                    entry.file.deletePermanently(entry);
                  } else {
                    entry.file.deleteEntry(entry);
                  }
                  await kdbxBloc.saveFile(entry.file);
                  if (mounted) {
                    navigator.pop();
                    scaffoldMessenger.clearSnackBars();
                    scaffoldMessenger.showSnackBar(
                      SnackBar(
                        content: Text(loc.deletedEntry),
                        duration: const Duration(milliseconds: 1800),
                      ),
                    );
                  }
                }
              } else if (val == 'history') {
                await KeyNestPasswordHistorySheet.show(context, entry);
                if (mounted) {
                  setState(() {});
                }
              }
            },
            itemBuilder: (context) => [
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
                      entry.history.isNotEmpty
                          ? 'History (${entry.history.length})'
                          : 'History',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) {
            return;
          }
          final navigator = Navigator.of(context);
          if (isFormDirty) {
            final discard = await DialogUtils.showConfirmDialog(
              context: context,
              params: ConfirmDialogParams(
                title: loc.unsavedChangesWarningTitle,
                content: loc.unsavedChangesWarningBody,
                positiveButtonText: loc.unsavedChangesDiscardActionLabel,
              ),
            );
            if (!discard) {
              return;
            }
          }
          if (_isNew && !_isSaved) {
            _cleanupUnsavedEntry();
            navigator.pop(false);
          } else if (_isEditing) {
            _cancelEditing();
          } else {
            navigator.pop(_isSaved);
          }
        },
        child: _isEditing
            ? Form(
                key: formKey,
                onChanged: () {
                  if (!isFormDirty) {
                    setState(() => isFormDirty = true);
                  }
                },
                child: EntryDetails(
                  key: entryDetailsKey,
                  entry: vm,
                  isNew: _isNew,
                  onSavedPressed: !isDirty && !entry.isDirty
                      ? null
                      : saveCallback,
                ),
              )
            : _EntryViewMode(
                key: ValueKey(
                  '${widget.entry.uuid}-$_viewVersion-${widget.entry.times.lastModificationTime.get()?.millisecondsSinceEpoch ?? 0}',
                ),
                entry: widget.entry,
                commonFields: Provider.of<CommonFields>(context),
                onEdit: () => setState(() {
                  _entrySnapshot = _EntrySnapshot.capture(widget.entry);
                  _isEditing = true;
                }),
                onMoveToGroup: () async {
                  final entryDetails = entryDetailsKey.currentState;
                  if (entryDetails != null) {
                    await entryDetails._showMoveToGroup(loc, vm.entry);
                  } else {
                    final newGroup = (await Navigator.of(context).push(
                      GroupListFlat.route(
                        {if (entry.parent != null) entry.parent!},
                        groupListMode: GroupListMode.singleSelect,
                      ),
                    ))?.firstOrNull;
                    if (newGroup != null && newGroup != entry.parent) {
                      final isCrossVault = newGroup.file != entry.file;
                      final moved =
                          await KeyNestItemTypeHelper.promptAndMoveOrCopyEntry(
                            context: context,
                            entry: entry,
                            targetGroup: newGroup,
                            kdbxBloc: context.read<KdbxBloc>(),
                          );
                      if (mounted) {
                        if (moved && isCrossVault) {
                          Navigator.of(context).pop();
                        } else {
                          setState(() {});
                        }
                      }
                    }
                  }
                },
              ),
      ),
    );
  }
}

mixin KdbxObjectSavableStateMixin<T extends StatefulWidget>
    on State<T>, TaskStateMixin<T>, StreamSubscriberMixin<T> {
  GlobalKey<FormState> get formKey;

  KdbxFile get file;

  bool _isObjectDirty = false;

  bool get isDirty => _isObjectDirty || isFormDirty;
  bool isFormDirty = false;

  Changeable<KdbxNode> get kdbxObject;

  @protected
  Future<void> onFileSaved() async {}

  @override
  void initState() {
    super.initState();
    _registerListener();
  }

  @override
  void didUpdateWidget(T oldWidget) {
    super.didUpdateWidget(oldWidget);
    _registerListener();
  }

  void _registerListener() {
    subscriptions.cancelSubscriptions();
    handleSubscription(
      kdbxObject.changes.listen((change) {
        _logger.finer(
          '_isObjectDirty = ${change.isDirty} (before: $_isObjectDirty / formDirty: $isFormDirty',
        );
        setState(() {
          _isObjectDirty = change.isDirty;
        });
      }),
    );
  }

  @protected
  VoidCallback? get saveCallback => asyncTaskCallback(() async {
    final loc = AppLocalizations.of(context);
    final form = formKey.currentState;
    if (form == null) {
      return;
    }
    if (form.validate()) {
      form.save();
      if (kdbxObject is KdbxEntry) {
        final entry = kdbxObject as KdbxEntry;
        final currentTitle = entry
            .getString(KdbxKeyCommon.TITLE)
            ?.getText()
            ?.trim();
        final recordType = entry.getString(KdbxKey('RecordType'))?.getText();
        if ((currentTitle == null || currentTitle.isEmpty) &&
            recordType != null &&
            recordType.isNotEmpty) {
          entry.setString(KdbxKeyCommon.TITLE, PlainValue(recordType));
        }

        final itemType = KeyNestItemTypeHelper.getItemType(entry);
        if (itemType == KeyNestItemType.login) {
          final title =
              entry.getString(KdbxKeyCommon.TITLE)?.getText()?.trim() ?? '';
          final username =
              entry.getString(KdbxKeyCommon.USER_NAME)?.getText()?.trim() ?? '';
          final email =
              entry.getString(KdbxKey('Email'))?.getText()?.trim() ?? '';

          if (title.isEmpty) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                const SnackBar(
                  content: Text('Title is required.'),
                  backgroundColor: KeyNestPalette.error,
                  duration: Duration(milliseconds: 2500),
                ),
              );
            return;
          }

          if (username.isEmpty && email.isEmpty) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                const SnackBar(
                  content: Text(
                    'At least one of Username or Email is required.',
                  ),
                  backgroundColor: KeyNestPalette.error,
                  duration: Duration(milliseconds: 2500),
                ),
              );
            return;
          }
        }

        // Check for potential duplicate if this is a newly created entry
        if (widget is EntryDetailsScreen &&
            (widget as EntryDetailsScreen).isNew) {
          final dupes = KeyNestDuplicateDetector.findPotentialDuplicates(
            file: file,
            entry: entry,
          );
          if (dupes.isNotEmpty && mounted) {
            final resolution = await KeyNestDuplicateWarningSheet.show(
              context,
              match: dupes.first,
            );
            if (resolution == DuplicateResolutionAction.cancel ||
                resolution == null) {
              return;
            }
            if (resolution == DuplicateResolutionAction.openExisting) {
              final existing = dupes.first.existingEntry;
              entry.file.deletePermanently(entry);
              if (!mounted) {
                return;
              }
              Navigator.of(context).pushReplacement(
                EntryDetailsScreen.route(entry: existing),
              );
              return;
            }
          }
        }
      }
      setState(() => isFormDirty = false);
      final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
      if (kdbxBloc.fileForKdbxFile(file).fileSource.supportsWrite) {
        try {
          if (kdbxObject is KdbxEntry) {
            KeyNestItemTypeHelper.upgradeEntrySensitiveFields(
              kdbxObject as KdbxEntry,
            );
          }
          await kdbxBloc.saveFile(file);
          await onFileSaved();
        } on StorageException catch (e, stackTrace) {
          _logger.warning('Error while saving database.', e, stackTrace);
          await DialogUtils.showErrorDialog(
            context,
            loc.errorWhileSavingTitle,
            loc.errorWhileSavingBody(e),
          );
          return;
        } catch (e, stackTrace) {
          _logger.severe('Error while saving database.', e, stackTrace);
          if (mounted) {
            await DialogUtils.showErrorDialog(
              context,
              loc.errorWhileSavingTitle,
              loc.errorWhileSavingBody(e),
            );
          }
          rethrow;
        }
      } else {
        await DialogUtils.showSimpleAlertDialog(
          context,
          null,
          loc.databaseDoesNotSupportSaving,
          routeAppend: 'databaseNoSupportSaving',
        );
      }
    }
  });
}

enum FieldType {
  string,
  otp,
}

class EntryDetails extends StatefulWidget {
  const EntryDetails({
    super.key,
    required this.entry,
    required this.onSavedPressed,
    this.isNew = false,
  });

  final EntryViewModel entry;
  final VoidCallback? onSavedPressed;
  final bool isNew;

  @override
  _EntryDetailsState createState() => _EntryDetailsState();
}

class _EntryDetailsState extends State<EntryDetails>
    with StreamSubscriberMixin {
  final Set<KdbxKey> _deletedFieldKeys = <KdbxKey>{};
  List<Tuple3<GlobalKey<_EntryFieldState>, KdbxKey, CommonField?>>? _fieldKeys;

  IntentActionRegistration? _shortcutRegistration;

  @override
  void dispose() {
    _shortcutRegistration?.dispose();
    super.dispose();
  }

  void _initShortcutListener(
    KeyboardShortcutEvents events,
    CommonFields commonFields,
  ) {
    _shortcutRegistration?.dispose();
    _shortcutRegistration = events.registerActions({
      CopyPasswordIntent: CallbackAction(
        onInvoke: (_) {
          final context = FocusManager.instance.primaryFocus?.context;
          if (context != null) {
            _logger.fine('context: $context');
            if (context.widget is EditableText) {
              final ctrl = (context.widget as EditableText).controller;
              if (!ctrl.selection.isCollapsed && ctrl.selection.isNormalized) {
                final data = ctrl.selection.textInside(ctrl.text);
                if (data.isNotEmpty) {
                  Clipboard.setData(ClipboardData(text: data));
                  if (mounted) {
                    final loc = AppLocalizations.of(context);
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(loc.copiedToClipboard),
                          duration: const Duration(milliseconds: 1500),
                        ),
                      );
                  }
                  return;
                }
              }
            }

            final entryFieldState = context
                .findAncestorStateOfType<_EntryFieldState>();
            if (entryFieldState != null) {
              entryFieldState.copyValue();
              return;
            }
            if (widget is EditableText) {
              return;
            }
          }

          _copyField([commonFields.password]);
          return null;
        },
      ),
      CopyUsernameIntent: CallbackAction(
        onInvoke: (_) {
          _copyField([commonFields.userName]);
          return null;
        },
      ),
      CopyTotpIntent: CallbackAction(
        onInvoke: (_) {
          _logger.fine('Copying ${commonFields.otpAuth}');
          _copyField([
            commonFields.otpAuth,
            commonFields.otpAuthCompat2,
            commonFields.otpAuthCompat1,
          ]);
          return null;
        },
      ),
      OpenUrlIntent: CallbackAction(
        onInvoke: (_) {
          _fieldStateFor(commonFields.url)?.openUrl();
          return null;
        },
      ),
      CopyUrlIntent: CallbackAction(
        onInvoke: (_) {
          _fieldStateFor(commonFields.url)?.copyValue();
          return null;
        },
      ),
    });
  }

  _EntryFieldState? _fieldStateFor(CommonField commonField) => _fieldKeys!
      .firstWhereOrNull((f) => f.item2 == commonField.key)
      ?.item1
      .currentState;

  Future<bool> _copyField(List<CommonField> commonFields) async {
    for (final commonField in commonFields) {
      if (await _copyFieldValue(commonField)) {
        return true;
      }
    }
    final loc = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(loc.copiedFieldEmpty(commonFields.first.displayName)),
          duration: const Duration(milliseconds: 1800),
        ),
      );
    return false;
  }

  Future<bool> _copyFieldValue(CommonField commonField) async {
    final field = _fieldStateFor(commonField);
    if (field != null) {
      if (await field.copyValue()) {
        return true;
      }
    }
    final entry = widget.entry.entry;
    final value = entry.getString(commonField.key);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (value == null || value.getText() == null) {
      return false;
    }
    final text = value.getText() ?? CharConstants.empty;
    final commonFields = Provider.of<CommonFields>(context, listen: false);
    final isSensitive =
        commonField == commonFields.password ||
        commonField == commonFields.otpAuth ||
        KeyNestItemTypeHelper.isSensitiveFieldKey(commonField.key.key);
    if (isSensitive) {
      await SecurityService.copySensitive(
        context,
        text,
        label: commonField.displayName,
      );
    } else {
      await SecurityService.copyNonSensitive(
        context,
        text,
        label: commonField.displayName,
      );
    }
    return true;
  }

  static bool _isInternalMetadataKey(KdbxKey key) {
    const hidden = {
      'RecordType',
      'ItemCategory',
      'IsDeleted',
      'CardColorHex',
      'CardFinish',
      'CardNetwork',
      'Cardholder',
      'OTPAuth',
    };
    return hidden.contains(key.key);
  }

  void _initFields(CommonFields commonFields) {
    final entry = widget.entry.entry;
    final itemType = KeyNestItemTypeHelper.getItemType(entry);
    final isRecord =
        entry.getString(KdbxKey('ItemCategory'))?.getText() == 'Record' ||
        entry.getString(KdbxKey('RecordType')) != null ||
        itemType == KeyNestItemType.record;
    final isTwoFactor = itemType == KeyNestItemType.twoFactor;

    final nonCommonKeys = entry.stringEntries.where(
      (str) =>
          !commonFields.isCommon(str.key) &&
          !_isInternalMetadataKey(str.key) &&
          !_deletedFieldKeys.contains(str.key),
    );
    final oldKeys = _fieldKeys == null
        ? <KdbxKey, GlobalKey<_EntryFieldState>>{}
        : Map.fromEntries(_fieldKeys!.map((e) => MapEntry(e.item2, e.item1)));

    if (isRecord) {
      final otherCommonFields = commonFields.fields.where(
        (f) =>
            f.key != commonFields.title.key &&
            !_deletedFieldKeys.contains(f.key) &&
            (entry.getString(f.key) != null ||
                (widget.isNew && f.key == commonFields.notes.key)),
      );

      final titleTuple =
          Tuple3<GlobalKey<_EntryFieldState>, KdbxKey, CommonField?>(
            oldKeys[commonFields.title.key] ??
                GlobalKey<_EntryFieldState>(
                  debugLabel: commonFields.title.key.toString(),
                ),
            commonFields.title.key,
            commonFields.title,
          );

      _fieldKeys = [
        titleTuple,
        ...nonCommonKeys.map(
          (f) => Tuple3<GlobalKey<_EntryFieldState>, KdbxKey, CommonField?>(
            oldKeys[f.key] ??
                GlobalKey<_EntryFieldState>(debugLabel: f.key.toString()),
            f.key,
            null,
          ),
        ),
        ...otherCommonFields.map(
          (f) => Tuple3(
            oldKeys[f.key] ??
                GlobalKey<_EntryFieldState>(debugLabel: f.key.toString()),
            f.key,
            f,
          ),
        ),
      ];
    } else if (isTwoFactor) {
      final relevantFields = commonFields.fields.where(
        (f) =>
            !_deletedFieldKeys.contains(f.key) &&
            (f.key == commonFields.title.key ||
                f.key == commonFields.userName.key ||
                f.key == commonFields.otpAuth.key ||
                entry.getString(f.key) != null ||
                (widget.isNew && f.key == commonFields.notes.key)),
      );
      _fieldKeys = [
        ...relevantFields.map(
          (f) => Tuple3<GlobalKey<_EntryFieldState>, KdbxKey, CommonField?>(
            oldKeys[f.key] ??
                GlobalKey<_EntryFieldState>(debugLabel: f.key.toString()),
            f.key,
            f,
          ),
        ),
        ...nonCommonKeys.map(
          (f) => Tuple3<GlobalKey<_EntryFieldState>, KdbxKey, CommonField?>(
            oldKeys[f.key] ??
                GlobalKey<_EntryFieldState>(debugLabel: f.key.toString()),
            f.key,
            null,
          ),
        ),
      ];
    } else {
      _fieldKeys = commonFields.fields
          .where(
            (f) =>
                !_deletedFieldKeys.contains(f.key) &&
                (f.showByDefault ||
                    entry.getString(f.key) != null ||
                    (widget.isNew && f.key == commonFields.notes.key)),
          )
          .map(
            (f) => Tuple3<GlobalKey<_EntryFieldState>, KdbxKey, CommonField?>(
              oldKeys[f.key] ??
                  GlobalKey<_EntryFieldState>(debugLabel: f.key.toString()),
              f.key,
              f,
            ),
          )
          .followedBy(
            nonCommonKeys.map(
              (f) => Tuple3(
                oldKeys[f.key] ??
                    GlobalKey<_EntryFieldState>(debugLabel: f.key.toString()),
                f.key,
                null,
              ),
            ),
          )
          .toList();
    }
    _logger.fine('Listing on changes for ${widget.entry.label}');
    handleSubscription(
      entry.changes.listen((event) {
        _logger.fine('Widget entry changed.');
        setState(() {});
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _logger.info('_EntryDetailsState.didChangeDependencies');
    if (_fieldKeys == null) {
      subscriptions.cancelSubscriptions();
      _initFields(Provider.of<CommonFields>(context));
      _initShortcutListener(
        Provider.of<KeyboardShortcutEvents>(context),
        Provider.of<CommonFields>(context),
      );
    }
  }

  @override
  void didUpdateWidget(EntryDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    _logger.fine('_EntryDetailsState.didUpdateWidget');
    if (oldWidget.entry != widget.entry) {
      _logger.info('_EntryDetailsState: widget.entry changed.');
      _initFields(Provider.of<CommonFields>(context));
    }
  }

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = Provider.of<KdbxBloc>(context);
    final commonFields = Provider.of<CommonFields>(context);
    final vm = widget.entry;
    final entry = widget.entry.entry;
    final formatUtils = Provider.of<FormatUtils>(context);
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);

    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: KeyNestTokens.contentMaxWidth,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: SafeArea(
              top: false,
              left: false,
              child: Column(
                children: <Widget>[
                  KeyNestDestinationTile(
                    file: entry.file,
                    group: entry.parent,
                    onChangeDestination: () async {
                      final dest = await KeyNestDestinationPickerSheet.show(
                        context,
                        initialFile: entry.file,
                        initialGroup: entry.parent,
                      );
                      if (dest != null && mounted) {
                        final kdbxBloc = context.read<KdbxBloc>();
                        if (dest.file != entry.file) {
                          final moved =
                              await KeyNestItemTypeHelper.moveEntryToGroup(
                                sourceEntry: entry,
                                targetGroup: dest.group,
                                kdbxBloc: kdbxBloc,
                              );
                          if (mounted) {
                            Navigator.of(context).pushReplacement(
                              EntryDetailsScreen.route(
                                entry: moved,
                                isEditing: true,
                              ),
                            );
                          }
                        } else {
                          entry.file.move(entry, dest.group);
                          setState(() {});
                        }
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: KeyNestCard(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          EntryIcon(
                            vm: vm,
                            size: 56,
                            fallback: (context) => IconSelectorFormField(
                              initialValue: SelectedIcon.fromObject(entry),
                              onSaved: (icon) {
                                icon?.when(
                                  predefined: (predefined) {
                                    entry.customIcon = null;
                                    entry.icon.set(predefined);
                                  },
                                  custom: (custom) {
                                    entry.customIcon = custom;
                                  },
                                );
                              },
                              kdbxFile: entry.file,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                EntryMetaInfo(
                                  label: loc.entryInfoFile,
                                  value: KeyNestVaultScope.cleanVaultName(
                                    kdbxBloc,
                                    entry.file,
                                  ),
                                ),
                                EntryMetaInfo(
                                  label: loc.entryInfoGroup,
                                  value: vm.groupNames.join(' » '), // NON-NLS
                                  onTap: () async {
                                    await _showMoveToGroup(loc, vm.entry);
                                  },
                                ),
                                EntryMetaInfo(
                                  label: 'Category',
                                  value: KeyNestItemTypeHelper.getCategory(
                                    entry,
                                  ),
                                  onTap: () async {
                                    final currentCat =
                                        KeyNestItemTypeHelper.getCategory(
                                          entry,
                                        );
                                    final selected =
                                        await KeyNestCategoryPicker.show(
                                          context,
                                          selectedCategory: currentCat,
                                          showAllOption: false,
                                        );
                                    if (selected != null &&
                                        selected != currentCat &&
                                        selected != 'All') {
                                      setState(() {
                                        KeyNestItemTypeHelper.setCategory(
                                          entry,
                                          selected,
                                        );
                                        final parentState = context
                                            .findAncestorStateOfType<
                                              KdbxObjectSavableStateMixin
                                            >();
                                        parentState?.isFormDirty = true;
                                      });
                                    }
                                  },
                                ),
                                EntryMetaInfo(
                                  label: loc.entryInfoLastModified,
                                  value: formatUtils.formatDateFull(
                                    vm.entry.times.lastModificationTime.get()!,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  ..._fieldKeys!
                      .map(
                        (f) => EntryField(
                          fieldType: commonFields.isTotp(f.item2)
                              ? FieldType.otp
                              : FieldType.string,
                          key: f.item1,
                          entry: entry,
                          fieldKey: f.item2,
                          commonField: f.item3,
                          onDeleteField: (key) {
                            _deletedFieldKeys.add(key);
                          },
                          onChangedMetadata: () => setState(() {
                            _initFields(
                              Provider.of<CommonFields>(context, listen: false),
                            );
                          }),
                        ),
                      )
                      .expand((el) => [el, const SizedBox(height: 8)]),
                  AddFieldButton(
                    onAddField: (result) async {
                      final key = result.key;
                      _deletedFieldKeys.remove(key);
                      if (entry.getString(key) != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Field "${key.key}" already exists.'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                        return;
                      }
                      final cf = commonFields[key];
                      if (cf == commonFields.otpAuth) {
                        final secret = await _askForTotpSecret(context);
                        if (secret == null) {
                          return;
                        }
                        _logger.finer('Got otp auth: $secret');
                        entry.setString(
                          key,
                          ProtectedValue.fromString(secret.toUri().toString()),
                        );
                      } else {
                        final isSensitive =
                            result.isProtected ||
                            cf?.protect == true ||
                            KeyNestItemTypeHelper.isSensitiveFieldKey(
                              key.key,
                              kind: result.customKind,
                            );
                        final initialVal = result.initialValue ??
                            (result.customKind == CustomFieldKind.yesNo
                                ? 'No'
                                : CharConstants.empty);
                        entry.setString(
                          key,
                          isSensitive
                              ? ProtectedValue.fromString(initialVal)
                              : PlainValue(initialVal),
                        );
                        if (result.customKind != null) {
                          entry.customData['FieldType_${key.key}'] =
                              result.customKind!.name;
                        }
                      }
                      Provider.of<Analytics>(
                        context,
                        listen: false,
                      ).events.trackAddField(key: key.key);
                      _initFields(
                        Provider.of<CommonFields>(context, listen: false),
                      );
                      setState(() {});
                    },
                  ),
                  const Divider(),
                  ...entry.binaryEntries.map((e) {
                    return InkWell(
                      onTap: () async {
                        await showModalBottomSheet<void>(
                          context: context,
                          builder: (context) => AttachmentBottomSheet(
                            entry: entry,
                            attachment: e,
                          ),
                        );
                      },
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 500),
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 8,
                        ),
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.attach_file),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    e.key.key,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    loc.sizeBytes(e.value.value.length),
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  LinkButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: _attachFile,
                    child: Text(loc.entryAddAttachment),
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    icon: const Icon(Icons.save),
                    onPressed: widget.onSavedPressed,
                    child: Text(loc.saveButtonLabel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<KdbxGroup?> _showMoveToGroup(
    AppLocalizations loc,
    KdbxEntry entry, {
    final KdbxGroup? toGroup,
  }) async {
    final newGroup =
        toGroup ??
        (await Navigator.of(context).push(
          GroupListFlat.route(
            {if (entry.parent != null) entry.parent!},
            groupListMode: GroupListMode.singleSelect,
          ),
        ))?.firstOrNull;
    if (newGroup != null) {
      final isCrossVault = newGroup.file != entry.file;
      final moved = await KeyNestItemTypeHelper.promptAndMoveOrCopyEntry(
        context: context,
        entry: entry,
        targetGroup: newGroup,
        kdbxBloc: context.read<KdbxBloc>(),
      );
      if (mounted) {
        if (moved && isCrossVault) {
          Navigator.of(context).pop();
        } else {
          final parentState = context
              .findAncestorStateOfType<KdbxObjectSavableStateMixin>();
          parentState?.isFormDirty = true;
          setState(() {});
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  'Item placed in "${newGroup.name.get() ?? 'Folder'}"',
                ),
                duration: const Duration(milliseconds: 2000),
              ),
            );
        }
      }
    }
    return newGroup;
  }

  Future<void> _attachFile() async {
    if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
      await FilePickerWritable().openFile((fileInfo, file) async {
        final fileName = fileInfo.fileName ?? file.path;
        final bytes = await file.readAsBytes();
        await _attachFileContent(fileName, bytes);
        return fileInfo;
      });
    } else {
      final file = await openFile(acceptedTypeGroups: []);
      if (file != null) {
        final fileName = path.basename(file.path);
        final bytes = await file.readAsBytes();
        await _attachFileContent(fileName, bytes);
      }
    }
  }

  Future<void> _attachFileContent(String fileName, Uint8List bytes) async {
    final analytics = Provider.of<Analytics>(context, listen: false);
    final loc = AppLocalizations.of(context);
    final kdbxBloc = widget.entry.kdbxBloc;

    final attachmentProvider = await kdbxBloc.attachmentProviderForFileSource(
      widget.entry.entry.file,
    );

    if (bytes.lengthInBytes > 10 * 1024) {
      if (!await DialogUtils.showConfirmDialog(
        context: context,
        params: ConfirmDialogParams(
          content: loc.entryAttachmentSizeWarning,
        ),
      )) {
        analytics.events.trackAttachmentAdd(
          AttachmentAddType.canceled,
          path.extension(fileName),
          bytes.lengthInBytes,
        );
        return;
      }
    }
    analytics.events.trackAttachmentAdd(
      AttachmentAddType.success,
      path.extension(fileName),
      bytes.lengthInBytes,
    );
    await attachmentProvider.attachFile(
      entry: widget.entry.entry,
      fileName: fileName,
      bytes: bytes,
    );
  }

  Future<OtpAuth?> _askForTotpSecret(BuildContext context) async {
    Future<OtpAuth?> cleanOtpCodeCode(String totpCode) async {
      try {
        if (totpCode.startsWith(OtpAuth.URI_PREFIX)) {
          return OtpAuth.fromUri(Uri.parse(totpCode));
        }
        if (totpCode.startsWith(OtpAuth.MIGRATION_URI_PREFIX)) {
          final migration = OtpAuthMigration();
          final uris = migration.decode(totpCode);
          if (uris.length != 1) {
            final loc = AppLocalizations.of(context);
            await DialogUtils.showErrorDialog(
              context,
              loc.otpUnsupportedMigrationTitle,
              loc.otpUnsupportedMigrationBody(uris.length),
              routeAppend: 'invalidTotpMigration',
            );
            return null;
          }
          return OtpAuth.fromUri(Uri.parse(uris.first));
        }
        final value = base32Decode(totpCode);
        _logger.fine('Got totp secret with ${value.lengthInBytes} bytes.');
        return OtpAuth(secret: value);
      } catch (e, stackTrace) {
        _logger.warning('Invalid base32 code?', e, stackTrace);
        final loc = AppLocalizations.of(context);
        await DialogUtils.showSimpleAlertDialog(
          context,
          loc.otpInvalidKeyTitle,
          loc.otpInvalidKeyBody,
          routeAppend: 'totpInvalidKey',
        );
        return await _askForTotpSecret(context);
      }
    }

    if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
      try {
        _logger.finer('Opening barcode scanner.');

        final loc = AppLocalizations.of(context);
        final barcodeResult = await BarcodeScanHelper.scanBarcode(
          context,
          titleText: loc.scanQrCodeTitle,
          formats: [
            BarcodeFormat.qrCode,
            BarcodeFormat.microQRCode,
          ],
        );

        if (barcodeResult case ScanResultValid(barcode: final barcode)) {
          return await cleanOtpCodeCode(barcode.text);
        }
      } catch (e, stackTrace) {
        _logger.warning('Error during barcode scanning.', e, stackTrace);
      }
    }
    final loc = AppLocalizations.of(context);
    final totpCode = await SimplePromptDialog(
      title: loc.otpPromptTitle,
      helperText: loc.otpPromptHelperText,
    ).show(context);
    if (totpCode == null) {
      return null;
    }
    return cleanOtpCodeCode(totpCode);
  }
}

class AttachmentBottomSheet extends StatelessWidget {
  const AttachmentBottomSheet({
    super.key,
    required this.entry,
    required this.attachment,
  });

  final KdbxEntry entry;
  final MapEntry<KdbxKey, KdbxBinary> attachment;

  @override
  Widget build(BuildContext context) {
    final analytics = Provider.of<Analytics>(context);
    final loc = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.open_in_new),
          title: Text(loc.entryAttachmentOpenActionLabel),
          onTap: () async {
            analytics.events.trackAttachmentAction('open');
            Navigator.of(context).pop();
            final kdbxBloc = context.read<KdbxBloc>();
            final provider = await kdbxBloc.attachmentProviderForFileSource(
              entry.file,
            );
            final bytes = await provider.readAttachmentBytes(
              entry.file,
              attachment.value,
            );
            final f = await PathUtils().saveToTempDirectory(
              bytes,
              dirPrefix: 'openbinary',
              fileName: attachment.key.key,
            );
            _logger.fine('Opening ${f.path}');
            final result = await OpenFile.open(f.path);
            _logger.fine('finished opening ${result.type}: ${result.message}');
          },
        ),
        ListTile(
          leading: const Icon(Icons.share),
          title: Text(loc.entryAttachmentShareActionLabel),
          onTap: () async {
            analytics.events.trackAttachmentAction('share');
            final kdbxBloc = context.read<KdbxBloc>();
            final provider = await kdbxBloc.attachmentProviderForFileSource(
              entry.file,
            );
            final bytes = await provider.readAttachmentBytes(
              entry.file,
              attachment.value,
            );
            final mimeType = lookupMimeType(
              attachment.key.key,
              headerBytes: bytes.length > defaultMagicNumbersMaxLength
                  ? Uint8List.sublistView(
                      bytes,
                      0,
                      defaultMagicNumbersMaxLength,
                    )
                  : null,
            )!;
            _logger.fine('Opening attachment with mimeType $mimeType');

            final tempDir = await PathUtils().getTemporaryDirectory();
            final f = await tempDir.childFile(attachment.key.key).create();
            await f.writeAsBytes(bytes);

            try {
              await SharePlus.instance.share(
                ShareParams(
                  files: [
                    XFile(f.path, mimeType: mimeType),
                  ],
                  subject: loc.entryAttachmentShareSubject,
                ),
              );
            } finally {
              unawaited(f.delete());
            }

            Navigator.of(context).pop();
          },
        ),
        if (!KeyNestPlatform.isWeb)
          ListTile(
            leading: const Icon(Icons.save),
            title: Text(loc.entryAttachmentSaveActionLabel),
            onTap: () async {
              analytics.events.trackAttachmentAction('saveToDevice');
              Navigator.of(context).pop();
              final kdbxBloc = context.read<KdbxBloc>();
              final provider = await kdbxBloc.attachmentProviderForFileSource(
                entry.file,
              );
              final bytes = await provider.readAttachmentBytes(
                entry.file,
                attachment.value,
              );
              if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
                await FilePickerWritable().openFileForCreate(
                  fileName: attachment.key.key,
                  writer: (file) async {
                    _logger.fine('Opening ${file.path}');
                    await file.writeAsBytes(bytes);
                  },
                );
              } else {
                final saveLocation = await getSaveLocation(
                  suggestedName: attachment.key.key,
                  confirmButtonText: loc.saveButtonLabel,
                );
                if (saveLocation != null) {
                  final outputFile = io.File(saveLocation.path);
                  await outputFile.writeAsBytes(bytes);
                }
              }
            },
          ),
        ListTile(
          leading: const Icon(Icons.delete),
          title: Text(loc.entryAttachmentRemoveActionLabel),
          onTap: () async {
            analytics.events.trackAttachmentAction('remove');
            Navigator.of(context).pop();
            final confirm = await DialogUtils.showConfirmDialog(
              context: context,
              params: ConfirmDialogParams(
                content: loc.entryAttachmentRemoveConfirm(attachment.key.key),
              ),
            );
            if (confirm) {
              entry.removeBinary(attachment.key);
            }
          },
        ),
      ],
    );
  }
}

class EntryMetaInfo extends StatelessWidget {
  const EntryMetaInfo({
    super.key,
    this.label,
    this.value,
    this.onTap,
  });

  final String? label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            ...?onTap == null
                ? null
                : [
                    const Icon(Icons.edit, size: 16, color: Colors.black45),
                    const SizedBox(width: 8),
                  ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label!, style: theme.textTheme.bodySmall),
                  Text(
                    value!,
                    style: theme.textTheme.bodyLarge!.copyWith(
                      color: theme.textTheme.bodySmall!.color,
                    ),
                    maxLines: 2,
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

class AddFieldButton extends StatelessWidget {
  const AddFieldButton({super.key, required this.onAddField});

  final void Function(KeyNestAddFieldResult result) onAddField;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark
              ? KeyNestPalette.primaryDark
              : KeyNestPalette.primary,
          side: BorderSide(
            color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
            width: 1.2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
        label: const Text(
          'Add Field',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        onPressed: () async {
          final result = await KeyNestAddFieldSheet.show(context);
          if (result != null) {
            onAddField(result);
          }
        },
      ),
    );
  }
}

class EntryField extends StatefulWidget {
  const EntryField({
    super.key,
    required this.fieldType,
    required this.entry,
    required this.fieldKey,
    this.commonField,
    this.onDeleteField,
    required this.onChangedMetadata,
  });

  final FieldType fieldType;
  final KdbxEntry entry;
  final KdbxKey fieldKey;
  final CommonField? commonField;
  final void Function(KdbxKey key)? onDeleteField;
  final VoidCallback onChangedMetadata;

  @override
  _EntryFieldState createState() =>
      // ignore: no_logic_in_create_state
      fieldType == FieldType.otp ? _OtpEntryFieldState() : _EntryFieldState();
}

enum EntryAction {
  copy,
  copyRawData,
  editOtp,
  rename,
  protect,
  delete,
  show,
  passwordGenerator,
  generateEmail,
  passwordHistory,
}

abstract class FieldDelegate {
  Future<void> generatePassword();

  Future<void> openUrl();
}

class _EntryFieldState extends State<EntryField>
    with StreamSubscriberMixin, TaskStateMixin
    implements FieldDelegate {
  final GlobalKey _formFieldKey = GlobalKey();
  late TextEditingController _controller;
  bool _isValueObscured = false;
  final FocusNode _focusNode = FocusNode();
  late CommonFields _commonFields;

  IntentActionRegistration? _keyboardRegistration;

  StringValue? get _fieldValue => widget.entry.getString(widget.fieldKey);

  set _fieldValue(StringValue? value) {
    widget.entry.setString(widget.fieldKey, value);
  }

  CustomFieldKind? get _customKind {
    if (widget.commonField != null) {
      return null;
    }
    final raw = widget.entry.customData['FieldType_${widget.fieldKey.key}'];
    if (raw != null && raw.isNotEmpty) {
      final cdLower = raw.toLowerCase();
      if (cdLower == 'boolean' ||
          cdLower == 'switch' ||
          cdLower == 'bool' ||
          cdLower == 'yesno') {
        return CustomFieldKind.yesNo;
      }
      final match = CustomFieldKind.values.firstWhereOrNull(
        (k) => k.name.toLowerCase() == cdLower,
      );
      if (match != null) {
        return match;
      }
    }
    return KeyNestCustomFieldSheet.resolveFieldKind(
      widget.entry,
      widget.fieldKey.key,
      value: _fieldValue?.getText(),
      isProtected: _fieldValue is ProtectedValue,
    );
  }

  bool get _isProtected => _fieldValue == null
      ? (widget.commonField?.protect == true ||
            KeyNestItemTypeHelper.isSensitiveFieldKey(
              widget.fieldKey.key,
              kind: _customKind,
            ))
      : (_fieldValue is ProtectedValue ||
            KeyNestItemTypeHelper.isSensitiveFieldKey(
              widget.fieldKey.key,
              kind: _customKind,
            ));

  String? get _valueCurrent =>
      (_isValueObscured
          ? widget.entry.getString(widget.fieldKey)?.getText()
          : _controller.text) ??
      _fieldValue?.getText();

  final GlobalKey<HighlightWidgetState> _highlightWidgetKey =
      GlobalKey<HighlightWidgetState>();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_focusNodeChanged);
    _initController();
  }

  void _initController() {
    _isValueObscured = false;
    _controller = TextEditingController(
      text: _fieldValue?.getText() ?? CharConstants.empty,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _commonFields = Provider.of<CommonFields>(context);
    if (widget.fieldKey == _commonFields.password.key) {
      _keyboardRegistration?.dispose();
      final keyboardShortcutEvents = context.watch<KeyboardShortcutEvents>();
      _keyboardRegistration = keyboardShortcutEvents.registerActions({
        GeneratePassword: CallbackAction(onInvoke: (_) => _generatePassword()),
      });
    }
  }

  void _focusNodeChanged() {
    if (!_isProtected) {
      return;
    }
    if (!_focusNode.hasFocus) {
      _fieldValue = ProtectedValue.fromString(_controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    _logger.finer('building ${widget.fieldKey} ($_isValueObscured)');
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey(widget.fieldKey),
      background: Container(
        alignment: Alignment.centerLeft,
        color: theme.brightness == Brightness.light
            ? Colors.lightBlueAccent
            : Colors.blueAccent,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.lock),
            const SizedBox(height: 4),
            Text(loc.swipeCopyField),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        await copyValue();
        return false;
      },
      child: HighlightWidget(
        key: _highlightWidgetKey,
        childOnHighlight: Text(
          loc.doneCopiedField,
          style: theme.textTheme.bodyMedium!
              .copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                shadows: const [
                  Shadow(
                    color: Colors.black,
                    blurRadius: 1,
                  ),
                ],
                letterSpacing: 1,
              )
              .apply(fontSizeFactor: 1.2),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Material(
            color: theme.brightness == Brightness.dark
                ? KeyNestPalette.cardDark
                : KeyNestPalette.surfaceLight,
            borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? KeyNestPalette.cardDark
                    : KeyNestPalette.surfaceLight,
                borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
                border: Border.all(
                  color: theme.brightness == Brightness.dark
                      ? KeyNestPalette.entryBorderDark
                      : KeyNestPalette.entryBorderLight,
                  width: 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Center(
                      child: Icon(
                        _customKind == CustomFieldKind.yesNo
                            ? Icons.toggle_on_rounded
                            : _iconForFieldKey(widget.fieldKey, widget.commonField),
                        size: 22,
                        color: theme.brightness == Brightness.dark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.lightIcon,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.fieldType != FieldType.otp) ...[
                          Row(
                            children: [
                              Text(
                                widget.commonField?.displayName ??
                                    widget.fieldKey.key,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.brightness == Brightness.dark
                                      ? KeyNestPalette.textSecondaryDark
                                      : KeyNestPalette.textSecondaryLight,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (_isProtected) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        (theme.brightness == Brightness.dark
                                                ? KeyNestPalette.primaryDark
                                                : KeyNestPalette.primary)
                                            .withValues(
                                              alpha:
                                                  theme.brightness ==
                                                      Brightness.dark
                                                  ? 0.20
                                                  : 0.12,
                                            ),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color:
                                          (theme.brightness == Brightness.dark
                                                  ? KeyNestPalette.primaryDark
                                                  : KeyNestPalette.primary)
                                              .withValues(
                                                alpha: 0.35,
                                              ),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.lock_rounded,
                                        size: 10,
                                        color:
                                            theme.brightness == Brightness.dark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'PROTECTED',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                          color:
                                              theme.brightness ==
                                                  Brightness.dark
                                              ? KeyNestPalette.primaryDark
                                              : KeyNestPalette.primary,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                        ],
                        _buildEntryFieldEditor(),
                      ],
                    ),
                  ),
                  Container(
                    width: 36,
                    height: 36,
                    margin: const EdgeInsets.only(top: 2),
                    alignment: Alignment.center,
                    child: AnimatedCrossFade(
                      duration: const Duration(milliseconds: 300),
                      firstChild: KeyNestPopupMenuButton<EntryAction>(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.more_vert_rounded,
                          size: 20,
                          color: theme.brightness == Brightness.dark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                        ),
                        offset: const Offset(0, 32),
                        onSelected: _handleMenuEntrySelected,
                        itemBuilder: _buildMenuEntries,
                      ),
                      secondChild: const Padding(
                        padding: EdgeInsets.all(8.0),
                        child: CircularProgressIndicator(),
                      ),
                      crossFadeState: task == null
                          ? CrossFadeState.showFirst
                          : CrossFadeState.showSecond,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleMenuEntrySelected(EntryAction entryAction) async {
    switch (entryAction) {
      case EntryAction.copy:
        await copyValue();
        break;
      case EntryAction.copyRawData:
        // only used by [_OtpEntryFieldState]
        throw UnsupportedError('Field does not support this action.');
      case EntryAction.editOtp:
        // only used by [_OtpEntryFieldState]
        throw UnsupportedError('Field does not support this action.');
      case EntryAction.rename:
        final loc = AppLocalizations.of(context);
        final key = await SimplePromptDialog(
          title: loc.entryRenameFieldPromptTitle,
          labelText: loc.entryRenameFieldPromptLabel,
          initialValue: widget.fieldKey.key,
        ).show(context);
        if (key != null && key.trim().isNotEmpty && key.trim() != widget.fieldKey.key) {
          final trimmedNewKey = key.trim();
          final oldCustomType =
              widget.entry.customData['FieldType_${widget.fieldKey.key}'];
          widget.entry.renameKey(widget.fieldKey, KdbxKey(trimmedNewKey));
          if (oldCustomType != null) {
            widget.entry.customData['FieldType_$trimmedNewKey'] = oldCustomType;
            widget.entry.customData['FieldType_${widget.fieldKey.key}'] = '';
          }
          widget.onChangedMetadata();
        }
        break;
      case EntryAction.passwordGenerator:
        await _launchPasswordGenerator();
        break;
      case EntryAction.protect:
        setState(() {
          if (_isProtected) {
            _fieldValue = PlainValue(_valueCurrent ?? CharConstants.empty);
            _isValueObscured = false;
          } else {
            _logger.fine(
              'protected: $_isProtected, obscured: $_isValueObscured, current: $_valueCurrent',
            );
            _fieldValue = ProtectedValue.fromString(
              _valueCurrent ?? CharConstants.empty,
            );
            _isValueObscured = true;
          }
          _initController();
        });
        break;
      case EntryAction.delete:
        widget.onDeleteField?.call(widget.fieldKey);
        widget.entry.removeString(widget.fieldKey);
        widget.entry.customData['FieldType_${widget.fieldKey.key}'] = '';
        widget.onChangedMetadata();
        break;
      case EntryAction.show:
        FullScreenHud.show(context, (context) {
          return FullScreenHud(
            value: _valueCurrent ?? CharConstants.empty,
          );
        });
        break;
      case EntryAction.generateEmail:
        break;
      case EntryAction.passwordHistory:
        await KeyNestPasswordHistorySheet.show(
          context,
          widget.entry,
          onRestore: (restored) {
            setState(() {
              _controller.text = restored;
              _fieldValue = ProtectedValue.fromString(restored);
              _initController();
            });
            widget.onChangedMetadata();
          },
        );
        break;
    }
  }

  List<PopupMenuEntry<EntryAction>> _buildMenuEntries(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return <PopupMenuEntry<EntryAction>>[
      PopupMenuItem(
        value: EntryAction.copy,
        child: ListTile(
          leading: const Icon(Icons.content_copy),
          title: Text(loc.swipeCopyField),
        ),
      ),
      if (widget.fieldKey == KdbxKeyCommon.PASSWORD) ...[
        PopupMenuItem(
          value: EntryAction.passwordHistory,
          child: ListTile(
            leading: Icon(
              Icons.history_rounded,
              color: Theme.of(context).brightness == Brightness.dark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
            ),
            title: const Text('Password History'),
          ),
        ),
      ],
      const PopupMenuDivider(),
      PopupMenuItem(
        value: EntryAction.rename,
        child: ListTile(
          leading: const Icon(Icons.edit),
          title: Text(loc.fieldRename),
        ),
      ),
      PopupMenuItem(
        value: EntryAction.passwordGenerator,
        child: ListTile(
          leading: const FaIcon(FontAwesomeIcons.shuffle),
          title: Text(loc.generatePassword),
        ),
      ),
      PopupMenuItem(
        value: EntryAction.protect,
        child: ListTile(
          leading: Icon(
            _isProtected ? Icons.no_encryption : Icons.enhanced_encryption,
          ),
          title: Text(_isProtected ? loc.fieldUnprotect : loc.fieldProtect),
        ),
      ),
      if (widget.fieldKey != KdbxKeyCommon.TITLE)
        PopupMenuItem(
          value: EntryAction.delete,
          child: ListTile(
            leading: const Icon(Icons.delete, color: KeyNestPalette.error),
            title: Text(
              loc.deleteAction,
              style: const TextStyle(color: KeyNestPalette.error),
            ),
          ),
        ),
      PopupMenuItem(
        value: EntryAction.show,
        child: ListTile(
          leading: const FaIcon(FontAwesomeIcons.qrcode),
          title: Text(loc.fieldPresent),
        ),
      ),
    ];
  }

  @override
  Future<void> openUrl() async {
    context.events.trackEntryAction(EntryActionType.openUrl);
    final url = _valueCurrent!;
    final loc = AppLocalizations.of(context);
    final normalizedUrl = DialogUtils.normalizeUrl(url);
    String? openError;
    try {
      _logger.finer('Opening url $url ($normalizedUrl)');
      if (await DialogUtils.openUrl(normalizedUrl)) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(loc.launchedUrl(url)),
              duration: const Duration(milliseconds: 1800),
            ),
          );
      } else {
        openError = loc.unableToLaunchUrlNoHandler;
      }
    } catch (e, stackTrace) {
      openError = e.toString();
      _logger.severe('Unable to open url, $url', e, stackTrace);
    }
    if (openError != null) {
      await DialogUtils.showErrorDialog(
        context,
        loc.unableToLaunchUrlTitle,
        loc.unableToLaunchUrlDescription(url, openError),
      );
    }
  }

  @override
  Future<void> generatePassword() => _generatePassword();

  Future<void> _generatePassword() async {
    context.events.trackEntryAction(EntryActionType.generatePassword);
    final appData = await Provider.of<AppDataBloc>(
      context,
      listen: false,
    ).store.load();
    final characterSets = CharacterSet.characterSetFromIds(
      appData.passwordGeneratorCharacterSets,
    );
    if (characterSets.isEmpty) {
      characterSets.addAll([CharacterSet.alphaNumeric, CharacterSet.numeric]);
    }
    final length = appData.passwordGeneratorLength ?? 16;
    _generatedPassword(
      PasswordGenerator.singleton().generatePassword(
        CharacterSetCollection(characterSets.toList()),
        length,
      ),
    );
  }

  Future<void> _launchPasswordGenerator() async {
    final password = await Navigator.of(
      context,
    ).push(PasswordGeneratorScreen.route(finishButton: FinishButtonStyle.done));
    if (password != null) {
      setState(() {
        _generatedPassword(password);
      });
    }
  }

  void _generatedPassword(String password) {
    setState(() {
      _isValueObscured = false;
      _controller.text = password;
      _fieldValue = ProtectedValue.fromString(_controller.text);
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
      _focusNode.requestFocus();
    });
    copyValue();
  }

  Future<bool> copyValue() async {
    _highlightWidgetKey.currentState!.triggerHighlight();
    Provider.of<Analytics>(
      context,
      listen: false,
    ).events.trackCopyField(key: widget.fieldKey.key);
    final val = _valueCurrent ?? CharConstants.empty;
    final lbl = widget.commonField?.displayName ?? widget.fieldKey.key;
    if (_isProtected) {
      await SecurityService.copySensitive(
        context,
        val,
        label: lbl,
      );
    } else {
      await SecurityService.copyNonSensitive(
        context,
        val,
        label: lbl,
      );
    }
    return true;
  }

  Widget _buildEntryFieldEditor() {
    if (_customKind == CustomFieldKind.yesNo) {
      return _buildSwitchEntryFieldEditor();
    }
    return _buildStringEntryFieldEditor();
  }

  Widget _buildSwitchEntryFieldEditor() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currentValue = _valueCurrent ?? _fieldValue?.getText() ?? '';
    final isTrue = KeyNestCustomFieldSheet.isTruthy(currentValue);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (isTrue
                          ? (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary)
                          : (isDark ? Colors.white12 : Colors.black12))
                      .withValues(alpha: isTrue ? (isDark ? 0.25 : 0.15) : 1.0),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isTrue ? 'ON' : 'OFF',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: isTrue
                        ? (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary)
                        : (isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isTrue ? 'Enabled' : 'Disabled',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
              ),
            ],
          ),
          Switch.adaptive(
            value: isTrue,
            activeThumbColor: isDark
                ? KeyNestPalette.primaryDark
                : KeyNestPalette.primary,
            onChanged: (val) {
              setState(() {
                final newText = KeyNestCustomFieldSheet.boolToString(
                  val,
                  originalValue: currentValue,
                );
                _controller.text = newText;
                _fieldValue = PlainValue(newText);
              });
              final detailsState =
                  context.findAncestorStateOfType<_EntryDetailsScreenState>();
              if (detailsState != null && !detailsState.isFormDirty) {
                detailsState.setState(() => detailsState.isFormDirty = true);
              }
              widget.onChangedMetadata();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStringEntryFieldEditor() {
    return StringEntryFieldEditor(
      onSaved: (value) {
        final trimmed = value?.trim();
        final isRemovableOptional = widget.fieldKey == KdbxKey('Notes') ||
            (widget.fieldKey != KdbxKeyCommon.TITLE &&
                widget.fieldKey != KdbxKeyCommon.PASSWORD &&
                widget.fieldKey != KdbxKeyCommon.USER_NAME);
        if (value == null ||
            (trimmed != null && trimmed.isEmpty && isRemovableOptional)) {
          widget.onDeleteField?.call(widget.fieldKey);
          widget.entry.removeString(widget.fieldKey);
          widget.entry.customData['FieldType_${widget.fieldKey.key}'] = '';
        } else {
          final newValue = _isProtected
              ? ProtectedValue.fromString(value)
              : PlainValue(value);
          _fieldValue = newValue;
        }
      },
      fieldKey: widget.fieldKey,
      commonField: widget.commonField,
      controller: _controller,
      formFieldKey: _formFieldKey,
      focusNode: _focusNode,
      delegate: this,
    );
  }

  @override
  void dispose() {
    _logger.fine(
      'EntryFieldState.dispose() - ${widget.key} (${widget.fieldKey})',
    );
    _keyboardRegistration?.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  static IconData _iconForFieldKey(KdbxKey fieldKey, CommonField? commonField) {
    final commonIcon = commonField?.icon;
    if (commonIcon != null) {
      return commonIcon;
    }
    final k = fieldKey.key.toLowerCase();
    if (k == 'title') {
      return Icons.badge_outlined;
    }
    if (k.contains('user') || k.contains('login') || k.contains('account')) {
      return Icons.person_outline_rounded;
    }
    if (k.contains('pass') ||
        k.contains('pin') ||
        k.contains('secret') ||
        k.contains('cvv') ||
        k.contains('cvc')) {
      return Icons.lock_outline_rounded;
    }
    if (k.contains('url') ||
        k.contains('web') ||
        k.contains('link') ||
        k.contains('host')) {
      return Icons.language_rounded;
    }
    if (k.contains('note') || k.contains('comment') || k.contains('desc')) {
      return Icons.notes_rounded;
    }
    if (k.contains('mail')) {
      return Icons.mail_outline_rounded;
    }
    if (k.contains('phone')) {
      return Icons.phone_outlined;
    }
    if (k.contains('key') || k.contains('token') || k.contains('cert')) {
      return Icons.key_rounded;
    }
    if (k.contains('otp') || k.contains('2fa') || k.contains('totp')) {
      return Icons.timer_outlined;
    }
    if (k.contains('date') || k.contains('time') || k.contains('expiry')) {
      return Icons.calendar_today_rounded;
    }
    if (k.contains('card') || k.contains('number')) {
      return Icons.credit_card_rounded;
    }
    return Icons.data_object_rounded;
  }
}

class _OtpEntryFieldState extends _EntryFieldState with WidgetsBindingObserver {
  Timer? _timer;
  int? _currentStep;

  String _currentOtp = CharConstants.empty;

  String? _errorMessage;

  /// elapsed seconds since the last period change.
  int _elapsed = 0;

  /// period in seconds how often the otp changes.
  int _period = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTimer();
    } else {
      _stopTimer();
    }
  }

  void _startTimer() {
    if (_timer != null && _timer!.isActive) {
      return;
    }
    _updateOtp();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateOtp();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  String get _valueCurrent =>
      widget.entry.getString(widget.fieldKey)?.getText() ?? CharConstants.empty;

  OtpAuth _getOtpAuth() {
    final value = widget.entry.getString(widget.fieldKey)?.getText();
    if (value == null || value.isEmpty) {
      return throw FormatException('OTP Field contains no data.', value);
    }
    final parsed = EntryTotpHelper.parseOtpAuth(value, entry: widget.entry);
    if (parsed != null) {
      return parsed;
    }
    throw FormatException('Unknown format for OTP', value);
  }

  void _updateOtp({bool force = false}) {
    try {
      final now = clock.now().millisecondsSinceEpoch;
      final nowSec = now ~/ 1000;
      final currentPeriod = _period > 0 ? _period : 30;
      final step = nowSec ~/ currentPeriod;

      if (force || _currentStep != step || _currentOtp.isEmpty) {
        final otpAuth = _getOtpAuth();
        final secretBase32 = base32Encode(otpAuth.secret);
        _logger.fine('uri: $otpAuth');
        final totpCode = OTP.generateTOTPCodeString(
          secretBase32,
          now,
          algorithm: otpAuth.algorithm,
          length: otpAuth.digits,
          interval: otpAuth.period,
          // do not pad OTP secret if it is not of correct length.
          isGoogle: true,
        );
        _currentStep = step;
        _period = otpAuth.period > 0 ? otpAuth.period : 30;
        _currentOtp = totpCode;
      }
      setState(() {
        final activePeriod = _period > 0 ? _period : 30;
        _elapsed = nowSec % activePeriod;
        _errorMessage = null;
      });
    } on FormatException catch (e, stackTrace) {
      _logger.severe(
        'Error while decoding otpauth url for ${widget.fieldKey}.',
        e,
        stackTrace,
      );
      final loc = AppLocalizations.of(context);
      setState(() {
        _currentOtp = CharConstants.empty;
        _errorMessage = loc.otpErrorMessageGeneration(e);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timer == null) {
      _startTimer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
    super.dispose();
  }

  @override
  Future<bool> copyValue() async {
    _logger.finer('Copying OTP value.');
    _highlightWidgetKey.currentState!.triggerHighlight();
    Provider.of<Analytics>(
      context,
      listen: false,
    ).events.trackCopyField(key: widget.fieldKey.key);
    await SecurityService.copySensitive(
      context,
      _currentOtp,
      label: 'OTP code',
    );
    return true;
  }

  @override
  Widget _buildEntryFieldEditor() {
    if (_errorMessage != null) {
      return Row(
        children: [
          Expanded(child: Text(_errorMessage!)),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit TOTP Settings',
            onPressed: _showEditTotpDialog,
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: OtpFieldEntryEditor(
            period: _period,
            elapsed: _elapsed,
            otpCode: _currentOtp,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.edit_outlined, size: 20),
          tooltip: 'Edit TOTP Settings',
          color: Theme.of(context).brightness == Brightness.dark
              ? KeyNestPalette.primaryDark
              : KeyNestPalette.primary,
          onPressed: _showEditTotpDialog,
        ),
      ],
    );
  }

  @override
  Future<void> _handleMenuEntrySelected(EntryAction entryAction) async {
    if (entryAction == EntryAction.copyRawData) {
      await SecurityService.copySensitive(
        context,
        _valueCurrent,
        label: 'Raw OTP Secret',
      );
      return;
    }
    if (entryAction == EntryAction.editOtp) {
      await _showEditTotpDialog();
      return;
    }
    if (entryAction == EntryAction.protect) {
      setState(() {
        final currentVal = _valueCurrent;
        if (_isProtected) {
          _fieldValue = PlainValue(currentVal);
        } else {
          _fieldValue = ProtectedValue.fromString(currentVal);
        }
        widget.entry.setString(widget.fieldKey, _fieldValue);
      });
      widget.onChangedMetadata();
      return;
    }
    return super._handleMenuEntrySelected(entryAction);
  }

  Future<void> _showEditTotpDialog() async {
    String currentSecret = '';
    int currentDigits = 6;
    int currentPeriod = 30;
    String currentAlgorithm = 'SHA1';

    try {
      final currentAuth = _getOtpAuth();
      currentSecret = base32Encode(currentAuth.secret);
      currentDigits = currentAuth.digits;
      currentPeriod = currentAuth.period;
      currentAlgorithm = currentAuth.algorithm.name.toUpperCase();
    } catch (_) {
      currentSecret = _valueCurrent;
    }

    final secretController = TextEditingController(text: currentSecret);
    final periodController = TextEditingController(
      text: currentPeriod.toString(),
    );
    final digitsController = TextEditingController(
      text: currentDigits.toString(),
    );
    String selectedAlgorithm = currentAlgorithm.toUpperCase();
    bool isProtected = _isProtected;
    final formKey = GlobalKey<FormState>();

    final updated = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  Icons.timer_rounded,
                  color: Theme.of(ctx).brightness == Brightness.dark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                ),
                const SizedBox(width: 8),
                const Text('Edit TOTP Settings'),
              ],
            ),
            content: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: secretController,
                      decoration: InputDecoration(
                        labelText: 'Secret Key or otpauth:// URI',
                        filled: true,
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          tooltip: 'Scan QR Code',
                          onPressed: () async {
                            final barcodeResult =
                                await BarcodeScanHelper.scanBarcode(
                                  context,
                                  titleText: 'Scan TOTP QR Code',
                                  formats: const [
                                    BarcodeFormat.qrCode,
                                    BarcodeFormat.microQRCode,
                                  ],
                                );
                            if (barcodeResult case ScanResultValid(
                              barcode: final barcode,
                            )) {
                              setDialogState(() {
                                secretController.text = barcode.text;
                              });
                            }
                          },
                        ),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Please enter a secret key';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: digitsController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Digits',
                              filled: true,
                            ),
                            validator: (val) {
                              final n = int.tryParse(val ?? '');
                              if (n == null || n < 4 || n > 10) {
                                return 'Invalid';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: periodController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Period (s)',
                              filled: true,
                            ),
                            validator: (val) {
                              final n = int.tryParse(val ?? '');
                              if (n == null || n < 5 || n > 300) {
                                return 'Invalid';
                              }
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue:
                          [
                            'SHA1',
                            'SHA256',
                            'SHA512',
                          ].contains(selectedAlgorithm)
                          ? selectedAlgorithm
                          : 'SHA1',
                      decoration: const InputDecoration(
                        labelText: 'Algorithm',
                        filled: true,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'SHA1',
                          child: Text('SHA1 (Default)'),
                        ),
                        DropdownMenuItem(
                          value: 'SHA256',
                          child: Text('SHA256'),
                        ),
                        DropdownMenuItem(
                          value: 'SHA512',
                          child: Text('SHA512'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => selectedAlgorithm = val);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Protect Value'),
                      subtitle: const Text(
                        'Keep TOTP masked with dots in view mode until revealed',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: isProtected,
                      onChanged: (val) {
                        setDialogState(() => isProtected = val ?? false);
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (formKey.currentState!.validate()) {
                    Navigator.of(dialogCtx).pop(true);
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    if (updated == true && mounted) {
      final inputSecret = secretController.text.trim();
      String finalUri;
      if (inputSecret.startsWith(OtpAuth.URI_PREFIX)) {
        finalUri = inputSecret;
      } else {
        final cleanSecret = inputSecret.replaceAll(' ', '').toUpperCase();
        final label = Uri.encodeComponent(widget.entry.label ?? 'KeyNest');
        final digits = int.tryParse(digitsController.text.trim()) ?? 6;
        final period = int.tryParse(periodController.text.trim()) ?? 30;
        finalUri =
            'otpauth://totp/$label?secret=$cleanSecret&digits=$digits&period=$period&algorithm=$selectedAlgorithm';
      }

      setState(() {
        _fieldValue = isProtected
            ? ProtectedValue.fromString(finalUri)
            : PlainValue(finalUri);
        widget.entry.setString(widget.fieldKey, _fieldValue);
        _updateOtp();
      });
      widget.onChangedMetadata();
    }
  }

  @override
  List<PopupMenuEntry<EntryAction>> _buildMenuEntries(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return [
      PopupMenuItem(
        value: EntryAction.copy,
        child: ListTile(
          leading: const Icon(Icons.content_copy),
          title: Text(loc.swipeCopyField),
        ),
      ),
      PopupMenuItem(
        value: EntryAction.copyRawData,
        child: ListTile(
          leading: const Icon(Icons.code),
          title: Text(loc.otpCopySecretActionLabel),
        ),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: EntryAction.editOtp,
        child: ListTile(
          leading: Icon(
            Icons.edit_outlined,
            color: Theme.of(context).brightness == Brightness.dark
                ? KeyNestPalette.primaryDark
                : KeyNestPalette.primary,
          ),
          title: const Text('Edit TOTP Settings'),
        ),
      ),
      PopupMenuItem(
        value: EntryAction.protect,
        child: ListTile(
          leading: Icon(
            _isProtected ? Icons.no_encryption : Icons.enhanced_encryption,
          ),
          title: Text(_isProtected ? loc.fieldUnprotect : loc.fieldProtect),
        ),
      ),
      PopupMenuItem(
        value: EntryAction.delete,
        child: ListTile(
          leading: const Icon(Icons.delete),
          title: Text(loc.deleteAction),
        ),
      ),
    ];
  }
}

class ObscuredEntryFieldEditor extends StatelessWidget {
  const ObscuredEntryFieldEditor({
    super.key,
    required this.onPressed,
    required this.onShowPressed,
    required this.commonField,
    required this.fieldKey,
  });

  final CommonField? commonField;
  final KdbxKey fieldKey;
  final VoidCallback onPressed;
  final VoidCallback onShowPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final loc = AppLocalizations.of(context);

    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '••••••••••••',
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFamily: KeyNestTheme.monoFontFamily,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                  letterSpacing: 2.0,
                ),
              ),
            ),
          ),
        ),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          icon: Icon(
            Icons.visibility_rounded,
            size: 20,
            color: isDark
                ? KeyNestPalette.textSecondaryDark
                : KeyNestPalette.textSecondaryLight,
          ),
          tooltip: loc.entryFieldActionRevealField,
          onPressed: onShowPressed,
        ),
      ],
    );
  }
}

class StringEntryFieldEditor extends StatelessWidget {
  const StringEntryFieldEditor({
    super.key,
    required this.onSaved,
    required this.controller,
    required this.formFieldKey,
    required this.focusNode,
    required this.commonField,
    required this.fieldKey,
    required this.delegate,
  });

  final Key formFieldKey;
  final FocusNode focusNode;
  final CommonField? commonField;
  final KdbxKey fieldKey;
  final TextEditingController? controller;
  final FormFieldSetter<String> onSaved;
  final FieldDelegate delegate;

  @override
  Widget build(BuildContext context) {
    final commonFields = Provider.of<CommonFields>(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final loc = AppLocalizations.of(context);
    final isMonospace =
        fieldKey == commonFields.password.key ||
        fieldKey.key.toLowerCase().contains('key') ||
        fieldKey.key.toLowerCase().contains('secret') ||
        fieldKey.key.toLowerCase().contains('token') ||
        fieldKey.key.toLowerCase().contains('pin');
    final fieldKeyLower = fieldKey.key.toLowerCase();
    final isNotes = fieldKey == commonFields.notes.key;
    final isMultiline =
        isNotes ||
        fieldKeyLower.contains('note') ||
        fieldKeyLower.contains('comment') ||
        fieldKeyLower.contains('desc') ||
        fieldKeyLower.contains('address') ||
        (controller?.text.contains('\n') ?? false);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            key: formFieldKey,
            maxLines: isMultiline ? null : 4,
            minLines: isNotes ? 3 : (isMultiline ? 2 : 1),
            textInputAction: isMultiline
                ? TextInputAction.newline
                : TextInputAction.next,
            focusNode: focusNode,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              fontFamily: isMonospace ? KeyNestTheme.monoFontFamily : null,
              color: isDark
                  ? KeyNestPalette.textPrimaryDark
                  : KeyNestPalette.textPrimaryLight,
              letterSpacing: isMonospace ? 0.4 : 0,
            ),
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              fillColor: Colors.transparent,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
              hintText: 'Enter ${commonField?.displayName ?? fieldKey.key}...',
              hintStyle: TextStyle(
                color:
                    (isDark
                            ? KeyNestTokens.darkOnSurface
                            : KeyNestTokens.lightOnSurface)
                        .withValues(alpha: 0.38),
                fontWeight: FontWeight.normal,
                letterSpacing: 0,
                fontSize: 15,
              ),
            ),
            keyboardType: isMultiline
                ? TextInputType.multiline
                : commonField?.keyboardType,
            autocorrect: commonField?.autocorrect ?? true,
            enableSuggestions: commonField?.enableSuggestions ?? true,
            textCapitalization:
                commonField?.textCapitalization ?? TextCapitalization.sentences,
            controller: controller,
            validator: (val) {
              if (fieldKey == commonFields.title.key) {
                if (val == null || val.trim().isEmpty) {
                  return 'Title is required';
                }
              }
              return null;
            },
            onSaved: onSaved,
          ),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller!,
          builder: (context, value, child) {
            if (fieldKey == commonFields.password.key) {
              return Padding(
                padding: const EdgeInsets.only(top: 2),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  iconSize: 20,
                  tooltip: '${loc.menuItemGeneratePassword} (cmd+g)',
                  icon: Icon(
                    Icons.refresh_rounded,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                  ),
                  onPressed: delegate.generatePassword,
                ),
              );
            }
            if (fieldKey == commonFields.url.key &&
                controller!.text.isNotEmpty) {
              return Padding(
                padding: const EdgeInsets.only(top: 2),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  iconSize: 18,
                  tooltip: '${loc.actionOpenUrl} (shift+cmd+U)',
                  icon: const Icon(Icons.open_in_new_rounded),
                  color: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                  onPressed: delegate.openUrl,
                ),
              );
            }
            return const SizedBox();
          },
        ),
      ],
    );
  }
}

class HighlightWidget extends StatefulWidget {
  const HighlightWidget({super.key, this.child, this.childOnHighlight});

  final Widget? child;
  final Widget? childOnHighlight;

  @override
  HighlightWidgetState createState() => HighlightWidgetState();
}

class HighlightWidgetState extends State<HighlightWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  Animation<Decoration>? _decorationAnimation;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _controller.addStatusListener(_animationStatusChanged);
  }

  void _animationStatusChanged(AnimationStatus status) {
    _logger.finer('Highlight animation status changed: $status');
    if (status == AnimationStatus.completed) {
      setState(() {
        _decorationAnimation = null;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _decorationAnimation == null
        ? widget.child!

        : Stack(
            clipBehavior: Clip.none,
            children: [
              widget.child!,
              Positioned.fill(
                top: -4,
                bottom: -4,
                child: FadeTransition(
                  opacity: _opacity,
                  child: DecoratedBoxTransition(
                    decoration: _decorationAnimation!,
                    child: Center(child: widget.childOnHighlight),
                  ),
                ),
              ),
            ],
          );
  }

  void triggerHighlight() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark
        ? KeyNestTokens.primaryAccent
        : KeyNestTokens.lightPrimary;
    final tween = DecorationTween(
      begin: BoxDecoration(
        color: accent.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
      ),
      end: BoxDecoration(
        color: accent.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
      ),
    );
    setState(() {
      _decorationAnimation = CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOut,
      ).drive(tween);
      _opacity = CurvedAnimation(
        parent: _controller,
        curve: Curves.easeIn,
      ).drive(Tween(begin: 1, end: 0));
      _controller.forward(from: 0);
    });
  }
}

class _EntryViewMode extends StatefulWidget {
  const _EntryViewMode({
    super.key,
    required this.entry,
    required this.commonFields,
    required this.onEdit,
    required this.onMoveToGroup,
  });

  final KdbxEntry entry;
  final CommonFields commonFields;
  final VoidCallback onEdit;
  final VoidCallback onMoveToGroup;

  @override
  State<_EntryViewMode> createState() => _EntryViewModeState();
}

class _EntryViewModeState extends State<_EntryViewMode> {
  final Set<String> _revealedFields = <String>{};

  bool _isFieldRevealed(String key) => _revealedFields.contains(key);

  void _toggleFieldReveal(String key) {
    setState(() {
      if (_revealedFields.contains(key)) {
        _revealedFields.remove(key);
      } else {
        _revealedFields.add(key);
      }
    });
  }

  static bool _isInternalMetadata(String key) {
    const hidden = {
      'Title',
      'UserName',
      'Email',
      'Password',
      'URL',
      'Notes',
      'RecordType',
      'ItemCategory',
      'IsDeleted',
      'CardColorHex',
      'CardFinish',
      'CardNetwork',
      'Cardholder',
      'OTPAuth',
      'otp',
      'totp',
      'TOTP Seed',
      'TOTP Settings',
      '2fa',
      'is_favorite',
      'IsFavorite',
    };
    return hidden.contains(key);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final title = entry.label?.isNotEmpty == true
        ? entry.label!
        : 'Untitled Item';
    final username = entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
    final email = entry.getString(KdbxKey('Email'))?.getText() ?? '';
    final password = entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
    final url = entry.getString(KdbxKeyCommon.URL)?.getText() ?? '';
    final notes = entry.getString(KdbxKey('Notes'))?.getText() ?? '';
    final folderName = entry.parent?.name.get() ?? 'Root Group';

    // 2FA / TOTP calculation
    final hasTotp = EntryTotpHelper.hasTotp(entry);
    final isOtpProtected = EntryTotpHelper.isTotpProtected(entry);

    // Custom fields
    final customFields = entry.stringEntries
        .where(
          (e) =>
              !_isInternalMetadata(e.key.key) &&
              !widget.commonFields.isCommon(e.key) &&
              e.value?.getText()?.isNotEmpty == true,
        )
        .toList();

    final itemType = KeyNestItemTypeHelper.getItemType(entry);
    final modified = entry.times.lastModificationTime.get();
    final modifiedStr = modified != null
        ? DateFormat('MMMM d, y • h:mm a').format(modified)
        : null;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: KeyNestTokens.contentMaxWidth,
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 80),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: isDark
                    ? KeyNestPalette.surfaceContainerDark
                    : KeyNestPalette.surfaceLight,
                borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
                border: Border.all(
                  color: isDark
                      ? KeyNestPalette.entryBorderDark
                      : KeyNestPalette.entryBorderLight,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.lightIcon)
                              .withValues(alpha: isDark ? 0.20 : 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    alignment: Alignment.center,
                    child: EntryIcon(
                      entry: entry,
                      size: 26,
                      fallback: (ctx) => EntryIcon.defaultIconForEntry(
                        entry,
                        isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                        theme,
                        26,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary)
                                        .withValues(
                                          alpha: isDark ? 0.20 : 0.1,
                                        ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                itemType.name.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '• Tap any field to copy',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? KeyNestPalette.textSecondaryDark
                                          .withValues(
                                            alpha: 0.7,
                                          )
                                    : KeyNestPalette.textSecondaryLight
                                          .withValues(
                                            alpha: 0.7,
                                          ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

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
                    onPressed: widget.onMoveToGroup,
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

            if (username.isNotEmpty ||
                email.isNotEmpty ||
                password.isNotEmpty ||
                url.isNotEmpty ||
                hasTotp) ...[
              Text(
                'Credentials & Details',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 10),
            ],

            if (username.isNotEmpty)
              _ViewFieldTile(
                label: 'Username',
                value: username,
                icon: Icons.person_outline_rounded,
                isMasked:
                    (entry.getString(KdbxKeyCommon.USER_NAME)
                        is ProtectedValue) &&
                    !_isFieldRevealed('UserName'),
                onToggleMask:
                    (entry.getString(KdbxKeyCommon.USER_NAME) is ProtectedValue)
                    ? () => _toggleFieldReveal('UserName')
                    : null,
              ),

            if (email.isNotEmpty)
              _ViewFieldTile(
                label: 'Email',
                value: email,
                icon: Icons.alternate_email_rounded,
                isMasked:
                    (entry.getString(KdbxKey('Email')) is ProtectedValue) &&
                    !_isFieldRevealed('Email'),
                onToggleMask:
                    (entry.getString(KdbxKey('Email')) is ProtectedValue)
                    ? () => _toggleFieldReveal('Email')
                    : null,
              ),

            if (password.isNotEmpty)
              _ViewFieldTile(
                label: 'Password',
                value: password,
                icon: Icons.lock_outline_rounded,
                isMonospace: true,
                isMasked: !_isFieldRevealed('Password'),
                onToggleMask: () => _toggleFieldReveal('Password'),
              ),

            if (hasTotp)
              KeyNestTotpTile(
                entry: entry,
                isMasked: isOtpProtected && !_isFieldRevealed('TOTP'),
                onToggleMask: isOtpProtected
                    ? () => _toggleFieldReveal('TOTP')
                    : null,
              ),

            if (url.isNotEmpty)
              _ViewFieldTile(
                label: 'Website / URL',
                value: url,
                icon: Icons.language_rounded,
                isMasked:
                    (entry.getString(KdbxKeyCommon.URL) is ProtectedValue) &&
                    !_isFieldRevealed('URL'),
                onToggleMask:
                    (entry.getString(KdbxKeyCommon.URL) is ProtectedValue)
                    ? () => _toggleFieldReveal('URL')
                    : null,
                customAction: () => DialogUtils.openUrl(url),
                customActionIcon: Icons.open_in_new_rounded,
                customActionTooltip: 'Open website',
              ),

            if (notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Notes',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 8),
              _ViewFieldTile(
                label: 'Notes',
                value: notes,
                icon: Icons.notes_rounded,
                maxLines: null,
                isMasked:
                    (entry.getString(KdbxKey('Notes')) is ProtectedValue) &&
                    !_isFieldRevealed('Notes'),
                onToggleMask:
                    (entry.getString(KdbxKey('Notes')) is ProtectedValue)
                    ? () => _toggleFieldReveal('Notes')
                    : null,
              ),
            ],

            if (customFields.isNotEmpty) ...[
              const SizedBox(height: 10),
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
              ...customFields.map((field) {
                final fKey = field.key.key;
                final fVal = field.value?.getText() ?? '';
                final isFieldProtected = field.value is ProtectedValue;
                final kind = KeyNestCustomFieldSheet.resolveFieldKind(
                  entry,
                  fKey,
                  value: fVal,
                  isProtected: isFieldProtected,
                );
                if (kind == CustomFieldKind.yesNo) {
                  final isTrue = KeyNestCustomFieldSheet.isTruthy(fVal);
                  return _ViewFieldTile(
                    label: '$fKey (Switch)',
                    value: isTrue ? 'On (Enabled)' : 'Off (Disabled)',
                    icon: Icons.toggle_on_rounded,
                    trailing: IgnorePointer(
                      child: Switch.adaptive(
                        value: isTrue,
                        activeThumbColor: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                        onChanged: null,
                      ),
                    ),
                  );
                }
                if (kind == CustomFieldKind.authenticator) {
                  return KeyNestTotpTile(
                    entry: entry,
                    secret: fVal,
                    label: '$fKey (Authenticator (2FA))',
                    isMasked:
                        isFieldProtected && !_isFieldRevealed('custom_$fKey'),
                    onToggleMask: isFieldProtected
                        ? () => _toggleFieldReveal('custom_$fKey')
                        : null,
                  );
                }
                return _ViewFieldTile(
                  label: fKey,
                  value: fVal,
                  icon: Icons.data_object_rounded,
                  isMasked:
                      isFieldProtected && !_isFieldRevealed('custom_$fKey'),
                  onToggleMask: isFieldProtected
                      ? () => _toggleFieldReveal('custom_$fKey')
                      : null,
                );
              }),
            ],

            if (entry.binaryEntries.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Attachments (${entry.binaryEntries.length})',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 8),
              ...entry.binaryEntries.map((b) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      await showModalBottomSheet<void>(
                        context: context,
                        builder: (context) => AttachmentBottomSheet(
                          entry: entry,
                          attachment: b,
                        ),
                      );
                    },
                    child: Container(
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
                      child: Row(
                        children: [
                          Icon(
                            Icons.attach_file_rounded,
                            size: 20,
                            color: isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.lightIcon,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              b.key.key,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],

            if (entry.history.isNotEmpty) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.history_rounded, size: 18),
                label: Text('View Revisions History (${entry.history.length})'),
                onPressed: () =>
                    KeyNestPasswordHistorySheet.show(context, entry),
              ),
            ],

            const SizedBox(height: 16),

            if (modifiedStr != null) ...[
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Last modified: $modifiedStr',
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
}

class _ViewFieldTile extends StatelessWidget {
  const _ViewFieldTile({
    required this.label,
    required this.value,
    required this.icon,
    this.isMonospace = false,
    this.isMasked = false,
    this.onToggleMask,
    this.trailing,
    this.customAction,
    this.customActionIcon,
    this.customActionTooltip,
    this.maxLines = 4,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool isMonospace;
  final bool isMasked;
  final VoidCallback? onToggleMask;
  final Widget? trailing;
  final VoidCallback? customAction;
  final IconData? customActionIcon;
  final String? customActionTooltip;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final VoidCallback? copyCallback = value.isNotEmpty
        ? () {
            HapticFeedback.lightImpact();
            if (isMasked ||
                onToggleMask != null ||
                KeyNestItemTypeHelper.isSensitiveFieldKey(label)) {
              SecurityService.copySensitive(context, value, label: label);
            } else {
              SecurityService.copyNonSensitive(context, value, label: label);
            }
          }
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: KeyNestPressScale(
        onTap: copyCallback,
        child: Material(
          color: isDark ? KeyNestPalette.cardDark : KeyNestPalette.surfaceLight,
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
          child: InkWell(
            onTap: copyCallback,
            borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
                border: Border.all(
                  color: isDark
                      ? KeyNestPalette.entryBorderDark
                      : KeyNestPalette.entryBorderLight,
                  width: 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Center(
                      child: Icon(
                        icon,
                        size: 22,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.lightIcon,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          isMasked ? '••••••••••••' : value,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFamily: isMonospace
                                ? KeyNestTheme.monoFontFamily
                                : null,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                            letterSpacing: isMasked
                                ? 2.0
                                : (isMonospace ? 0.8 : 0),
                          ),
                          maxLines: maxLines,
                          overflow: maxLines != null
                              ? TextOverflow.ellipsis
                              : null,
                        ),
                      ],
                    ),
                  ),
                  if (onToggleMask != null)
                    IconButton(
                      icon: Icon(
                        isMasked
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        size: 20,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                      onPressed: onToggleMask,
                    ),
                  if (customAction != null && customActionIcon != null)
                    IconButton(
                      icon: Icon(
                        customActionIcon,
                        size: 20,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                      tooltip: customActionTooltip,
                      onPressed: customAction,
                    ),
                  if (trailing != null) ...[trailing!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
