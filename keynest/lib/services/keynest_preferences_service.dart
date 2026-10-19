import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/ui/screens/password_list.dart' show VaultSortMode;
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('KeyNestVaultScope');

class KeyNestPreferencesService {
  static const String _fileName = 'keynest_ui_preferences.json';
  static const String _onboardingCompletedKey = 'hasCompletedOnboarding';

  static Future<bool> hasCompletedOnboarding() async {
    final prefs = await loadRawPreferences();
    return prefs[_onboardingCompletedKey] == true;
  }

  static Future<void> setCompletedOnboarding(bool completed) async {
    final prefs = await loadRawPreferences();
    prefs[_onboardingCompletedKey] = completed;
    await saveRawPreferences(prefs);
  }

  static Future<io.File> _getPrefsFile() async {
    final appDataDir = await PathUtils().getAppDataDirectory();
    return io.File(p.join(appDataDir.path, _fileName));
  }

  static Future<Map<String, dynamic>> loadRawPreferences() async {
    try {
      final file = await _getPrefsFile();
      if (file.existsSync()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
        }
      }
    } catch (e, stack) {
      _logger.warning(
        'Failed to load UI preferences, returning defaults',
        e,
        stack,
      );
    }
    return {};
  }

  static Future<void> saveRawPreferences(Map<String, dynamic> data) async {
    try {
      final file = await _getPrefsFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (e, stack) {
      _logger.severe('Failed to save UI preferences', e, stack);
    }
  }
}

enum KeyNestTab {
  secrets,
  records,
  cards,
  notes,
  twoFactor,
}

class KeyNestTabScopeData {
  KeyNestTabScopeData({
    this.selectedVaultSourcePath,
    this.selectedFolderUuid,
    this.sortMode = VaultSortMode.alphabeticalAsc,
  });

  String? selectedVaultSourcePath;
  String? selectedFolderUuid;
  VaultSortMode sortMode;
}

class KeyNestVaultScope with ChangeNotifier {
  KeyNestVaultScope._();

  static final KeyNestVaultScope instance = KeyNestVaultScope._();

  bool _initialized = false;
  String? _selectedCategory;
  bool _favoritesOnly = false;
  int? _activeTabIndex;

  final Map<KeyNestTab, KeyNestTabScopeData> _tabStates = {
    for (final tab in KeyNestTab.values) tab: KeyNestTabScopeData(),
  };

  KeyNestTab get currentActiveTab {
    switch (_activeTabIndex) {
      case 1:
        return KeyNestTab.records;
      case 2:
        return KeyNestTab.cards;
      case 3:
        return KeyNestTab.notes;
      case 4:
        return KeyNestTab.twoFactor;
      case 0:
      default:
        return KeyNestTab.secrets;
    }
  }

  bool get isInitialized => _initialized;
  String? get selectedVaultSourcePath => getSelectedVaultSourcePath();
  String? get selectedFolderUuid => getSelectedFolderUuid();
  VaultSortMode get sortMode => getSortMode();
  String? get selectedCategory => _selectedCategory;
  bool get favoritesOnly => _favoritesOnly;
  int? get activeTabIndex => _activeTabIndex;

  void notifyScopeChanged() {
    notifyListeners();
  }

  void setActiveTab(int index) {
    if (_activeTabIndex == index) {
      return;
    }
    _activeTabIndex = index;
    notifyListeners();
  }

  VaultSortMode getSortMode([KeyNestTab? tab]) {
    final t = tab ?? currentActiveTab;
    return _tabStates[t]?.sortMode ?? VaultSortMode.alphabeticalAsc;
  }

  void setSortMode(VaultSortMode mode, [KeyNestTab? tab]) {
    final t = tab ?? currentActiveTab;
    _tabStates[t]?.sortMode = mode;
    _persist();
    notifyListeners();
  }

  String? getSelectedVaultSourcePath([KeyNestTab? tab]) {
    final t = tab ?? currentActiveTab;
    return _tabStates[t]?.selectedVaultSourcePath;
  }

  String? getSelectedFolderUuid([KeyNestTab? tab]) {
    final t = tab ?? currentActiveTab;
    return _tabStates[t]?.selectedFolderUuid;
  }

  /// Loads persisted preferences from local disk.
  Future<void> init() async {
    if (_initialized) {
      return;
    }
    try {
      final data = await KeyNestPreferencesService.loadRawPreferences();
      final tabMap = data['tabStates'] as Map<String, dynamic>?;
      if (tabMap != null) {
        for (final tab in KeyNestTab.values) {
          final tData = tabMap[tab.name] as Map<String, dynamic>?;
          if (tData != null) {
            final sortIdx = tData['sortModeIndex'] as int?;
            final sortMode =
                (sortIdx != null &&
                    sortIdx >= 0 &&
                    sortIdx < VaultSortMode.values.length)
                ? VaultSortMode.values[sortIdx]
                : VaultSortMode.alphabeticalAsc;
            _tabStates[tab] = KeyNestTabScopeData(
              selectedVaultSourcePath:
                  tData['selectedVaultSourcePath'] as String?,
              selectedFolderUuid: tData['selectedFolderUuid'] as String?,
              sortMode: sortMode,
            );
          }
        }
      } else {
        // Fallback for legacy preferences
        final legacyVault = data['selectedVaultSourcePath'] as String?;
        final legacyFolder = data['selectedFolderUuid'] as String?;
        final legacySortIdx = data['sortModeIndex'] as int?;
        final legacySort =
            (legacySortIdx != null &&
                legacySortIdx >= 0 &&
                legacySortIdx < VaultSortMode.values.length)
            ? VaultSortMode.values[legacySortIdx]
            : VaultSortMode.alphabeticalAsc;
        _tabStates[KeyNestTab.secrets] = KeyNestTabScopeData(
          selectedVaultSourcePath: legacyVault,
          selectedFolderUuid: legacyFolder,
          sortMode: legacySort,
        );
      }

      _selectedCategory = data['selectedCategory'] as String?;
      _favoritesOnly = (data['favoritesOnly'] as bool?) ?? false;
      _initialized = true;
      notifyListeners();
    } catch (e) {
      _initialized = true;
    }
  }

  Future<void> _persist() async {
    final tabMap = <String, dynamic>{
      for (final entry in _tabStates.entries)
        entry.key.name: {
          'selectedVaultSourcePath': entry.value.selectedVaultSourcePath,
          'selectedFolderUuid': entry.value.selectedFolderUuid,
          'sortModeIndex': entry.value.sortMode.index,
        },
    };

    await KeyNestPreferencesService.saveRawPreferences({
      'tabStates': tabMap,
      'selectedVaultSourcePath': getSelectedVaultSourcePath(KeyNestTab.secrets),
      'selectedFolderUuid': getSelectedFolderUuid(KeyNestTab.secrets),
      'sortModeIndex': getSortMode(KeyNestTab.secrets).index,
      'selectedCategory': _selectedCategory,
      'favoritesOnly': _favoritesOnly,
    });
  }

  /// Extracts the authentic vault file or database name, stripping the `.kdbx` extension.
  /// Uses the KDBX filename as the single source of truth across the app.
  static String cleanVaultName(KdbxBloc kdbxBloc, KdbxFile file) {
    KdbxOpenedFile? opened;
    try {
      opened = kdbxBloc.fileForKdbxFile(file);
    } catch (_) {
      for (final of in kdbxBloc.openedFiles.values) {
        if (identical(of.kdbxFile, file) || of.kdbxFile == file) {
          opened = of;
          break;
        }
      }
    }

    if (opened != null) {
      final fs = opened.fileSource;
      if (fs is FileSourceLocal) {
        final pickerName = fs.filePickerInfo?.fileName;
        if (pickerName != null && pickerName.trim().isNotEmpty) {
          final cleanPicker = FileSource.cleanDisplayName(pickerName);
          if (cleanPicker.isNotEmpty &&
              cleanPicker != 'Vault' &&
              cleanPicker.toLowerCase() != 'vault') {
            return _disambiguateIfDuplicate(kdbxBloc, opened, cleanPicker);
          }
        }
      }

      final rawName = fs.displayName;
      final clean = FileSource.cleanDisplayName(rawName);
      if (clean.isNotEmpty &&
          clean != 'Vault' &&
          clean.toLowerCase() != 'vault') {
        return _disambiguateIfDuplicate(kdbxBloc, opened, clean);
      }
      final openedName = FileSource.cleanDisplayName(opened.openedFile.name);
      if (openedName.isNotEmpty &&
          openedName != 'Vault' &&
          openedName.toLowerCase() != 'vault') {
        return _disambiguateIfDuplicate(kdbxBloc, opened, openedName);
      }
      if (clean.isNotEmpty) {
        return _disambiguateIfDuplicate(kdbxBloc, opened, clean);
      }
    }

    final rootName = file.body.rootGroup.name.get()?.trim();
    if (rootName != null && rootName.isNotEmpty) {
      final clean = FileSource.cleanDisplayName(rootName);
      if (clean.isNotEmpty &&
          clean != 'Vault' &&
          clean.toLowerCase() != 'vault') {
        return clean;
      }
    }

    final metaName = file.body.meta.databaseName.get()?.trim();
    if (metaName != null && metaName.isNotEmpty) {
      final clean = FileSource.cleanDisplayName(metaName);
      if (clean.isNotEmpty &&
          clean != 'Vault' &&
          clean.toLowerCase() != 'vault') {
        return clean;
      }
    }

    if (rootName != null && rootName.isNotEmpty) {
      return FileSource.cleanDisplayName(rootName);
    }
    return 'Vault';
  }

  /// Disambiguates duplicate vault filenames safely without altering underlying vault identifiers or paths.
  static String _disambiguateIfDuplicate(
    KdbxBloc kdbxBloc,
    KdbxOpenedFile current,
    String baseName,
  ) {
    try {
      final allOpened = kdbxBloc.openedFiles.values.toList();
      final matching = allOpened.where((of) {
        final name = of.fileSource.displayName;
        return FileSource.cleanDisplayName(name).toLowerCase() ==
            baseName.toLowerCase();
      }).toList();

      if (matching.length <= 1) {
        return baseName;
      }

      // Disambiguate multiple vaults having the same filename by parent folder or index.
      final pathStr = current.fileSource.displayPath;
      if (pathStr.isNotEmpty) {
        final parentDir = p.basename(p.dirname(pathStr));
        if (parentDir.isNotEmpty &&
            parentDir != '.' &&
            parentDir != '/' &&
            parentDir != '\\') {
          return '$baseName ($parentDir)';
        }
      }

      final index = matching.indexWhere(
        (of) => of.fileSource.uuid == current.fileSource.uuid,
      );
      if (index > 0) {
        return '$baseName (${index + 1})';
      }
    } catch (_) {}
    return baseName;
  }

  /// Resolves the currently selected [KdbxFile], or `null` if "All Vault Items" is active.
  KdbxFile? getSelectedVault(KdbxBloc bloc, [KeyNestTab? tab]) {
    final t = tab ?? currentActiveTab;
    final path = _tabStates[t]?.selectedVaultSourcePath;
    if (path == null) {
      return null;
    }
    for (final entry in bloc.openedFilesWithSources) {
      if (entry.key.displayPath == path || entry.key.uuid == path) {
        return entry.value;
      }
    }
    // If not found in current opened files, fall back to null ("All Vault Items")
    return null;
  }

  /// Resolves the current folder [KdbxGroup] within the selected vault.
  KdbxGroup? getCurrentFolder(KdbxBloc bloc, [KeyNestTab? tab]) {
    final t = tab ?? currentActiveTab;
    final vault = getSelectedVault(bloc, t);
    if (vault == null) {
      return null;
    }
    final rootGroup = vault.body.rootGroup;
    final folderUuid = _tabStates[t]?.selectedFolderUuid;
    if (folderUuid == null) {
      return rootGroup;
    }
    try {
      final targetUuid = KdbxUuid(folderUuid);
      return vault.findGroupByUuid(targetUuid);
    } catch (_) {
      return rootGroup;
    }
  }

  /// Returns the entries scoped to the currently selected vault and/or folder.
  Iterable<KdbxEntry> getScopedEntries(
    KdbxBloc bloc, {
    KeyNestTab? tab,
    bool directOnlyForFolder = false,
  }) {
    final t = tab ?? currentActiveTab;
    final selectedVault = getSelectedVault(bloc, t);
    if (selectedVault == null) {
      return bloc.openedFilesKdbx
          .expand((f) => f.body.rootGroup.getAllEntries())
          .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e));
    }
    final currentFolder = getCurrentFolder(bloc, t);
    if (currentFolder != null &&
        currentFolder != selectedVault.body.rootGroup) {
      final isTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(currentFolder);
      if (isTrash) {
        return directOnlyForFolder
            ? currentFolder.entries
            : currentFolder.getAllEntries();
      }
      return directOnlyForFolder
          ? currentFolder.entries.where(
              (e) => !KeyNestItemTypeHelper.isEntryInTrash(e),
            )
          : currentFolder.getAllEntries().where(
              (e) => !KeyNestItemTypeHelper.isEntryInTrash(e),
            );
    }
    return directOnlyForFolder
        ? selectedVault.body.rootGroup.entries.where(
            (e) => !KeyNestItemTypeHelper.isEntryInTrash(e),
          )
        : selectedVault.body.rootGroup.getAllEntries().where(
            (e) => !KeyNestItemTypeHelper.isEntryInTrash(e),
          );
  }

  /// Sets the selected vault. `null` represents "All Vault Items".
  void setSelectedVault(KdbxBloc bloc, KdbxFile? file, [KeyNestTab? tab]) {
    final t = tab ?? currentActiveTab;
    final tabData = _tabStates[t]!;
    if (file == null) {
      tabData.selectedVaultSourcePath = null;
      tabData.selectedFolderUuid = null;
    } else {
      try {
        final opened = bloc.fileForKdbxFile(file);
        tabData.selectedVaultSourcePath = opened.fileSource.displayPath;
      } catch (_) {
        tabData.selectedVaultSourcePath = file.body.rootGroup.uuid.uuid;
      }
      tabData.selectedFolderUuid = file.body.rootGroup.uuid.uuid;
    }
    _persist();
    notifyListeners();
  }

  /// Sets both the selected vault and folder, switching to the designated tab (defaulting to Secrets tab 0).
  void setSelectedVaultAndFolder(
    KdbxBloc bloc,
    KdbxFile file,
    KdbxGroup folder, {
    int targetTab = 0,
    KeyNestTab? tab,
  }) {
    final t = tab ?? (targetTab == 0 ? KeyNestTab.secrets : currentActiveTab);
    final tabData = _tabStates[t]!;
    try {
      final opened = bloc.fileForKdbxFile(file);
      tabData.selectedVaultSourcePath = opened.fileSource.displayPath;
    } catch (_) {
      tabData.selectedVaultSourcePath = file.body.rootGroup.uuid.uuid;
    }
    tabData.selectedFolderUuid = folder.uuid.uuid;
    _activeTabIndex = targetTab;
    _persist();
    notifyListeners();
  }

  /// Sets the current folder being navigated within the selected vault.
  void setCurrentFolder(KdbxGroup? folder, [KeyNestTab? tab]) {
    final t = tab ?? currentActiveTab;
    _tabStates[t]?.selectedFolderUuid = folder?.uuid.uuid;
    _persist();
    notifyListeners();
  }

  /// Sets category filter.
  void setSelectedCategory(String? category) {
    _selectedCategory = category;
    _persist();
    notifyListeners();
  }

  /// Sets favorites only filter.
  void setFavoritesOnly(bool favs) {
    _favoritesOnly = favs;
    _persist();
    notifyListeners();
  }

  /// Clears any selected scope pointing to [vaultIdentifier] (path or uuid) across ALL tabs.
  void clearVaultFromAllTabs(String vaultIdentifier) {
    bool changed = false;
    for (final tab in KeyNestTab.values) {
      final tabData = _tabStates[tab];
      if (tabData != null) {
        final path = tabData.selectedVaultSourcePath;
        if (path != null) {
          final isMatch =
              path == vaultIdentifier ||
              p.basename(path) == p.basename(vaultIdentifier) ||
              path.contains(vaultIdentifier) ||
              vaultIdentifier.contains(path);
          if (isMatch) {
            tabData.selectedVaultSourcePath = null;
            tabData.selectedFolderUuid = null;
            changed = true;
          }
        }
      }
    }
    if (changed) {
      _persist();
      notifyListeners();
    }
  }

  /// Clears all tabs and selection state completely.
  void clearAllTabs() {
    for (final tab in KeyNestTab.values) {
      _tabStates[tab]?.selectedVaultSourcePath = null;
      _tabStates[tab]?.selectedFolderUuid = null;
    }
    _selectedCategory = null;
    _favoritesOnly = false;
    _persist();
    notifyListeners();
  }

  @visibleForTesting
  void setSelectedVaultPathForTesting(KeyNestTab tab, String? path) {
    _tabStates[tab]?.selectedVaultSourcePath = path;
  }
}
