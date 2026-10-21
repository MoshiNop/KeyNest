// ignore_for_file: use_build_context_synchronously, unawaited_futures
import 'dart:async';
import 'dart:math';

import 'package:autofill_service/autofill_service.dart';
import 'package:autofill_shared/credential_matcher.dart';
import 'package:built_collection/built_collection.dart';
import 'package:clock/clock.dart';
import 'package:flinq/flinq.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_dynamic_icon_service.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/add_record_catalog.dart';
import 'package:keynest/ui/screens/keynest_autofill_save_dialog.dart';
import 'package:keynest/ui/screens/keynest_autofill_sheet.dart';
import 'package:keynest/ui/screens/keynest_home_shell.dart';
import 'package:keynest/ui/screens/password_generator.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/ui/widgets/backup_warning_banner.dart';
import 'package:keynest/ui/widgets/keyboard_handler.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_category_picker.dart';
import 'package:keynest/ui/widgets/keynest_chips.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:keynest/ui/widgets/keynest_empty_state.dart';
import 'package:keynest/ui/widgets/keynest_entry_count_header.dart';
import 'package:keynest/ui/widgets/keynest_popup_menu.dart';
import 'package:keynest/ui/widgets/keynest_search_bar.dart';
import 'package:keynest/ui/widgets/keynest_tab_navigation_handler.dart';
import 'package:keynest/ui/widgets/primary_button.dart';
import 'package:keynest/ui/widgets/savefile/save_file_diag_button.dart';
import 'package:keynest/ui/widgets/shortcut/keynest_intents.dart';
import 'package:keynest/utils/biometric_lifecycle_tracker.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:keynest/utils/predefined_icons.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('password_list');

class EntryViewModel implements Comparable<EntryViewModel> {
  EntryViewModel(this.entry, this.kdbxBloc)
    : label = entry.label,
      _labelComparable = entry.label?.toLowerCase() ?? CharConstants.empty,
      groupNames = entry.parent == null
          ? const []
          : _createGroupNames(entry.parent!),
      fileColor = _resolveFileColor(kdbxBloc, entry);

  static const websiteKey = KdbxKeyCommon.URL;

  final KdbxBloc kdbxBloc;
  final KdbxEntry entry;

  late final String? website = _normalizeUrl();
  final String? label;
  final String _labelComparable;
  final List<String> groupNames;
  final Color? fileColor;

  String? get displayAccountIdentifier {
    final user = entry.getString(KdbxKeyCommon.USER_NAME)?.getText();
    if (user != null && user.trim().isNotEmpty) {
      return user.trim();
    }
    final email = entry.getString(KdbxKey('Email'))?.getText();
    if (email != null && email.trim().isNotEmpty) {
      return email.trim();
    }
    return null;
  }

  List<String>? _cachedSearchableValues;
  List<String> get searchableValues {
    if (_cachedSearchableValues != null) {
      return _cachedSearchableValues!;
    }
    final values = <String>[];
    for (final e in entry.stringEntries) {
      final text = e.value?.getText()?.toLowerCase();
      if (text != null && text.isNotEmpty) {
        values.add(text);
      }
    }
    for (final g in groupNames) {
      if (g.isNotEmpty) {
        values.add(g.toLowerCase());
      }
    }
    return _cachedSearchableValues = values;
  }

  static final Map<KdbxFile, Color?> _fileColorCache = <KdbxFile, Color?>{};
  static final Expando<List<String>> _groupNamesCache =
      Expando<List<String>>();

  static Color? _resolveFileColor(KdbxBloc kdbxBloc, KdbxEntry entry) {
    try {
      final file = entry.file;
      if (_fileColorCache.containsKey(file)) {
        return _fileColorCache[file];
      }
      final color = kdbxBloc.fileForKdbxFile(file).openedFile.color;
      _fileColorCache[file] = color;
      return color;
    } catch (_) {
      return null;
    }
  }

  static List<String> _createGroupNames(KdbxGroup group) {
    final cached = _groupNamesCache[group];
    if (cached != null) {
      return cached;
    }
    final names = group.breadcrumbs
        .map((e) => e.name.get() ?? '')
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    _groupNamesCache[group] = names;
    return names;
  }

  String? _normalizeUrl() {
    final url = entry.getString(websiteKey)?.getText()?.trim();
    if (url == null || url.isEmpty) {
      return null;
    }
    try {
      // If the url contains newlines, just take the first line.
      final newlineIdx = url.indexOf('\n');
      final crIdx = url.indexOf('\r');
      var urlToParse = url;
      if (newlineIdx != -1 || crIdx != -1) {
        final cut = (newlineIdx != -1 && crIdx != -1)
            ? (newlineIdx < crIdx ? newlineIdx : crIdx)
            : (newlineIdx != -1 ? newlineIdx : crIdx);
        urlToParse = url.substring(0, cut);
      }
      final lower = urlToParse.toLowerCase();
      if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
        urlToParse = 'http://$urlToParse'; // NON-NLS
      }
      final parsed = Uri.parse(urlToParse);
      final resolved = parsed.resolve('/'); // NON-NLS
      return resolved.toString();
    } catch (e) {
      return null;
    }
  }

  @override
  int compareTo(EntryViewModel other) {
    if (entry == other.entry) {
      return 0;
    }
    return _labelComparable
        .compareTo(other._labelComparable)
        .unlessZero(() => entry.uuid.uuid.compareTo(other.entry.uuid.uuid))
        .unlessZero(
          () =>
              identityHashCode(entry).compareTo(identityHashCode(other.entry)),
        );
  }
}

extension on int {
  int unlessZero(int Function() cb) => this == 0 ? cb() : this;
}

enum VaultSortMode {
  alphabeticalAsc,
  alphabeticalDesc,
  lastModified,
  dateCreated,
}

typedef OnEntrySelected =
    void Function(KdbxEntry entry, EntrySelectionType type);

class PasswordList extends StatelessWidget {
  const PasswordList({
    super.key,
    required this.onEntrySelected,
    this.selectedEntry,
    this.embedded = true,
    this.onCountChanged,
    this.onSelectionModeChanged,
    this.onRegisterNavigationHandler,
  });

  final void Function(int count)? onCountChanged;
  final ValueChanged<bool>? onSelectionModeChanged;
  final ValueChanged<KeyNestTabNavigationHandler>? onRegisterNavigationHandler;

  static const routeSettings = RouteSettings(name: '/passwordList');

  static Route<void> route() => KeyNestHomeShell.route();

  final KdbxEntry? selectedEntry;
  final OnEntrySelected onEntrySelected;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = Provider.of<KdbxBloc>(context);

    final streams = kdbxBloc.openedFilesKdbx.map(
      (file) => file.dirtyObjectsChanged,
    );
    if (streams.isEmpty) {
      Provider.of<Analytics>(context).events.trackPasswordListEmpty();
      final loc = AppLocalizations.of(context);
      return Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: PrimaryButton(
          onPressed: () {
            Navigator.of(
              context,
              rootNavigator: true,
            ).pushAndRemoveUntil(SelectFileScreen.route(), (_) => false);
          },
          child: Text(loc.openFile),
        ),
      );
    }
    return StreamBuilder<bool>(
      stream: Rx.merge(
        streams,
      ).debounceTime(const Duration(milliseconds: 300)).map((x) => true),
      builder: (context, snapshot) {
        @NonNls
        final isAutofill =
            View.maybeOf(context)?.platformDispatcher.defaultRouteName ==
            '/autofill';
        return PasswordListContent(
          appData: context.watch<AppData>(),
          kdbxBloc: kdbxBloc,
          openedKdbxFiles: kdbxBloc.openedFilesKdbx,
          selectedEntry: selectedEntry,
          onEntrySelected: onEntrySelected,
          isAutofillSelector: isAutofill,
          embedded: embedded,
          onCountChanged: onCountChanged,
          onSelectionModeChanged: onSelectionModeChanged,
          onRegisterNavigationHandler: onRegisterNavigationHandler,
        );
      },
    );
  }
}

enum EntrySelectionType {
  /// entry was highlighted (e.g. via search or up/down arrows) must not switch context.
  passiveHighlight,

  /// entry was actively selected by the user (e.g. via tap).
  activeOpen,

  /// entry was newly created and should be discarded if user leaves without saving.
  newEntry,
}

class PasswordListContent extends StatefulWidget {
  const PasswordListContent({
    super.key,
    required this.appData,
    required this.kdbxBloc,
    required this.openedKdbxFiles,
    required void Function(KdbxEntry entry, EntrySelectionType type)
    onEntrySelected,
    required this.isAutofillSelector,
    this.selectedEntry,
    this.embedded = false,
    this.onCountChanged,
    this.onSelectionModeChanged,
    this.onRegisterNavigationHandler,
  }) : _onEntrySelected = onEntrySelected;

  final void Function(int count)? onCountChanged;
  final ValueChanged<bool>? onSelectionModeChanged;
  final ValueChanged<KeyNestTabNavigationHandler>? onRegisterNavigationHandler;

  final AppData appData;
  final KdbxBloc kdbxBloc;
  final List<KdbxFile> openedKdbxFiles;

  @NonNls
  final bool isAutofillSelector;
  final void Function(KdbxEntry entry, EntrySelectionType type)
  _onEntrySelected;
  final KdbxEntry? selectedEntry;
  final bool embedded;

  void onEntrySelected(
    BuildContext context,
    KdbxEntry entry,
    EntrySelectionType type,
  ) {
    if (isAutofillSelector) {
      if (type == EntrySelectionType.activeOpen) {
        final cf = Provider.of<CommonFields>(context, listen: false);
        final username = entry.getString(cf.userName.key)?.getText();
        final email = entry.getString(KdbxKey('Email'))?.getText()?.trim();
        final password = entry.getString(cf.password.key)?.getText();
        final otp = EntryTotpHelper.getLiveTotpCode(entry);
        AutofillService().resultWithDataset(
          id: entry.uuid.uuid,
          label: entry.label,
          username: username,
          email: email?.isNotEmpty == true ? email : null,
          password: password,
          otp: otp,
        );
        context.read<Analytics>().events.trackAutofillSelect();
        return;
      }
    }
    _onEntrySelected(entry, type);
    Provider.of<Analytics>(
      context,
      listen: false,
    ).events.trackSelectEntry(type: type);
  }

  @override
  _PasswordListContentState createState() => _PasswordListContentState();
}

class PasswordListFilterIsolateRunner {
  static List<EntryViewModel> filterEntries(
    AppData appData,
    List<EntryViewModel> allEntries,
    String query, {
    int maxResults = 100,
  }) {
    _logger.info('We have to filter for $query');
    final cleanQuery = query.trim().toLowerCase();
    if (cleanQuery.isEmpty) {
      return allEntries;
    }
    final terms = cleanQuery
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (terms.isEmpty) {
      return allEntries;
    }

    final scored = <MapEntry<EntryViewModel, int>>[];
    for (final entry in allEntries) {
      final score = _scoreEntry(entry, terms);
      if (score > 0) {
        scored.add(MapEntry(entry, score));
      }
    }

    scored.sort((a, b) {
      final scoreCmp = b.value.compareTo(a.value);
      if (scoreCmp != 0) {
        return scoreCmp;
      }
      return a.key.compareTo(b.key);
    });

    return scored.take(maxResults).map((e) => e.key).toList(growable: false);
  }

  static final searchFields = CommonFields.defaultSearchFields;

  static bool matches(
    Set<KdbxKey>? searchFields,
    EntryViewModel entry,
    List<String> filterTerms,
  ) {
    return _scoreEntry(entry, filterTerms) > 0;
  }

  static bool _isSubsequence(String text, String pattern) {
    if (pattern.length < 2) {
      return false;
    }
    if (pattern.length > text.length) {
      return false;
    }
    int pIdx = 0;
    for (int i = 0; i < text.length && pIdx < pattern.length; i++) {
      if (text.codeUnitAt(i) == pattern.codeUnitAt(pIdx)) {
        pIdx++;
      }
    }
    return pIdx == pattern.length;
  }

  static int _scoreEntry(EntryViewModel vm, List<String> terms) {
    final title = vm.label?.toLowerCase() ?? '';
    final username =
        vm.entry.getString(KdbxKeyCommon.USER_NAME)?.getText()?.toLowerCase() ??
        '';
    final email =
        vm.entry.getString(KdbxKey('Email'))?.getText()?.toLowerCase() ?? '';
    final url = vm.website?.toLowerCase() ?? '';
    final notes =
        vm.entry.getString(KdbxKey('Notes'))?.getText()?.toLowerCase() ?? '';
    final tags =
        vm.entry.getString(KdbxKey('Tags'))?.getText()?.toLowerCase() ?? '';

    // Collect all internal values: custom fields, protected fields, card numbers, etc.
    final internalValues = vm.searchableValues;

    int totalScore = 0;

    for (final term in terms) {
      int termScore = 0;

      // 1. Title matching
      if (title == term) {
        termScore = max(termScore, 1000);
      } else if (title.startsWith(term)) {
        termScore = max(termScore, 500);
      } else if (title.contains(term)) {
        termScore = max(termScore, 300);
      } else if (_isSubsequence(title, term)) {
        termScore = max(termScore, 120);
      }

      // 2. Username / Email matching
      final accountId = username.isNotEmpty ? username : email;
      if (accountId == term || username == term || email == term) {
        termScore = max(termScore, 400);
      } else if (accountId.startsWith(term) ||
          username.startsWith(term) ||
          email.startsWith(term)) {
        termScore = max(termScore, 250);
      } else if (accountId.contains(term) ||
          username.contains(term) ||
          email.contains(term)) {
        termScore = max(termScore, 180);
      } else if (_isSubsequence(accountId, term) ||
          _isSubsequence(username, term) ||
          _isSubsequence(email, term)) {
        termScore = max(termScore, 80);
      }

      // 3. URL matching
      if (url.contains(term)) {
        termScore = max(termScore, 160);
      } else if (_isSubsequence(url, term)) {
        termScore = max(termScore, 70);
      }

      // 4. Notes matching
      if (notes.contains(term)) {
        termScore = max(termScore, 150);
      } else if (_isSubsequence(notes, term)) {
        termScore = max(termScore, 60);
      }

      // 5. Tags matching
      if (tags.contains(term)) {
        termScore = max(termScore, 140);
      }

      // 6. Internal content (all other string entries, custom attributes, folder names)
      for (final val in internalValues) {
        if (val.contains(term)) {
          termScore = max(termScore, 130);
          break;
        } else if (_isSubsequence(val, term)) {
          termScore = max(termScore, 50);
        }
      }

      // All terms must match at least one field
      if (termScore == 0) {
        return 0;
      }
      totalScore += termScore;
    }

    return totalScore;
  }
}

class GroupFilterEntry {
  const GroupFilterEntry({required this.group, required this.isRecursive});

  final KdbxGroup group;
  final bool isRecursive;
}

class GroupFilter {
  const GroupFilter({
    this.groups = const [],
    required this.showRecycleBin,
    required this.showActive,
    required String name,
  }) : _name = name,
       nameLoc = null;

  const GroupFilter._({
    required this.showRecycleBin,
    required this.showActive,
    required this.nameLoc,
  }) : groups = const [],
       _name = null;

  static final defaultGroupFilter = GroupFilter._(
    showRecycleBin: false,
    showActive: true,
    nameLoc: (loc) => loc.passwordFilterHideDeleted,
  );
  static final recycleBin = GroupFilter._(
    showRecycleBin: true,
    showActive: false,
    nameLoc: (loc) => loc.passwordFilterOnlyDeleted,
  );

  final List<GroupFilterEntry> groups;

  /// show items which are in the recycle bins.
  final bool showRecycleBin;

  /// show items which are not in recycle bins.
  final bool showActive;

  /// Name to display.
  final String? _name;

  final String Function(AppLocalizations loc)? nameLoc;

  String name(AppLocalizations loc) {
    return _name ?? nameLoc!(loc);
  }

  Iterable<KdbxEntry> getEntries(List<KdbxFile> files) {
    if (groups.isNotEmpty) {
      return groups.expand((groupSelected) {
        final groups = groupSelected.isRecursive
            ? groupSelected.group.getAllGroups()
            : [groupSelected.group];
        if (showRecycleBin && showActive) {
          return groups.expand((g) => g.entries);
        } else if (showActive) {
          return groups
              .where((g) => g == groupSelected.group || g.file.recycleBin != g)
              .expand((g) => g.entries);
        } else if (showRecycleBin) {
          return groups
              .where((g) => g.file.recycleBin == g)
              .expand((g) => g.entries);
        } else {
          throw StateError(
            'Impossible. (showRecycleBin: $showRecycleBin,'
            'showActive: $showActive)',
          );
        }
      });
    }
    return files.expand((f) {
      if (showRecycleBin && showActive) {
        return f.body.rootGroup.getAllEntries();
      } else {
        final recycleBin = f.recycleBin;
        if (showRecycleBin) {
          return recycleBin?.entries ?? [];
        } else {
          final allGroups = f.body.rootGroup.getAllGroups();
          return allGroups
              .where((g) => g != recycleBin && !g.isInRecycleBin())
              .expand((e) => e.entries);
        }
      }
    });
  }
}

class _CancelSearchFilterAction extends Action<CancelSearchFilterIntent> {
  _CancelSearchFilterAction(this.state);

  final _PasswordListContentState state;

  @override
  bool isActionEnabled = false;

  void updateEnabled() {
    final isEnabled = state._filterQuery != null;
    if (isActionEnabled != isEnabled) {
      isActionEnabled = isEnabled;
      notifyActionListeners();
    }
  }

  @override
  bool consumesKey(CancelSearchFilterIntent intent) {
    _logger.fine('_CancelSearchFilterAction.consumesKey() = $isActionEnabled');
    return isActionEnabled;
  }

  @override
  Object? invoke(CancelSearchFilterIntent intent) {
    state._cancelFilter();
    return null;
  }
}

class _PasswordListContentState extends State<PasswordListContent>
    with StreamSubscriberMixin, WidgetsBindingObserver, FutureTaskStateMixin {
  List<EntryViewModel>? _filteredEntries;

  String? get _filterQuery => __filterQuery;

  set _filterQuery(String? filterQuery) {
    __filterQuery = filterQuery;
    cancelSearchFilterAction.updateEnabled();
  }

  String? __filterQuery;
  final _filterTextEditingController = TextEditingController();
  final FocusNode _filterFocusNode = FocusNode();
  final ScrollController _chipsScrollController = ScrollController();
  bool _isSearchExpanded = false;
  bool _keyboardWasVisible = false;
  DateTime? _searchOpenedAt;
  bool _isSelectionMode = false;
  final Set<KdbxEntry> _selectedEntries = <KdbxEntry>{};
  bool _isBulkActionRunning = false;
  bool _isFolderPathVisible = true;
  KdbxGroup? _lastFolder;
  int _lastFolderDepth = 0;
  bool _isNavigatingDeeper = true;
  final Map<KdbxEntry, EntryViewModel> _entryViewModelCache = {};

  int _calculateFolderDepth(KdbxGroup? folder) {
    int depth = 0;
    KdbxGroup? cur = folder;
    while (cur != null) {
      depth++;
      cur = cur.parent;
    }
    return depth;
  }

  void _enterSelectionMode(KdbxEntry entry) {
    HapticFeedback.mediumImpact();
    setState(() {
      _isSelectionMode = true;
      _selectedEntries.add(entry);
    });
    widget.onSelectionModeChanged?.call(true);
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedEntries.clear();
    });
    widget.onSelectionModeChanged?.call(false);
  }

  void _toggleEntrySelection(KdbxEntry entry) {
    setState(() {
      if (_selectedEntries.contains(entry)) {
        _selectedEntries.remove(entry);
      } else {
        _selectedEntries.add(entry);
      }
    });
  }

  void _toggleSelectAll(List<EntryViewModel> visibleEntries) {
    final visibleKdbx = visibleEntries.map((e) => e.entry).toSet();
    final allSelected =
        visibleKdbx.isNotEmpty && _selectedEntries.containsAll(visibleKdbx);
    setState(() {
      if (allSelected) {
        _selectedEntries.removeAll(visibleKdbx);
      } else {
        _selectedEntries.addAll(visibleKdbx);
      }
    });
  }

  bool _areAllSelected(List<EntryViewModel> visibleEntries) {
    if (visibleEntries.isEmpty) {
      return false;
    }
    return visibleEntries.every((e) => _selectedEntries.contains(e.entry));
  }

  Future<void> _handleBulkCopy() async {
    if (_selectedEntries.isEmpty) {
      return;
    }
    final dest = await KeyNestDestinationPickerSheet.show(context);
    if (dest == null || !mounted) {
      return;
    }

    final count = _selectedEntries.length;
    setState(() => _isBulkActionRunning = true);
    try {
      await KeyNestItemTypeHelper.bulkCopyEntries(
        entries: _selectedEntries.toList(),
        targetGroup: dest.group,
        kdbxBloc: widget.kdbxBloc,
      );
      if (!mounted) {
        return;
      }
      final folderName = dest.group.name.get() ?? 'folder';
      final vaultName = KeyNestVaultScope.cleanVaultName(
        widget.kdbxBloc,
        dest.file,
      );
      final isDarkSnack = Theme.of(context).brightness == Brightness.dark;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$count ${count == 1 ? 'item' : 'items'} copied to "$folderName" in $vaultName.',
            style: TextStyle(
              color: isDarkSnack ? const Color(0xFF00315D) : Colors.white,
            ),
          ),
          backgroundColor: isDarkSnack
              ? KeyNestPalette.primaryDark
              : KeyNestPalette.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
      _exitSelectionMode();
      _entryViewModelCache.clear();
      _updateAllEntries();
      KeyNestVaultScope.instance.notifyScopeChanged();
    } catch (e, st) {
      _logger.severe('Failed bulk copy', e, st);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to copy items: $e'),
          backgroundColor: KeyNestPalette.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isBulkActionRunning = false);
      }
    }
  }

  Future<void> _handleBulkMove() async {
    if (_selectedEntries.isEmpty) {
      return;
    }
    final dest = await KeyNestDestinationPickerSheet.show(context);
    if (dest == null || !mounted) {
      return;
    }

    final count = _selectedEntries.length;
    setState(() => _isBulkActionRunning = true);
    try {
      await KeyNestItemTypeHelper.bulkMoveEntries(
        entries: _selectedEntries.toList(),
        targetGroup: dest.group,
        kdbxBloc: widget.kdbxBloc,
      );
      if (!mounted) {
        return;
      }
      final folderName = dest.group.name.get() ?? 'folder';
      final vaultName = KeyNestVaultScope.cleanVaultName(
        widget.kdbxBloc,
        dest.file,
      );
      final isDarkSnack = Theme.of(context).brightness == Brightness.dark;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$count ${count == 1 ? 'item' : 'items'} moved to "$folderName" in $vaultName.',
            style: TextStyle(
              color: isDarkSnack ? const Color(0xFF00315D) : Colors.white,
            ),
          ),
          backgroundColor: isDarkSnack
              ? KeyNestPalette.primaryDark
              : KeyNestPalette.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
      _exitSelectionMode();
      _entryViewModelCache.clear();
      _updateAllEntries();
      KeyNestVaultScope.instance.notifyScopeChanged();
    } catch (e, st) {
      _logger.severe('Failed bulk move', e, st);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to move items: $e'),
          backgroundColor: KeyNestPalette.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isBulkActionRunning = false);
      }
    }
  }

  Future<void> _handleBulkDelete() async {
    if (_selectedEntries.isEmpty) {
      return;
    }
    final count = _selectedEntries.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: KeyNestPalette.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.delete_outline_rounded,
                color: KeyNestPalette.error,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Delete $count ${count == 1 ? 'Entry' : 'Entries'}?',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to delete $count selected ${count == 1 ? 'item' : 'items'}? '
          'They will be moved to the Recycle Bin (or permanently deleted if recycle bin is disabled).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: KeyNestPalette.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _isBulkActionRunning = true);
    try {
      await KeyNestItemTypeHelper.bulkDeleteEntries(
        entries: _selectedEntries.toList(),
        kdbxBloc: widget.kdbxBloc,
      );
      if (!mounted) {
        return;
      }
      final isDarkSnack = Theme.of(context).brightness == Brightness.dark;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$count ${count == 1 ? 'item' : 'items'} deleted.',
            style: TextStyle(
              color: isDarkSnack ? const Color(0xFF00315D) : Colors.white,
            ),
          ),
          backgroundColor: isDarkSnack
              ? KeyNestPalette.primaryDark
              : KeyNestPalette.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
      _exitSelectionMode();
      _entryViewModelCache.clear();
      _updateAllEntries();
      KeyNestVaultScope.instance.notifyScopeChanged();
    } catch (e, st) {
      _logger.severe('Failed bulk delete', e, st);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to delete items: $e'),
          backgroundColor: KeyNestPalette.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isBulkActionRunning = false);
      }
    }
  }

  Widget _buildSelectionToolbar(
    BuildContext context,
    List<EntryViewModel> visibleEntries,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final allSelected = _areAllSelected(visibleEntries);
    final hasSelection = _selectedEntries.isNotEmpty;

    return Material(
      elevation: 8,
      color: isDark ? KeyNestPalette.surfaceContainerDark : Colors.white,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: isDark ? Colors.white12 : Colors.black12,
                width: 1,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top Row: Cancel, Count, Select All
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: isDark ? Colors.white70 : Colors.black87,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                    ),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    label: const Text(
                      'Cancel',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    onPressed: _exitSelectionMode,
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '${_selectedEntries.length} Selected',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        ),
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                    ),
                    icon: Icon(
                      allSelected
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                      size: 20,
                    ),
                    label: Text(
                      allSelected ? 'Deselect All' : 'Select All',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => _toggleSelectAll(visibleEntries),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Divider(height: 1),
              const SizedBox(height: 8),
              // Bottom Row: Action buttons (Copy, Move, Delete)
              Row(
                children: [
                  Expanded(
                    child: _buildToolbarButton(
                      context: context,
                      icon: Icons.copy_rounded,
                      label: 'Copy',
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      onPressed: hasSelection && !_isBulkActionRunning
                          ? _handleBulkCopy
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildToolbarButton(
                      context: context,
                      icon: Icons.drive_file_move_rounded,
                      label: 'Move',
                      color: const Color(0xFF0284C7),
                      onPressed: hasSelection && !_isBulkActionRunning
                          ? _handleBulkMove
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildToolbarButton(
                      context: context,
                      icon: Icons.delete_outline_rounded,
                      label: 'Delete',
                      color: KeyNestPalette.error,
                      isDestructive: true,
                      onPressed: hasSelection && !_isBulkActionRunning
                          ? _handleBulkDelete
                          : null,
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

  Widget _buildToolbarButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onPressed,
    bool isDestructive = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isEnabled = onPressed != null;

    return Material(
      color: isEnabled
          ? color.withValues(alpha: isDark ? 0.16 : 0.08)
          : (isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.03)),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isEnabled
                  ? color.withValues(alpha: 0.25)
                  : (isDark ? Colors.white10 : Colors.black12),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: isEnabled
                    ? color
                    : (isDark ? Colors.white24 : Colors.black26),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: isEnabled
                      ? color
                      : (isDark ? Colors.white24 : Colors.black26),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _sortLabel() {
    switch (KeyNestVaultScope.instance.getSortMode(KeyNestTab.secrets)) {
      case VaultSortMode.alphabeticalAsc:
        return 'Sort: A-Z';
      case VaultSortMode.alphabeticalDesc:
        return 'Sort: Z-A';
      case VaultSortMode.lastModified:
        return 'Sort: Modified';
      case VaultSortMode.dateCreated:
        return 'Sort: Created';
    }
  }

  void _showSortModal(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Text(
                    'Sort Vault Items',
                    style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(),
                RadioGroup<VaultSortMode>(
                  groupValue: KeyNestVaultScope.instance.getSortMode(
                    KeyNestTab.secrets,
                  ),
                  onChanged: (val) {
                    if (val != null) {
                      KeyNestVaultScope.instance.setSortMode(
                        val,
                        KeyNestTab.secrets,
                      );
                      Navigator.pop(ctx);
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<VaultSortMode>(
                        title: const Text('Title (A → Z)'),
                        subtitle: const Text('Alphabetical order'),
                        value: VaultSortMode.alphabeticalAsc,
                      ),
                      RadioListTile<VaultSortMode>(
                        title: const Text('Title (Z → A)'),
                        subtitle: const Text('Reverse alphabetical order'),
                        value: VaultSortMode.alphabeticalDesc,
                      ),
                      RadioListTile<VaultSortMode>(
                        title: const Text('Date Modified'),
                        subtitle: const Text('Recently updated items first'),
                        value: VaultSortMode.lastModified,
                      ),
                      RadioListTile<VaultSortMode>(
                        title: const Text('Date Created'),
                        subtitle: const Text('Newest items first'),
                        value: VaultSortMode.dateCreated,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showVaultSelectionSheet(BuildContext context, KdbxBloc kdbxBloc) {
    final openedFiles = kdbxBloc.openedFilesKdbx;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selectedVault = KeyNestVaultScope.instance.getSelectedVault(
      kdbxBloc,
      KeyNestTab.secrets,
    );

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color:
                              (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                  .withValues(alpha: isDark ? 0.20 : 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.inventory_2_outlined,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Select Vault',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Switch active database or view all',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: Icon(
                    Icons.all_inclusive_rounded,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                  ),
                  title: const Text(
                    'All Vault Items',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    'Displays items from all opened vaults (${openedFiles.length})',
                  ),
                  trailing: selectedVault == null
                      ? Icon(
                          Icons.check_circle_rounded,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        )
                      : null,
                  onTap: () {
                    KeyNestVaultScope.instance.setSelectedVault(
                      kdbxBloc,
                      null,
                      KeyNestTab.secrets,
                    );
                    Navigator.pop(ctx);
                  },
                ),
                if (openedFiles.isNotEmpty)
                  const Divider(indent: 16, endIndent: 16),
                ...openedFiles.map((file) {
                  final isSelected = file == selectedVault;
                  final vaultName = KeyNestVaultScope.cleanVaultName(
                    kdbxBloc,
                    file,
                  );
                  final count = file.body.rootGroup
                      .getAllEntries()
                      .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
                      .length;
                  return ListTile(
                    leading: Icon(
                      Icons.shield_rounded,
                      color: isSelected
                          ? (isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary)
                          : (isDark ? Colors.white70 : Colors.black87),
                    ),
                    title: Text(
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
                    subtitle: Text('$count items'),
                    trailing: isSelected
                        ? Icon(
                            Icons.check_circle_rounded,
                            color: isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary,
                          )
                        : null,
                    onTap: () {
                      KeyNestVaultScope.instance.setSelectedVault(
                        kdbxBloc,
                        file,
                        KeyNestTab.secrets,
                      );
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFolderBreadcrumbsSection(
    BuildContext context,
    KdbxFile vault,
    KdbxGroup currentFolder,
  ) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOutCubic,
      child: _isFolderPathVisible
          ? AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              opacity: _isFolderPathVisible ? 1.0 : 0.0,
              child: _buildFolderBreadcrumbs(context, vault, currentFolder),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildFolderBreadcrumbs(
    BuildContext context,
    KdbxFile vault,
    KdbxGroup currentFolder,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.read<KdbxBloc>();
    final vaultName = KeyNestVaultScope.cleanVaultName(kdbxBloc, vault);

    final crumbs = <KdbxGroup>[];
    KdbxGroup? cur = currentFolder;
    while (cur != null) {
      crumbs.insert(0, cur);
      cur = cur.parent;
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:
            (isDark
                    ? KeyNestPalette.surfaceContainerDark
                    : KeyNestPalette.surfaceLight)
                .withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color:
              (isDark
                      ? KeyNestPalette.cardBorderDark
                      : KeyNestPalette.cardBorderLight)
                  .withValues(alpha: 0.7),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                _isNavigatingDeeper = false;
                KeyNestVaultScope.instance.setCurrentFolder(
                  currentFolder.parent ?? vault.body.rootGroup,
                );
              },
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary)
                          .withValues(alpha: isDark ? 0.20 : 0.1),
                ),
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 13,
                  color: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () {
                      _isNavigatingDeeper = false;
                      KeyNestVaultScope.instance.setCurrentFolder(
                        vault.body.rootGroup,
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 11,
                            color:
                                (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary)
                                    .withValues(
                                      alpha: 0.8,
                                    ),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            vaultName,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (int i = 1; i < crumbs.length; i++) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 12,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () {
                        if (i < crumbs.length - 1) {
                          _isNavigatingDeeper = false;
                        }
                        KeyNestVaultScope.instance.setCurrentFolder(crumbs[i]);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Text(
                          crumbs[i].name.get() ?? 'Folder',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: i == crumbs.length - 1
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: i == crumbs.length - 1
                                ? (isDark
                                      ? KeyNestPalette.textPrimaryDark
                                      : KeyNestPalette.textPrimaryLight)
                                : (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          KeyNestPopupMenuButton<String>(
            tooltip: 'Folder options',
            padding: EdgeInsets.zero,
            iconSize: 18,
            splashRadius: 16,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: Icon(
              Icons.more_vert_rounded,
              size: 16,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
            onSelected: (action) async {
              if (action == 'rename') {
                await _promptRenameFolder(
                  context,
                  kdbxBloc,
                  vault,
                  currentFolder,
                );
              } else if (action == 'subfolder') {
                await _promptCreateSubfolder(
                  context,
                  kdbxBloc,
                  vault,
                  currentFolder,
                );
              } else if (action == 'delete') {
                await _promptDeleteFolder(
                  context,
                  kdbxBloc,
                  vault,
                  currentFolder,
                );
              } else if (action == 'empty_trash') {
                await _promptEmptyTrash(
                  context,
                  kdbxBloc,
                  vault,
                  currentFolder,
                );
              }
            },
            itemBuilder: (context) {
              final isTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(
                currentFolder,
              );
              if (isTrash) {
                return [
                  const PopupMenuItem(
                    value: 'empty_trash',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_forever_rounded,
                          size: 18,
                          color: KeyNestPalette.error,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Empty Trash',
                          style: TextStyle(color: KeyNestPalette.error),
                        ),
                      ],
                    ),
                  ),
                ];
              }
              return [
                const PopupMenuItem(
                  value: 'rename',
                  child: Row(
                    children: [
                      Icon(Icons.drive_file_rename_outline_rounded, size: 18),
                      SizedBox(width: 8),
                      Text('Rename Folder'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'subfolder',
                  child: Row(
                    children: [
                      Icon(Icons.create_new_folder_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('Add Subfolder'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: KeyNestPalette.error,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Delete Folder',
                        style: TextStyle(color: KeyNestPalette.error),
                      ),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
    );
  }

  Future<void> _promptRenameFolder(
    BuildContext context,
    KdbxBloc kdbxBloc,
    KdbxFile kdbxFile,
    KdbxGroup group,
  ) async {
    final textController = TextEditingController(
      text: group.name.get() ?? 'Folder',
    );
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
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
            onPressed: () {
              final val = textController.text.trim();
              if (val.isNotEmpty) {
                Navigator.of(ctx).pop(val);
              }
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && mounted) {
      try {
        group.name.set(newName);
        await kdbxBloc.saveFile(kdbxFile);
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Renamed folder to "$newName".'),
              duration: const Duration(milliseconds: 1800),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Failed to rename folder: $e',
          );
        }
      }
    }
  }

  Future<void> _promptCreateSubfolder(
    BuildContext context,
    KdbxBloc kdbxBloc,
    KdbxFile kdbxFile,
    KdbxGroup parentGroup,
  ) async {
    final textController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Subfolder'),
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
            onPressed: () {
              final val = textController.text.trim();
              if (val.isNotEmpty) {
                Navigator.of(ctx).pop(val);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty && mounted) {
      try {
        kdbxFile.createGroup(parent: parentGroup, name: name);
        await kdbxBloc.saveFile(kdbxFile);
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Created subfolder "$name".'),
              duration: const Duration(milliseconds: 1800),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Failed to create subfolder: $e',
          );
        }
      }
    }
  }

  Future<void> _promptDeleteFolder(
    BuildContext context,
    KdbxBloc kdbxBloc,
    KdbxFile kdbxFile,
    KdbxGroup group,
  ) async {
    final isInsideTrash = group.isInRecycleBin();
    final folderName = group.name.get() ?? 'Folder';

    if (isInsideTrash) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Permanently Delete Folder?'),
          content: Text(
            'Permanently delete folder "$folderName" and all its items?\n\nThis action cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: KeyNestPalette.error,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete Permanently'),
            ),
          ],
        ),
      );

      if (confirmed == true && mounted) {
        try {
          final parent = group.parent ?? kdbxFile.body.rootGroup;
          KeyNestVaultScope.instance.setCurrentFolder(parent);
          kdbxFile.deletePermanently(group);
          await kdbxBloc.saveFile(kdbxFile);
          if (mounted) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Permanently deleted folder "$folderName".'),
                duration: const Duration(milliseconds: 1800),
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            DialogUtils.showErrorDialog(
              context,
              'Error',
              'Failed to delete folder: $e',
            );
          }
        }
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Folder?'),
        content: Text(
          'Delete folder "$folderName" and move its contents to Trash?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: KeyNestPalette.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final parent = group.parent ?? kdbxFile.body.rootGroup;
        KeyNestVaultScope.instance.setCurrentFolder(parent);
        kdbxFile.deleteGroup(group);
        await kdbxBloc.saveFile(kdbxFile);
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Moved folder "$folderName" to Trash.'),
              duration: const Duration(milliseconds: 1800),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          DialogUtils.showErrorDialog(
            context,
            'Error',
            'Failed to delete folder: $e',
          );
        }
      }
    }
  }

  Future<void> _promptEmptyTrash(
    BuildContext context,
    KdbxBloc kdbxBloc,
    KdbxFile kdbxFile,
    KdbxGroup trashGroup,
  ) async {
    final entryCount = trashGroup.getAllEntries().length;
    final subfolderCount = trashGroup.getAllGroups().length - 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Empty Trash?'),
        content: Text(
          'Are you sure you want to permanently delete all items in the Trash '
          '($entryCount ${entryCount == 1 ? 'entry' : 'entries'}, '
          '$subfolderCount ${subfolderCount == 1 ? 'subfolder' : 'subfolders'})?\n\n'
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: KeyNestPalette.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Empty Trash'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final groupsToDelete = List<KdbxGroup>.from(trashGroup.groups);
        for (int i = 0; i < groupsToDelete.length; i++) {
          kdbxFile.deletePermanently(groupsToDelete[i]);
          if (i > 0 && i % 25 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }
        final entriesToDelete = List<KdbxEntry>.from(trashGroup.entries);
        for (int i = 0; i < entriesToDelete.length; i++) {
          kdbxFile.deletePermanently(entriesToDelete[i]);
          if (i > 0 && i % 25 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }
        await kdbxBloc.saveFile(kdbxFile);
        _entryViewModelCache.clear();
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Trash emptied successfully.'),
              duration: Duration(milliseconds: 1800),
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
      }
    }
  }

  Widget _buildSubfolderCard(BuildContext context, KdbxGroup g) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(g);
    final itemCount = isTrash
        ? g.entries.length
        : g.entries
              .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
              .length;
    final childGroupCount = isTrash
        ? g.groups.length
        : g.groups
              .where(
                (child) =>
                    child == child.file.recycleBin || !child.isInRecycleBin(),
              )
              .length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: isDark ? KeyNestPalette.cardDark : KeyNestPalette.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            if (_isSelectionMode) {
              _exitSelectionMode();
            }
            _isNavigatingDeeper = true;
            KeyNestVaultScope.instance.setCurrentFolder(g);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color:
                        (isTrash
                                ? KeyNestPalette.error
                                : (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary))
                            .withValues(alpha: isDark ? 0.20 : 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isTrash
                        ? Icons.delete_outline_rounded
                        : Icons.folder_rounded,
                    color: isTrash
                        ? KeyNestPalette.error
                        : (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.name.get() ?? 'Folder',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        '$itemCount items${childGroupCount > 0 ? ' • $childGroupCount subfolders' : ''}',
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
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: Colors.grey,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  final ValueNotifier<GroupFilter> _groupFilterNotifier = ValueNotifier(
    GroupFilter.defaultGroupFilter,
  );

  IntentActionRegistration? _actionsRegistration;

  late final _CancelSearchFilterAction cancelSearchFilterAction =
      _CancelSearchFilterAction(this);

  GroupFilter get _groupFilter => _groupFilterNotifier.value;

  List<EntryViewModel>? _allEntries;
  int? _lastReportedCount;

  /// on android while requesting autofill.
  AutofillMetadata? _autofillMetadata;

  AutofillServiceStatus? _autofillStatus;

  /// iOS's answer to the same question [_autofillStatus] asks on android.
  /// Null until asked, and on every other platform.
  bool? _iosAutofillEnabled;
  bool? _dismissedAutofillSuggestion;

  @override
  void initState() {
    super.initState();
    _logger.finer('Initializing password list content.');
    WidgetsBinding.instance.addObserver(this);
    KeyNestVaultScope.instance.addListener(_onVaultScopeChanged);
    if (!KeyNestVaultScope.instance.isInitialized) {
      KeyNestVaultScope.instance.init().then((_) {
        if (mounted) {
          _updateAllEntries();
        }
      });
    }
    _updateAllEntries();
    _groupFilterNotifier.addListener(_updateAllEntries);
    _updateAutofillPrefs();
    _updateAutofillMetadata();
    _updateDismissedBanners(widget.appData);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      BiometricLifecycleTracker.instance.stop(
        'post_auth_entry',
        'first_usable_frame',
      );
      BiometricLifecycleTracker.instance.stop(
        'vault_creation',
        'first_usable_frame',
      );
      BiometricLifecycleTracker.instance.stop(
        'open_existing_vault',
        'first_usable_frame',
      );
      if (mounted) {
        KeyNestAutofillSaveDialog.checkAndShow(context, widget.kdbxBloc);
      }
    });
    widget.onRegisterNavigationHandler?.call(
      KeyNestTabNavigationHandler(
        isSelectionActive: () => _isSelectionMode,
        exitSelection: _exitSelectionMode,
        isSearchActive: () =>
            _isSearchExpanded ||
            (_filterQuery != null && _filterQuery!.isNotEmpty),
        clearSearch: () {
          _cancelFilter();
          _filterFocusNode.unfocus();
        },
      ),
    );
  }

  Timer? _searchDebounceTimer;

  void _onSearchQueryChanged(String newQuery) {
    _searchDebounceTimer?.cancel();
    if (newQuery.isEmpty) {
      _updateFilterQuery(newQuery);
      return;
    }
    _searchDebounceTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        _updateFilterQuery(newQuery);
      }
    });
  }

  void _onVaultScopeChanged() {
    if (mounted) {
      if (KeyNestPlatform.isDesktopOrWeb) {
        final globalQuery = KeyNestVaultScope.instance.searchQuery;
        if (_filterTextEditingController.text != globalQuery) {
          _filterTextEditingController.text = globalQuery;
          _updateFilterQuery(globalQuery);
        }
      }
      _entryViewModelCache.clear();
      _updateAllEntries();
    }
  }

  void _onFilterFocusChanged() {
    // Focus changes alone should not auto-collapse the search field while in use.
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottomInset =
        WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .firstOrNull
            ?.viewInsets
            .bottom ??
        0;

    if (bottomInset > 0) {
      _keyboardWasVisible = true;
    } else if (bottomInset == 0 && _isSearchExpanded && mounted) {
      final justOpened =
          _searchOpenedAt != null &&
          clock.now().difference(_searchOpenedAt!).inMilliseconds < 600;

      // Close only if the keyboard was previously visible and is now dismissed
      if (_keyboardWasVisible && !justOpened) {
        _keyboardWasVisible = false;
        if (_filterTextEditingController.text.trim().isEmpty) {
          setState(() {
            _isSearchExpanded = false;
          });
          _filterFocusNode.unfocus();
        }
      }
    }
  }

  void _updateDismissedBanners(AppData data) {
    _dismissedLocalFilesReady = true;
    setState(() {
      _dismissedLocalFiles = data.dismissedBackupLocalFiles;
      _dismissedAutofillSuggestion = data.dismissedAutofillSuggestion;
    });
  }

  Future<void> _updateAutofillPrefs() async {
    if (KeyNestPlatform.isWeb) {
      return;
    }
    if (KeyNestPlatform.isIOS) {
      final enabled = await context
          .read<KdbxBloc>()
          .autofillIdentities
          .isEnabled();
      if (!mounted || _iosAutofillEnabled == enabled) {
        return;
      }
      setState(() {
        _iosAutofillEnabled = enabled;
      });
    } else {
      final status = await AutofillService().status();
      if (!mounted || _autofillStatus == status) {
        return;
      }
      setState(() {
        _autofillStatus = status;
      });
    }
  }

  void _updateAutofillMetadata() {
    if (widget.isAutofillSelector) {
      AutofillService().getAutofillMetadata().then((value) {
        if (_autofillMetadata == value || !mounted) {
          return;
        }
        setState(() {
          _autofillMetadata = value;
        });
        final val = value?.let(_applyAutofillFilter) ?? 0;
        context.read<Analytics>().events.trackAutofillFilter(
          filter: '${value?.searchTerm?.isNotEmpty}',
          value: val,
        );
      });
    }
  }

  /// Narrows the list to the credentials which belong to the requesting site
  /// or app, matched by registrable domain rather than by substring.
  ///
  /// Falls back to the old behaviour — the domain typed into the search box,
  /// which searches every field — when nothing matches by url. Plenty of
  /// entries carry the site only in their title, and offering nothing at all
  /// would be worse than offering too much.
  int _applyAutofillFilter(AutofillMetadata metadata) {
    final matches = CredentialMatcher.instance.rank(
      metadata.credentialRequests,
      _allEntries!,
      (entry) => entry.entry.autofillUrls,
    );
    if (matches.isNotEmpty) {
      _autofillMatchedByUrl = true;
      return _showFilteredEntries(CharConstants.empty, matches);
    }

    _autofillMatchedByUrl = false;
    return metadata.searchTerm?.let((term) {
          _filterTextEditingController.text = term;
          _filterTextEditingController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: term.length,
          );
          return _updateFilterQuery(term);
        }) ??
        0;
  }

  /// Whether the list currently shows url matches rather than a text search.
  bool _autofillMatchedByUrl = false;

  void _updateAllEntries() {
    final watch = Stopwatch()..start();
    final selectedVault = KeyNestVaultScope.instance.getSelectedVault(
      widget.kdbxBloc,
      KeyNestTab.secrets,
    );
    final Iterable<KdbxEntry> sourceEntries;

    if (selectedVault == null) {
      sourceEntries = _groupFilter.getEntries(widget.openedKdbxFiles);
    } else {
      final currentFolder =
          KeyNestVaultScope.instance.getCurrentFolder(
            widget.kdbxBloc,
            KeyNestTab.secrets,
          ) ??
          selectedVault.body.rootGroup;
      final isTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(currentFolder);
      if (isTrash) {
        sourceEntries = currentFolder.entries;
      } else if (_filterQuery != null && _filterQuery!.isNotEmpty) {
        sourceEntries = currentFolder.getAllEntries().where(
          (e) => !KeyNestItemTypeHelper.isEntryInTrash(e),
        );
      } else {
        sourceEntries = currentFolder.entries.where(
          (e) => !KeyNestItemTypeHelper.isEntryInTrash(e),
        );
      }
    }

    final seenEntries = <KdbxEntry>{};
    final uniqueSourceEntries = sourceEntries.where((e) => seenEntries.add(e));

    final allEntries =
        uniqueSourceEntries
            .map<EntryViewModel>((e) {
              final cached = _entryViewModelCache[e];
              if (cached != null && cached.label == e.label) {
                return cached;
              }
              final vm = EntryViewModel(e, widget.kdbxBloc);
              _entryViewModelCache[e] = vm;
              return vm;
            })
            .toList(growable: true);
    _sortEntries(allEntries, KeyNestVaultScope.instance.sortMode);
    _allEntries = allEntries;
    if (_entryViewModelCache.length > allEntries.length * 2) {
      final activeEntries = sourceEntries.toSet();
      _entryViewModelCache.removeWhere((k, _) => !activeEntries.contains(k));
    }
    if (_filterQuery != null && _filterQuery!.isNotEmpty) {
      _filteredEntries = PasswordListFilterIsolateRunner.filterEntries(
        widget.appData,
        _allEntries!,
        _filterQuery!,
      );
    } else {
      _filteredEntries = null;
    }
    watch.stop();
    _logger.finer(
      'Rebuilding PasswordList. (${_allEntries!.length} entries)'
      ' ${watch.elapsedMilliseconds}ms',
    );
    setState(() {});
  }

  static void _sortEntries(List<EntryViewModel> list, VaultSortMode sortMode) {
    switch (sortMode) {
      case VaultSortMode.alphabeticalAsc:
        list.sort((a, b) => a.compareTo(b));
        break;
      case VaultSortMode.alphabeticalDesc:
        list.sort((a, b) => b.compareTo(a));
        break;
      case VaultSortMode.lastModified:
        list.sort((a, b) {
          final aMod =
              a.entry.times.lastModificationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final bMod =
              b.entry.times.lastModificationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return bMod.compareTo(aMod);
        });
        break;
      case VaultSortMode.dateCreated:
        list.sort((a, b) {
          final aCreated =
              a.entry.times.creationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final bCreated =
              b.entry.times.creationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return bCreated.compareTo(aCreated);
        });
        break;
    }
  }

  @override
  void didUpdateWidget(PasswordListContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appData != widget.appData) {
      _updateDismissedBanners(widget.appData);
    }
    _entryViewModelCache.clear();
    _updateAllEntries();
  }

  void _selectAllFilter() =>
      _filterTextEditingController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _filterTextEditingController.text.length,
      );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _logger.finer('didChangeAppLifecycleState($state)');
    if (state == AppLifecycleState.resumed) {
      if (mounted) {
        KeyNestAutofillSaveDialog.checkAndShow(context, widget.kdbxBloc);
      }
      setState(() {
        _selectAllFilter();
      });
      _updateAutofillPrefs();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    subscriptions.cancelSubscriptions();
    final shortcuts = Provider.of<KeyboardShortcutEvents?>(context);
    _actionsRegistration?.dispose();
    _actionsRegistration = shortcuts?.registerActions({
      SearchIntent: CallbackAction(
        onInvoke: (intent) => setState(() {
          _isSearchExpanded = true;
          if (_filterQuery == null || _filteredEntries == null) {
            _filterQuery ??= CharConstants.empty;
            _filteredEntries = _allEntries;
          }
          _selectAllFilter();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _filterFocusNode.requestFocus();
          });
        }),
      ),
      MoveUpIntent: CallbackAction(onInvoke: (intent) => _selectNextEntry(-1)),
      MoveDownIntent: CallbackAction(onInvoke: (intent) => _selectNextEntry(1)),
      CancelSearchFilterIntent: cancelSearchFilterAction,
    });
  }

  @Deprecated('was only a workaround needed for manual shortcut handling')
  // ignore: unused_element
  bool _isFocusInForeignTextField() {
    final widget =
        WidgetsBinding.instance.focusManager.primaryFocus?.context?.widget;
    if (widget == null) {
      return false;
    }
    if (widget is EditableText) {
      if (widget.controller == _filterTextEditingController) {
        return false;
      }
      return true;
    }
    return false;
  }

  void _selectNextEntry(int next) {
    final entries = _filteredEntries ?? _allEntries!;
    if (entries.isEmpty) {
      return;
    }
    final idx = entries.indexWhere((a) => a.entry == widget.selectedEntry);
    // right now we ignore the fact that the user might select a list item which is not in view.
    // https://github.com/flutter/flutter/issues/12319
    if (idx < 0) {
      widget.onEntrySelected(
        context,
        entries.first.entry,
        EntrySelectionType.passiveHighlight,
      );
    } else {
      // new Index, modulo entry length to make sure we wrap around the end..
      final newIndex = (idx + next) % entries.length;
      widget.onEntrySelected(
        context,
        entries[newIndex].entry,
        EntrySelectionType.passiveHighlight,
      );
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _logger.info('Disposing isolate runner.');
    _filterFocusNode.removeListener(_onFilterFocusChanged);
    _filterFocusNode.dispose();
    _filterTextEditingController.dispose();
    _chipsScrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    KeyNestVaultScope.instance.removeListener(_onVaultScopeChanged);
    _groupFilterNotifier.removeListener(_updateAllEntries);
    _groupFilterNotifier.dispose();
    _actionsRegistration?.dispose();
    super.dispose();
  }

  void _cancelFilter() {
    setState(() {
      _filterQuery = null;
      _filteredEntries = null;
      _isSearchExpanded = false;
      _filterTextEditingController.clear();
    });
  }

  int _updateFilterQuery(String newQuery) {
    // a text search replaces whatever the url matcher put on screen.
    _autofillMatchedByUrl = false;
    final entries = PasswordListFilterIsolateRunner.filterEntries(
      widget.appData,
      _allEntries!,
      newQuery,
    );
    if (!mounted) {
      _logger.severe(
        'No longer mounted after updating filter query.',
        null,
        StackTrace.current,
      );
      return 0;
    }
    return _showFilteredEntries(newQuery, entries);
  }

  int _showFilteredEntries(String query, List<EntryViewModel> entries) {
    setState(() {
      _filterQuery = query;
      _filteredEntries = entries;
      if (!widget.embedded &&
          _filteredEntries!.isNotEmpty &&
          (widget.selectedEntry == null ||
              !_filteredEntries!
                  .map((e) => e.entry)
                  .contains(widget.selectedEntry))) {
        widget.onEntrySelected(
          context,
          _filteredEntries!.first.entry,
          EntrySelectionType.passiveHighlight,
        );
      }
    });
    return entries.length;
  }

  List<Widget>? _buildGroupFilterPrefix() {
    if (_groupFilter == GroupFilter.defaultGroupFilter) {
      return null;
    }
    final loc = AppLocalizations.of(context);
    return [
      MaterialBanner(
        backgroundColor:
            (Theme.of(context).brightness == Brightness.dark
                    ? KeyNestTokens.primaryAccent
                    : KeyNestTokens.lightPrimary)
                .withValues(alpha: 0.15),
        content: Text(_groupFilter.name(loc)),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              _groupFilterNotifier.value = GroupFilter.defaultGroupFilter;
            },
            child: Text(loc.clear),
          ),
        ],
      ),
    ];
  }

  List<Widget>? _buildAutofillListPrefix() {
    if (!widget.isAutofillSelector) {
      _logger.info(
        'not autofill: ${View.maybeOf(context)?.platformDispatcher.defaultRouteName}',
      );
      return null;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final meta = _autofillMetadata;
    final term = meta?.searchTerm ?? 'Current App / Site';

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? KeyNestPalette.cardDark : KeyNestPalette.cardLight,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color:
                  (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                      .withValues(alpha: 0.35),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color:
                    (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary)
                        .withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                              .withValues(alpha: isDark ? 0.20 : 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.shield_rounded,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'KeyNest Autofill Active',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: KeyNestPalette.success.withValues(
                                  alpha: 0.15,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                _autofillMatchedByUrl
                                    ? 'Domain Matched'
                                    : 'Active',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: KeyNestPalette.success,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Select any account below to autofill into $term',
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
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          KeyNestAutofillSheet.route(
                            kdbxBloc: widget.kdbxBloc,
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                        foregroundColor: isDark
                            ? const Color(0xFF00315D)
                            : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      icon: Icon(
                        Icons.flash_on_rounded,
                        size: 16,
                        color: isDark ? const Color(0xFF00315D) : Colors.white,
                      ),
                      label: Text(
                        'Open Autofill Sheet',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFF00315D)
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final generated = await Navigator.of(context)
                          .push<String>(
                            PasswordGeneratorScreen.route(
                              finishButton: FinishButtonStyle.done,
                            ),
                          );
                      if (generated != null && generated.isNotEmpty) {
                        await AutofillService().resultWithDataset(
                          label: 'Generated Password',
                          username: '',
                          password: generated,
                        );
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    icon: const Icon(Icons.key_rounded, size: 16),
                    label: const Text(
                      'Generate',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget>? _buildListPrefix() {
    final kdbxBloc = Provider.of<KdbxBloc>(context);
    final unsupportedWrite = kdbxBloc.openedFilesWithSources.firstOrNullWhere(
      (f) => f.value.dirtyObjects.isNotEmpty && !f.key.supportsWrite,
    );
    if (unsupportedWrite == null) {
      return null;
    }
    return [UnsupportedWrite(source: unsupportedWrite.key)];
  }

  BuiltList<String>? _dismissedLocalFiles;
  bool _dismissedLocalFilesReady = false;

  List<Widget>? _buildBackupWarningBanners() {
    final kdbxBloc = context.watch<KdbxBloc>();
    final loc = AppLocalizations.of(context);
    final localFiles = kdbxBloc.openedFilesWithSources.where(
      (e) => e.key is FileSourceLocal,
    );
    final localFiles3 = localFiles
        .where(
          (file) =>
              file.value.body.rootGroup
                  .getAllGroups()
                  .where((element) => element != file.value.recycleBin)
                  .expand((element) => element.getAllEntries())
                  .length >=
              3,
        )
        .where(
          (element) =>
              !(_dismissedLocalFiles?.contains(element.key.uuid) ?? false),
        );
    if (localFiles3.isNotEmpty && _dismissedLocalFilesReady) {
      final file = localFiles3.first;
      final analytics = context.watch<Analytics>();
      analytics.events.trackBackupBanner(BannerAction.shown);
      return [
        BackupBanner(
          loc.backupWarningMessage(file.key.displayName),
          backupWidget: SaveFileAsDialogButton(
            file: kdbxBloc.fileForFileSource(file.key)!,
            onSave: (saveFuture) {
              asyncRunTask((progress) async {
                analytics.events.trackBackupBanner(BannerAction.saved);
                await saveFuture;
              }, label: loc.saving);
            },
            child: Text(loc.backupButton),
          ),
          dismissText: loc.dismissBackupButton,
          onDismiss: () {
            analytics.events.trackBackupBanner(BannerAction.dismissed);
            context.read<AppDataBloc>().update(
              (builder, data) => builder.dismissedBackupLocalFiles =
                  data.dismissedBackupLocalFiles?.toBuilder() ??
                        BuiltList<String>().toBuilder()
                    ..add(file.key.uuid),
            );
          },
        ),
      ];
    }
    return null;
  }

  List<Widget>? _buildAutofillSuggestBanners() {
    // Two platforms, one banner. Android asks its own autofill service whether
    // it is the current one; iOS asks whether the credential provider is
    // switched on in Settings — the same question, and until it is answered
    // yes, autofill silently does nothing on either.
    // Both compare against a value that is null until asked, so neither shows
    // the banner before the answer is in.
    final isOff = KeyNestPlatform.isIOS
        ? _iosAutofillEnabled == false
        : _autofillStatus == AutofillServiceStatus.disabled;
    if (!isOff) {
      return null;
    }
    if (_dismissedAutofillSuggestion == true) {
      return null;
    }
    final loc = AppLocalizations.of(context);
    final analytics = context.watch<Analytics>();
    return [
      MaterialBanner(
        content: Text(loc.enableAutofillSuggestionBanner),
        actions: [
          TextButton(
            onPressed: () async {
              await context.read<AppDataBloc>().update((builder, data) {
                builder.dismissedAutofillSuggestion = true;
              });
              analytics.events.trackAutofillBanner(BannerAction.dismissed);
            },
            child: Text(loc.dismissAutofillSuggestionBannerButton),
          ),
          TextButton(
            onPressed: () async {
              if (KeyNestPlatform.isIOS) {
                await context
                    .read<KdbxBloc>()
                    .autofillIdentities
                    .requestEnable();
              } else {
                await AutofillService().requestSetAutofillService();
              }
              await _updateAutofillPrefs();
              analytics.events.trackAutofillBanner(BannerAction.saved);
            },
            child: Text(loc.enableAutofillSuggestionBannerButton),
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final scope = KeyNestVaultScope.instance;
    final kdbxBloc = Provider.of<KdbxBloc>(context);

    final selectedVault = scope.getSelectedVault(kdbxBloc);
    final currentFolder = selectedVault != null
        ? (scope.getCurrentFolder(kdbxBloc) ?? selectedVault.body.rootGroup)
        : null;
    final currentDepth = _calculateFolderDepth(currentFolder);
    if (currentFolder != _lastFolder) {
      _isNavigatingDeeper = currentDepth >= _lastFolderDepth;
      _lastFolderDepth = currentDepth;
      _lastFolder = currentFolder;
      _isFolderPathVisible = true;
    }
    final isCurrentFolderTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(
      currentFolder,
    );
    final subfolders =
        (selectedVault != null && currentFolder != null && _filterQuery == null)
        ? KeyNestItemTypeHelper.sortGroupsWithTrashLast(
            currentFolder.groups.where((g) {
              if (isCurrentFolderTrash) {
                return true;
              }
              if (g == g.file.recycleBin) {
                return true;
              }
              return !g.isInRecycleBin();
            }),
          )
        : <KdbxGroup>[];

    final rawEntries = _filteredEntries ?? _allEntries;
    var entries = rawEntries;
    if (scope.favoritesOnly && entries != null) {
      entries = entries
          .where(
            (e) =>
                e.entry.getString(KdbxKey('is_favorite'))?.getText() == 'true',
          )
          .toList();
    }
    if (scope.selectedCategory != null && entries != null) {
      entries = entries
          .where(
            (e) =>
                KeyNestItemTypeHelper.getCategory(e.entry).toLowerCase() ==
                scope.selectedCategory!.toLowerCase(),
          )
          .toList();
    }

    final currentDisplayCount = entries?.length ?? 0;
    if (widget.onCountChanged != null &&
        _lastReportedCount != currentDisplayCount) {
      _lastReportedCount = currentDisplayCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onCountChanged!(currentDisplayCount);
        }
      });
    }

    if (entries != null) {
      if (identical(entries, _allEntries)) {
        // _allEntries is already pre-sorted by _updateAllEntries according to scope.sortMode.
      } else {
        final sortedList = List<EntryViewModel>.from(entries);
        _sortEntries(sortedList, scope.sortMode);
        entries = sortedList;
      }
    }

    final listPrefix = [
      ...?[
        _buildBackupWarningBanners,
        _buildAutofillSuggestBanners,
      ].map((e) => e()).whereNotNull().firstOrNull,
      ...?_buildGroupFilterPrefix(),
      ...?_buildAutofillListPrefix(),
      ...?_buildListPrefix(),
    ];

    final hasEntriesHeader = entries != null && entries.isNotEmpty;
    final totalItemsCount =
        1 +
        subfolders.length +
        (entries?.length ?? 0) +
        (hasEntriesHeader ? 1 : 0);

    final isSearchActive =
        _isSearchExpanded || (_filterQuery != null && _filterQuery!.isNotEmpty);

    final childContent = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Dismiss keyboard if user actively scrolls the vertical entries list
        if (notification.metrics.axis == Axis.vertical) {
          if (notification is UserScrollNotification) {
            if (_filterFocusNode.hasFocus) {
              _filterFocusNode.unfocus();
            }
            if (notification.direction == ScrollDirection.reverse &&
                _isFolderPathVisible &&
                notification.metrics.pixels > 20) {
              setState(() {
                _isFolderPathVisible = false;
              });
            } else if (notification.direction == ScrollDirection.forward &&
                !_isFolderPathVisible) {
              setState(() {
                _isFolderPathVisible = true;
              });
            }
          } else if (notification is ScrollUpdateNotification) {
            if (notification.metrics.pixels <= 10 && !_isFolderPathVisible) {
              setState(() {
                _isFolderPathVisible = true;
              });
            }
          }
        }
        return false;
      },
      child: Column(
        children: [
          if (!KeyNestPlatform.isDesktopOrWeb)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
            child: SingleChildScrollView(
              controller: _chipsScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  KeyNestExpandableSearchChip(
                    controller: _filterTextEditingController,
                    focusNode: _filterFocusNode,
                    isExpanded: isSearchActive,
                    hintText: 'Search vault...',
                    onChanged: (newQuery) {
                      _onSearchQueryChanged(newQuery);
                    },
                    onExpand: () {
                      _searchOpenedAt = clock.now();
                      _keyboardWasVisible = false;
                      setState(() {
                        _isSearchExpanded = true;
                      });
                      if (_chipsScrollController.hasClients &&
                          _chipsScrollController.offset > 0) {
                        _chipsScrollController.animateTo(
                          0,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                      }
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _isSearchExpanded) {
                          _filterFocusNode.requestFocus();
                        }
                      });
                    },
                    onCollapse: () {
                      _cancelFilter();
                      _filterFocusNode.unfocus();
                      setState(() {
                        _isSearchExpanded = false;
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  KeyNestChip(
                    label: selectedVault == null
                        ? 'All Vault Items'
                        : KeyNestVaultScope.cleanVaultName(
                            kdbxBloc,
                            selectedVault,
                          ),
                    icon: Icons.keyboard_arrow_down_rounded,
                    isSelected: selectedVault != null,
                    onTap: () => _showVaultSelectionSheet(context, kdbxBloc),
                  ),
                  const SizedBox(width: 8),
                  KeyNestChip(
                    label: _sortLabel(),
                    icon: Icons.sort_rounded,
                    isSelected: scope.sortMode != VaultSortMode.alphabeticalAsc,
                    onTap: () => _showSortModal(context),
                  ),
                  const SizedBox(width: 8),
                  KeyNestChip(
                    label: scope.selectedCategory ?? 'Category',
                    icon: Icons.keyboard_arrow_down_rounded,
                    isSelected: scope.selectedCategory != null,
                    onTap: () async {
                      final cat = await KeyNestCategoryPicker.show(
                        context,
                        selectedCategory: scope.selectedCategory,
                      );
                      if (cat == null || cat == 'All') {
                        scope.setSelectedCategory(null);
                      } else {
                        scope.setSelectedCategory(cat);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  KeyNestChip(
                    label: 'Favorites',
                    icon: Icons.star_rounded,
                    isSelected: scope.favoritesOnly,
                    onTap: () {
                      scope.setFavoritesOnly(!scope.favoritesOnly);
                    },
                  ),
                  if (scope.selectedCategory != null) ...[
                    const SizedBox(width: 8),
                    KeyNestChip(
                      label: 'Clear category',
                      icon: Icons.close_rounded,
                      onTap: () {
                        scope.setSelectedCategory(null);
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (selectedVault != null &&
              currentFolder != null &&
              currentFolder != selectedVault.body.rootGroup)
            _buildFolderBreadcrumbsSection(
              context,
              selectedVault,
              currentFolder,
            ),
          const SizedBox(height: 4),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final isIncoming =
                    child.key == ValueKey(currentFolder?.uuid.uuid ?? 'root');
                final isForward = _isNavigatingDeeper;
                final Offset beginOffset = isIncoming
                    ? (isForward
                          ? const Offset(0.2, 0.0)
                          : const Offset(-0.2, 0.0))
                    : (isForward
                          ? const Offset(-0.2, 0.0)
                          : const Offset(0.2, 0.0));

                final slideAnimation =
                    Tween<Offset>(
                      begin: beginOffset,
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeInOutCubic,
                      ),
                    );

                return SlideTransition(
                  position: slideAnimation,
                  child: FadeTransition(
                    opacity: animation,
                    child: child,
                  ),
                );
              },
              child: KeyedSubtree(
                key: ValueKey(currentFolder?.uuid.uuid ?? 'root'),
                child: ProgressOverlay(
                  task: task,
                  child: ((_allEntries?.isEmpty ?? true) && subfolders.isEmpty)
                      ? KeyNestEmptyState.secrets(
                          onAdd: () {
                            final entry = kdbxBloc.createEntry(
                              file: selectedVault,
                              group: currentFolder,
                            );
                            widget.onEntrySelected(
                              context,
                              entry,
                              EntrySelectionType.newEntry,
                            );
                          },
                        )
                      : (subfolders.isEmpty &&
                            (entries == null || entries.isEmpty))
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.search_off_rounded,
                                size: 48,
                                color: Colors.grey,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _filterQuery != null
                                    ? 'No matching secrets found'
                                    : 'This folder is empty',
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 16,
                                ),
                              ),
                              if (_filterQuery == null) ...[
                                const SizedBox(height: 12),
                                ElevatedButton.icon(
                                  icon: Icon(
                                    Icons.add_rounded,
                                    color: isDark
                                        ? const Color(0xFF00315D)
                                        : Colors.white,
                                  ),
                                  label: Text(
                                    'Add Entry',
                                    style: TextStyle(
                                      color: isDark
                                          ? const Color(0xFF00315D)
                                          : Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary,
                                    foregroundColor: isDark
                                        ? const Color(0xFF00315D)
                                        : Colors.white,
                                  ),
                                  onPressed: () {
                                    final entry = kdbxBloc.createEntry(
                                      file: selectedVault,
                                      group: currentFolder,
                                    );
                                    widget.onEntrySelected(
                                      context,
                                      entry,
                                      EntrySelectionType.newEntry,
                                    );
                                  },
                                ),
                              ],
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.only(
                            bottom: _isSelectionMode ? 16 : 96,
                          ),
                          itemCount: totalItemsCount,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              if (listPrefix.isEmpty) {
                                return const SizedBox();
                              }
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: listPrefix,
                              );
                            }
                            index--;

                            // Subfolders
                            if (index < subfolders.length) {
                              return _buildSubfolderCard(
                                context,
                                subfolders[index],
                              );
                            }
                            index -= subfolders.length;

                            if (hasEntriesHeader) {
                              if (index == 0) {
                                final count = entries!.length;
                                return KeyNestEntryCountHeader(
                                  count: count,
                                  singularLabel: 'entry',
                                  pluralLabel: 'entries',
                                  padding: EdgeInsets.fromLTRB(
                                    20,
                                    subfolders.isNotEmpty ? 14 : 6,
                                    20,
                                    6,
                                  ),
                                );
                              }
                              index--;
                            }

                            final entry = entries![index];
                            final openedFile = kdbxBloc.fileForKdbxFile(
                              entry.entry.file,
                            );
                            final fileColor = openedFile.openedFile.color;
                            return PasswordEntryListTileWrapper(
                              entry: entry,
                              fileColor: fileColor,
                              filterQuery: _filterQuery,
                              selectedEntry: widget.selectedEntry,
                              isSelectionMode: _isSelectionMode,
                              isItemSelected: _selectedEntries.contains(
                                entry.entry,
                              ),
                              onToggleSelection: () =>
                                  _toggleEntrySelection(entry.entry),
                              onLongPress: () {
                                if (!_isSelectionMode) {
                                  _enterSelectionMode(entry.entry);
                                } else {
                                  _toggleEntrySelection(entry.entry);
                                }
                              },
                              onEntrySelected:
                                  (
                                    KdbxEntry entry,
                                    EntrySelectionType type,
                                  ) {
                                    widget.onEntrySelected(
                                      context,
                                      entry,
                                      type,
                                    );
                                  },
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
          if (_isSelectionMode) _buildSelectionToolbar(context, entries ?? []),
        ],
      ),
    );

    if (widget.onRegisterNavigationHandler != null) {
      return childContent;
    }

    return PopScope(
      canPop:
          !_isSearchExpanded &&
          _filterQuery == null &&
          !_isSelectionMode &&
          (selectedVault == null ||
              currentFolder == null ||
              currentFolder == selectedVault.body.rootGroup),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        if (_isSelectionMode) {
          _exitSelectionMode();
          return;
        }
        if (_isSearchExpanded || _filterQuery != null) {
          _cancelFilter();
          _filterFocusNode.unfocus();
          return;
        }
        if (selectedVault != null &&
            currentFolder != null &&
            currentFolder != selectedVault.body.rootGroup) {
          _isNavigatingDeeper = false;
          KeyNestVaultScope.instance.setCurrentFolder(
            currentFolder.parent ?? selectedVault.body.rootGroup,
          );
        }
      },
      child: childContent,
    );
  }
}

class SearchAction extends Action<SearchIntent> {
  SearchAction(this.state);

  final _PasswordListContentState state;

  @override
  Object? invoke(SearchIntent intent) {
    _logger.info('We should start search.');
    return null;
  }
}

class PasswordEntryListTileWrapper extends StatelessWidget {
  const PasswordEntryListTileWrapper({
    super.key,
    required this.entry,
    required this.selectedEntry,
    required this.fileColor,
    required String? filterQuery,
    required this.onEntrySelected,
    this.isSelectionMode = false,
    this.isItemSelected = false,
    this.onToggleSelection,
    this.onLongPress,
  }) : _filterQuery = filterQuery;

  final EntryViewModel entry;
  final KdbxEntry? selectedEntry;
  final Color? fileColor;
  final String? _filterQuery;
  final OnEntrySelected onEntrySelected;
  final bool isSelectionMode;
  final bool isItemSelected;
  final VoidCallback? onToggleSelection;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final commonFields = Provider.of<CommonFields>(context);
    final theme = Theme.of(context);
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: loc.swipeCopyPassword): () =>
            _copyPassword(
              context,
              commonFields,
              loc,
              analyticsAction: 'semantic',
            ),
        CustomSemanticsAction(label: loc.swipeCopyUsername): () =>
            _copyUsername(
              context,
              commonFields,
              loc,
              analyticsAction: 'semantic',
            ),
      },
      child: Dismissible(
        key: ValueKey(entry.entry.uuid),
        direction: isSelectionMode
            ? DismissDirection.none
            : DismissDirection.horizontal,
        resizeDuration: null,
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
              Text(loc.swipeCopyPassword),
            ],
          ),
        ),
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          color: theme.brightness == Brightness.light
              ? Colors.limeAccent
              : Colors.brown,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.account_circle),
              const SizedBox(height: 4),
              Text(loc.swipeCopyUsername),
            ],
          ),
        ),
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.endToStart) {
            await _copyUsername(context, commonFields, loc);
          } else {
            await _copyPassword(context, commonFields, loc);
          }
          return false;
        },
        child: KeyNestCard(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          padding: EdgeInsets.zero,
          child: Container(
            decoration: isItemSelected
                ? BoxDecoration(
                    color:
                        (theme.brightness == Brightness.dark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary)
                            .withValues(
                              alpha: theme.brightness == Brightness.dark
                                  ? 0.16
                                  : 0.08,
                            ),
                    borderRadius: BorderRadius.circular(
                      KeyNestShapes.radiusCard,
                    ),
                    border: Border.all(
                      color: theme.brightness == Brightness.dark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      width: 1.5,
                    ),
                  )
                : (selectedEntry == entry.entry
                      ? BoxDecoration(
                          color: KeyNestPlatform.isDesktopOrWeb
                              ? const Color(0xFF0A85EA)
                              : (theme.listTileTheme.selectedTileColor ??
                                  (theme.brightness == Brightness.dark
                                      ? KeyNestPalette.surfaceContainerDark
                                      : KeyNestPalette.primaryContainerLight)),
                          borderRadius: BorderRadius.circular(
                            KeyNestPlatform.isDesktopOrWeb ? 10 : KeyNestShapes.radiusCard,
                          ),
                          border: KeyNestPlatform.isDesktopOrWeb
                              ? null
                              : Border.all(
                                  color: theme.brightness == Brightness.dark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary,
                                  width: 1.5,
                                ),
                        )
                      : null),
            child: PasswordEntryTile(
              vm: entry,
              isSelected: entry.entry == selectedEntry || isItemSelected,
              filterQuery: _filterQuery,
              isSelectionMode: isSelectionMode,
              isItemSelected: isItemSelected,
              onTap: isSelectionMode
                  ? onToggleSelection
                  : () {
                      onEntrySelected(
                        entry.entry,
                        EntrySelectionType.activeOpen,
                      );
                    },
              onLongPress: onLongPress,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copyUsername(
    BuildContext context,
    CommonFields commonFields,
    AppLocalizations loc, {
    @NonNls String analyticsAction = 'swipe',
  }) async {
    final analytics = context.read<Analytics>();
    final stringValue = entry.entry.getString(commonFields.userName.key);
    if (stringValue == null || stringValue.isNullOrEmpty()) {
      context.showSnackBar(loc.copyUsernameNotExists);
      return;
    }
    await SecurityService.copyNonSensitive(
      context,
      stringValue.getText() ?? CharConstants.empty,
      label: commonFields.userName.displayName,
    );
    analytics.events.trackCopyUsername(action: analyticsAction);
  }

  Future<void> _copyPassword(
    BuildContext context,
    CommonFields commonFields,
    AppLocalizations loc, {
    @NonNls String analyticsAction = 'swipe',
  }) async {
    final stringValue = entry.entry.getString(commonFields.password.key);
    if (stringValue == null || stringValue.isNullOrEmpty()) {
      context.showSnackBar(loc.copyPasswordNotExists);
      return;
    }
    await SecurityService.copySensitive(
      context,
      stringValue.getText() ?? CharConstants.empty,
      label: commonFields.password.displayName,
    );
    context.read<Analytics>().events.trackCopyPassword(action: analyticsAction);
  }
}

class NoPasswordsEmptyView extends StatelessWidget {
  const NoPasswordsEmptyView({
    super.key,
    this.onPrimaryButtonPressed,
    this.listPrefix,
  });

  final List<Widget>? listPrefix;
  final VoidCallback? onPrimaryButtonPressed;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        ...?listPrefix,
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Align(
              alignment: const Alignment(0, -0.7),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    '🤗️', // NON-NLS
                    style: TextStyle(fontSize: 64),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    loc.emptyPasswordVaultPlaceholder,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    onPressed: onPrimaryButtonPressed,
                    child: Text(loc.emptyPasswordVaultButtonLabel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class UnsupportedWrite extends StatelessWidget {
  const UnsupportedWrite({super.key, required this.source});

  final FileSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Card(
        color: theme.colorScheme.error.withValues(alpha: 0.2),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: <Widget>[
              Icon(Icons.warning, color: theme.colorScheme.error),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: [
                    Text(loc.changesWithoutSaving(source.displayName)),
                    const SizedBox(height: 4),
                    Text(source.displayPath, style: theme.textTheme.bodySmall),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () {
                            final bloc = Provider.of<KdbxBloc>(
                              context,
                              listen: false,
                            );
                            bloc.saveLocally(source);
                          },
                          child: Text(loc.changesSaveLocally),
                        ),
                      ],
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
}

class PasswordEntryTile extends StatelessWidget {
  const PasswordEntryTile({
    super.key,
    required this.vm,
    required this.isSelected,
    required this.filterQuery,
    this.isSelectionMode = false,
    this.isItemSelected = false,
    this.onTap,
    this.onLongPress,
  });

  final EntryViewModel vm;
  final bool isSelected;
  final String? filterQuery;
  final bool isSelectionMode;
  final bool isItemSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  Widget _defaultIcon(Color? fgColor, ThemeData theme, double size) =>
      EntryIcon.defaultIcon(vm, fgColor, theme, size);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkTheme = theme.brightness == Brightness.dark;
    final fgColor = isSelected
        ? (isDarkTheme ? theme.primaryColorLight : theme.primaryColorDark)
        : (isDarkTheme ? KeyNestPalette.primaryDark : KeyNestPalette.lightIcon);
    final iconTheme = IconTheme.of(context);
    final size = iconTheme.size! * 1.5;
    final loc = AppLocalizations.of(context);

    final icon = EntryIcon(
      vm: vm,
      size: size,
      fallback: (context) => _defaultIcon(fgColor, theme, size),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (isSelectionMode)
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 22,
                height: 22,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isItemSelected
                      ? (isDarkTheme
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary)
                      : Colors.transparent,
                  border: Border.all(
                    color: isItemSelected
                        ? (isDarkTheme
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary)
                        : (isDarkTheme ? Colors.white38 : Colors.black38),
                    width: 2,
                  ),
                ),
                child: isItemSelected
                    ? Icon(
                        Icons.check_rounded,
                        size: 15,
                        color: isDarkTheme
                            ? const Color(0xFF00315D)
                            : Colors.white,
                      )
                    : null,
              ),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: (KeyNestPlatform.isDesktopOrWeb && isSelected)
                    ? Colors.white
                    : (isDarkTheme
                        ? const Color(0xFF434657)
                        : KeyNestPalette.primaryContainerLight),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: icon,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Builder(
                builder: (context) {
                  final rawLabel = vm.label?.nullIfBlank();
                  final itemType = KeyNestItemTypeHelper.getItemType(vm.entry);
                  final recordType = KeyNestItemTypeHelper.getRecordType(
                    vm.entry,
                  );
                  final category = KeyNestItemTypeHelper.getCategory(vm.entry);

                  String displayTitle;
                  String? subtitleText;

                  if (itemType == KeyNestItemType.record ||
                      (recordType != null && recordType.isNotEmpty)) {
                    final typeName = recordType ?? 'Record';
                    final primaryFieldVal =
                        RecordTypeHelper.findPrimaryFieldValue(
                          vm.entry,
                          typeName,
                        );
                    if (rawLabel == null ||
                        rawLabel.isEmpty ||
                        rawLabel == 'Record' ||
                        rawLabel == typeName) {
                      displayTitle =
                          (primaryFieldVal != null &&
                              primaryFieldVal.isNotEmpty)
                          ? primaryFieldVal
                          : (rawLabel ?? typeName);
                      subtitleText = typeName;
                    } else {
                      displayTitle = rawLabel;
                      subtitleText =
                          (primaryFieldVal != null &&
                              primaryFieldVal.isNotEmpty)
                          ? '$typeName • $primaryFieldVal'
                          : typeName;
                    }
                  } else if (itemType == KeyNestItemType.card) {
                    final network =
                        vm.entry.getString(KdbxKey('CardNetwork'))?.getText() ??
                        vm.entry.getString(KdbxKey('Network'))?.getText() ??
                        'Payment Card';
                    final last4 = vm.entry
                        .getString(KdbxKey('CardNumber'))
                        ?.getText();
                    displayTitle =
                        rawLabel ??
                        ((last4 != null && last4.length >= 4)
                            ? '$network •••• ${last4.substring(last4.length - 4)}'
                            : network);
                    final holder = vm.entry
                        .getString(KdbxKey('Cardholder'))
                        ?.getText();
                    subtitleText = (last4 != null && last4.isNotEmpty)
                        ? '•••• ${last4.length >= 4 ? last4.substring(last4.length - 4) : last4}'
                        : (holder?.isNotEmpty == true
                              ? holder
                              : 'Payment Card');
                  } else if (itemType == KeyNestItemType.note) {
                    displayTitle = rawLabel ?? 'Secure Note';
                    final noteBody = vm.entry
                        .getString(KdbxKey('Notes'))
                        ?.getText()
                        ?.trim();
                    subtitleText = (noteBody != null && noteBody.isNotEmpty)
                        ? (noteBody.length > 30
                              ? '${noteBody.substring(0, 30)}...'
                              : noteBody)
                        : 'Secure Note';
                  } else if (itemType == KeyNestItemType.twoFactor) {
                    displayTitle = rawLabel ?? '2FA Authenticator';
                    subtitleText =
                        vm.displayAccountIdentifier ?? 'Authenticator Code';
                  } else {
                    displayTitle = rawLabel ?? loc.noTitle;
                    final accountIdentifier = vm.displayAccountIdentifier;
                    if (category != 'General' && category.isNotEmpty) {
                      subtitleText =
                          (accountIdentifier != null &&
                              accountIdentifier.isNotEmpty)
                          ? '$category • $accountIdentifier'
                          : category;
                    } else {
                      subtitleText = accountIdentifier ?? loc.noUsername;
                    }
                  }

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      DefaultTextStyle(
                        style: theme.textTheme.titleMedium!.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: (KeyNestPlatform.isDesktopOrWeb && isSelected)
                              ? Colors.white
                              : (isSelected
                                  ? fgColor
                                  : (isDarkTheme
                                      ? KeyNestPalette.textPrimaryDark
                                      : KeyNestPalette.textPrimaryLight)),
                        ),
                        child: Text.rich(
                          _highlightFilterQuery(
                                displayTitle,
                                isDark: isDarkTheme,
                              ) ??
                              TextSpan(text: displayTitle),
                        ),
                      ),
                      const SizedBox(height: 2),
                      DefaultTextStyle(
                        style: theme.textTheme.bodyMedium!.copyWith(
                          fontSize: 13,
                          color: (KeyNestPlatform.isDesktopOrWeb && isSelected)
                              ? Colors.white.withValues(alpha: 0.85)
                              : (isSelected
                                  ? fgColor
                                  : (isDarkTheme
                                      ? KeyNestPalette.textSecondaryDark
                                      : KeyNestPalette.textSecondaryLight)),
                        ),
                        child: Text.rich(
                          _highlightFilterQuery(
                                subtitleText,
                                isDark: isDarkTheme,
                              ) ??
                              TextSpan(text: subtitleText),
                        ),
                      ),
                      Builder(
                        builder: (context) {
                          final kdbxBloc = vm.kdbxBloc;
                          final isAllVaults =
                              KeyNestVaultScope.instance.getSelectedVault(
                                kdbxBloc,
                              ) ==
                              null;
                          final hasSubfolder = vm.groupNames.length >= 2;
                          final subfolderName = hasSubfolder
                              ? vm.groupNames.sublist(1).join(' / ')
                              : null;

                          String? locationBadge;
                          if (isAllVaults) {
                            final vaultName = KeyNestVaultScope.cleanVaultName(
                              kdbxBloc,
                              vm.entry.file,
                            );
                            if (subfolderName != null) {
                              locationBadge = '$vaultName • $subfolderName';
                            } else if (category != 'General' &&
                                category.isNotEmpty &&
                                category != 'Login') {
                              locationBadge = '$vaultName • $category';
                            } else {
                              locationBadge = vaultName;
                            }
                          } else if (hasSubfolder) {
                            locationBadge = subfolderName;
                          }

                          if (locationBadge == null) {
                            return const SizedBox.shrink();
                          }

                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: ShapeDecoration(
                                color: isDarkTheme
                                    ? KeyNestTokens.darkSurfaceVariant
                                          .withValues(alpha: 0.4)
                                    : KeyNestTokens.lightSurfaceVariant
                                          .withValues(alpha: 0.6),
                                shape: const StadiumBorder(),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.folder_outlined,
                                    size: 11,
                                    color: isDarkTheme
                                        ? KeyNestPalette.textTertiaryDark
                                        : KeyNestPalette.textTertiaryLight,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      locationBadge,
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w500,
                                        color: isDarkTheme
                                            ? KeyNestPalette.textTertiaryDark
                                            : KeyNestPalette.textTertiaryLight,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
            if (!isSelectionMode)
              StatefulBuilder(
                builder: (context, setFavState) {
                  final isFav =
                      vm.entry.getString(KdbxKey('is_favorite'))?.getText() ==
                      'true';
                  return KeyNestPressScale(
                    onTap: () {
                      setFavState(() {
                        if (isFav) {
                          vm.entry.removeString(KdbxKey('is_favorite'));
                        } else {
                          vm.entry.setString(
                            KdbxKey('is_favorite'),
                            PlainValue('true'),
                          );
                        }
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Icon(
                        isFav ? Icons.star_rounded : Icons.star_border_rounded,
                        color: isFav
                            ? const Color(0xFFFFB800)
                            : (isDarkTheme ? Colors.white38 : Colors.black26),
                        size: 22,
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  InlineSpan? _highlightFilterQuery(String? text, {bool isDark = false}) {
    if (text == null) {
      return null;
    }
    final filterQuery = this.filterQuery;
    if (filterQuery == null || filterQuery.trim().isEmpty) {
      return TextSpan(text: text);
    }
    final lcText = text.toLowerCase();
    final lcFilterTerms = filterQuery
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (lcFilterTerms.isEmpty) {
      return TextSpan(text: text);
    }
    final regexPattern = lcFilterTerms.map((e) => RegExp.escape(e)).join('|');
    if (regexPattern.isEmpty) {
      return TextSpan(text: text);
    }
    final filterRegexp = RegExp(regexPattern);
    var previousMatchEnd = 0;
    final spans = <TextSpan>[];
    final highlightColor = isDark
        ? KeyNestPalette.primaryDark
        : KeyNestPalette.primary;
    for (final match in filterRegexp.allMatches(lcText)) {
      if (match.start > previousMatchEnd) {
        spans.add(
          TextSpan(text: text.substring(previousMatchEnd, match.start)),
        );
      }
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: highlightColor,
          ),
        ),
      );
      previousMatchEnd = match.end;
    }
    if (previousMatchEnd < text.length) {
      spans.add(TextSpan(text: text.substring(previousMatchEnd)));
    }
    return TextSpan(children: spans);
  }
}

class EntryIcon extends StatelessWidget {
  const EntryIcon({
    super.key,
    this.vm,
    this.entry,
    this.websiteUrl,
    required this.fallback,
    required this.size,
  });

  final EntryViewModel? vm;
  final KdbxEntry? entry;
  final String? websiteUrl;
  final double size;
  final Widget Function(BuildContext context) fallback;

  static final newLineRegexp = RegExp(r'[\r\n]');

  @override
  Widget build(BuildContext context) {
    final effectiveEntry = entry ?? vm?.entry;
    if (effectiveEntry?.customIcon != null) {
      return fallback(context);
    }

    final env = context.watch<Env>();
    final appData = context.watch<AppData>();
    final isIconFetchEnabled =
        appData.fetchWebsiteIcons ??
        env.featureFetchWebsiteIconEnabledByDefault;

    var url =
        websiteUrl ??
        vm?.website?.trim() ??
        effectiveEntry?.getString(KdbxKeyCommon.URL)?.getText()?.trim();

    if (url == null || url.isEmpty || url.contains(newLineRegexp)) {
      final title = effectiveEntry
          ?.getString(KdbxKeyCommon.TITLE)
          ?.getText()
          ?.trim();
      final label = effectiveEntry?.label?.trim();
      if (title != null &&
          KeyNestDynamicIconService.extractDomain(title) != null) {
        url = title;
      } else if (label != null &&
          KeyNestDynamicIconService.extractDomain(label) != null) {
        url = label;
      } else {
        return fallback(context);
      }
    }

    // 1. Instant in-memory cache check (available even when offline or disabled)
    final cachedBytes = KeyNestDynamicIconService.instance.getCachedIconSync(
      url,
    );
    if (cachedBytes != null && cachedBytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.memory(
          cachedBytes,
          width: size,
          height: size,
          fit: BoxFit.contain,
          errorBuilder: (ctx, err, stack) => fallback(context),
        ),
      );
    }

    if (!isIconFetchEnabled) {
      // Offline / network fetching disabled: load from local disk cache without making network calls
      return FutureBuilder<Uint8List?>(
        future: KeyNestDynamicIconService.instance.getCachedIcon(url),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData &&
              snapshot.data != null &&
              snapshot.data!.isNotEmpty) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(size * 0.22),
              child: Image.memory(
                snapshot.data!,
                width: size,
                height: size,
                fit: BoxFit.contain,
                errorBuilder: (ctx, err, stack) => fallback(context),
              ),
            );
          }
          return fallback(context);
        },
      );
    }

    // 2. Asynchronous fetch with fallback while loading or on failure
    return FutureBuilder<Uint8List?>(
      future: KeyNestDynamicIconService.instance.getIcon(url),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.hasData &&
            snapshot.data != null &&
            snapshot.data!.isNotEmpty) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(size * 0.22),
            child: Image.memory(
              snapshot.data!,
              width: size,
              height: size,
              fit: BoxFit.contain,
              errorBuilder: (ctx, err, stack) => fallback(context),
            ),
          );
        }
        return fallback(context);
      },
    );
  }

  static Widget defaultIcon(
    EntryViewModel vm,
    Color? fgColor,
    ThemeData theme,
    double size,
  ) => defaultIconForEntry(
    vm.entry,
    fgColor,
    theme,
    size,
    fileColor: vm.fileColor,
  );

  static Widget defaultIconForEntry(
    KdbxEntry entry,
    Color? fgColor,
    ThemeData theme,
    double size, {
    Color? fileColor,
  }) {
    if (entry.customIcon != null) {
      return Image.memory(
        entry.customIcon!.data,
        width: size,
        height: size,
        fit: BoxFit.contain,
      );
    }

    final isDark = theme.brightness == Brightness.dark;
    final defaultPrimary = isDark
        ? KeyNestPalette.primaryDark
        : KeyNestPalette.primary;
    final color = fgColor ?? defaultPrimary;
    final type = KeyNestItemTypeHelper.getItemType(entry);
    if (type == KeyNestItemType.record) {
      final recordType = entry.getString(KdbxKey('RecordType'))?.getText();
      return Icon(
        RecordTypeHelper.iconForType(recordType ?? 'Record'),
        color: color,
        size: size,
      );
    }

    if (type == KeyNestItemType.card) {
      return Icon(
        Icons.credit_card_rounded,
        color: color,
        size: size,
      );
    }

    if (type == KeyNestItemType.note) {
      return Icon(
        Icons.note_alt_rounded,
        color: color,
        size: size,
      );
    }

    if (type == KeyNestItemType.twoFactor) {
      return Icon(
        Icons.security_rounded,
        color: color,
        size: size,
      );
    }

    final predefinedIcon = entry.icon.get() ?? KdbxIcon.Key;
    return FaIcon(
      PredefinedIcons.iconFor(predefinedIcon),
      color: color,
      size: size,
    );
  }
}

extension on AutofillMetadata {
  /// Everything the platform said about who is asking, as match requests.
  ///
  /// A browser reports the page's domain (occasionally more than one, for
  /// framed logins) plus its own package name; a native app reports only its
  /// package. `android` is the framework itself, never a credential.
  Iterable<CredentialRequest> get credentialRequests => [
    ...webDomains
        .where((domain) => domain.domain.isNotEmpty)
        .map((domain) => CredentialRequest.web(domain.domain)),
    ...packageNames
        .where(
          (packageName) => packageName != 'android', // NON-NLS
        )
        .map(CredentialRequest.application),
  ];

  String? get searchTerm =>
      webDomains
          .where((element) => element.domain.isNotEmpty)
          .firstOrNull
          ?.domain ??
      packageNames
          .where(
            (element) => element != 'android', // NON-NLS
          )
          .firstOrNull;
}
