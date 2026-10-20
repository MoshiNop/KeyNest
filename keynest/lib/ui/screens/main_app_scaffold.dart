import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/main.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/card_details.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/screens/keynest_home_shell.dart';
import 'package:keynest/ui/screens/note_details.dart';
import 'package:keynest/ui/screens/password_list.dart';
import 'package:keynest/ui/widgets/keyboard_handler.dart';
import 'package:keynest/ui/widgets/keynest_desktop_detail_pane.dart';
import 'package:keynest/ui/widgets/keynest_desktop_nav_rail.dart';
import 'package:keynest/ui/widgets/utils/back_button_navigator_delegate.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

final _logger = Logger('main_app_scaffold');

class MainAppScaffold extends StatelessWidget {
  static Route<void> route() => PageRouteBuilder<void>(
    settings: const RouteSettings(name: '/main'),
    pageBuilder: (context, animation, secondaryAnimation) => MainAppScaffold(),
    transitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final systemWideShortcuts = context.select<AppData, bool>(
      (appData) => appData.systemWideShortcuts,
    );
    _logger.finer('size.width: ${mediaQuery.size.width}');
    if (KeyNestPlatform.isDesktopOrWeb ||
        mediaQuery.size.width >= Breakpoints.TABLET_WIDTH) {
      return KeyboardHandler(
        systemWideShortcuts: systemWideShortcuts,
        child: MainAppTabletScaffold(),
      );
    }
    return KeyboardHandler(
      systemWideShortcuts: systemWideShortcuts,
      child: BackButtonNavigatorDelegate(
        observers: [
          AnalyticsNavigatorObserver(Provider.of<Analytics>(context)),
        ],
        onGenerateRoute: null,
        onGenerateInitialRoutes: (navigator, initialRoute) => [
          KeyNestHomeShell.route(),
        ],
      ),
    );
  }
}

class MainAppTabletScaffold extends StatefulWidget {
  @override
  _MainAppTabletScaffoldState createState() => _MainAppTabletScaffoldState();
}

/// Workaround for the search text field losing focus when pushing
/// a second route.
/// https://github.com/flutter/flutter/issues/53441
class FocusWorkaroundPageRoute<T> extends MaterialPageRoute<T> {
  FocusWorkaroundPageRoute({
    super.settings,
    required super.builder,
    this.focusNode,
  });

  final FocusNode? focusNode;

  @override
  void install() {
    super.install();
    _logger.fine('focusNode: $focusNode');
    focusNode!.addListener(_changedFocus);
  }

  void _changedFocus() {
    _logger.finest(
      'Changed focus. ${focusNode!.hasFocus} --- isCurrent:$isCurrent',
    );
    if (!focusNode!.hasFocus) {
      focusNode!.requestFocus();
    }
  }

  @override
  TickerFuture didPush() {
    final ret = super.didPush();
    ret.then((value) {
      focusNode!.removeListener(_changedFocus);
    });
    return ret;
  }
}

class _MainAppTabletScaffoldState extends State<MainAppTabletScaffold> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey();
  final TextEditingController _searchController = TextEditingController();
  final List<KdbxEntry> _history = [];
  int _historyIndex = -1;
  KdbxEntry? _selectedEntry;
  bool _isCreatingNew = false;
  double _listPaneWidth = 380.0;
  bool _isDraggingSplitter = false;
  int _activeRailIndex = 0;

  @override
  void initState() {
    super.initState();
    _activeRailIndex = KeyNestVaultScope.instance.activeTabIndex ?? 0;
    _searchController.text = KeyNestVaultScope.instance.searchQuery;
    KeyNestVaultScope.instance.addListener(_onVaultScopeChanged);
  }

  @override
  void dispose() {
    KeyNestVaultScope.instance.removeListener(_onVaultScopeChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onVaultScopeChanged() {
    final idx = KeyNestVaultScope.instance.activeTabIndex;
    if (idx != null && idx != _activeRailIndex && mounted) {
      setState(() {
        _activeRailIndex = idx;
      });
    }
    final q = KeyNestVaultScope.instance.searchQuery;
    if (_searchController.text != q && mounted) {
      _searchController.text = q;
    }
  }

  void _navigateToEntry(KdbxEntry? entry, {bool isNew = false}) {
    if (entry != null &&
        (_historyIndex < 0 ||
            _historyIndex >= _history.length ||
            _history[_historyIndex] != entry)) {
      if (_historyIndex >= 0 && _historyIndex < _history.length - 1) {
        _history.removeRange(_historyIndex + 1, _history.length);
      }
      _history.add(entry);
      _historyIndex = _history.length - 1;
    }
    setState(() {
      _selectedEntry = entry;
      _isCreatingNew = isNew;
    });
  }

  void _navigateBack() {
    if (_historyIndex > 0) {
      setState(() {
        _historyIndex--;
        _selectedEntry = _history[_historyIndex];
        _isCreatingNew = false;
      });
    }
  }

  void _navigateForward() {
    if (_historyIndex < _history.length - 1) {
      setState(() {
        _historyIndex++;
        _selectedEntry = _history[_historyIndex];
        _isCreatingNew = false;
      });
    }
  }

  void _handleAddNewItem() {
    final kdbxBloc = context.read<KdbxBloc>();
    final scope = KeyNestVaultScope.instance;
    final activeVault = scope.getSelectedVault(kdbxBloc) ??
        kdbxBloc.openedFilesKdbx.firstOrNull;
    final activeFolder = (activeVault != null)
        ? (scope.getCurrentFolder(kdbxBloc) ?? activeVault.body.rootGroup)
        : null;
    final newEntry = kdbxBloc.createEntry(
      file: activeVault,
      group: activeFolder,
    );
    _navigateToEntry(newEntry, isNew: true);
  }

  Route<void> _routeForEntry(KdbxEntry entry, bool isNew) {
    final type = KeyNestItemTypeHelper.getItemType(entry);
    switch (type) {
      case KeyNestItemType.card:
        return CardDetailsScreen.route(entry: entry);
      case KeyNestItemType.note:
        return NoteDetailsScreen.route(entry: entry, isEditing: isNew);
      case KeyNestItemType.record:
      case KeyNestItemType.login:
      case KeyNestItemType.twoFactor:
        return EntryDetailsScreen.route(entry: entry, isNew: isNew);
    }
  }

  Widget _buildSplitterHandle(BuildContext context, bool isDark) {
    final normalBorder = isDark
        ? KeyNestPalette.cardBorderDark
        : KeyNestPalette.cardBorderLight;
    final activeBorder = isDark
        ? KeyNestPalette.primaryDark
        : KeyNestPalette.primary;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          setState(() => _isDraggingSplitter = true);
        },
        onHorizontalDragUpdate: (details) {
          setState(() {
            _listPaneWidth = (_listPaneWidth + details.delta.dx).clamp(
              280.0,
              650.0,
            );
          });
        },
        onHorizontalDragEnd: (_) {
          setState(() => _isDraggingSplitter = false);
        },
        onHorizontalDragCancel: () {
          setState(() => _isDraggingSplitter = false);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 8,
          color: _isDraggingSplitter
              ? activeBorder.withValues(alpha: 0.15)
              : Colors.transparent,
          child: Center(
            child: Container(
              width: 1,
              color: _isDraggingSplitter ? activeBorder : normalBorder,
            ),
          ),
        ),
      ),
    );
  }

  void _onEntrySelected(KdbxEntry entry, EntrySelectionType type) {
    if (KeyNestPlatform.isDesktopOrWeb) {
      _navigateToEntry(entry, isNew: type == EntrySelectionType.newEntry);
      return;
    }

    if (_selectedEntry != entry) {
      final push = _navigatorKey.currentState!.pushAndRemoveUntil(
        _routeForEntry(
          entry,
          type == EntrySelectionType.newEntry,
        ),
        (route) => route.isFirst,
      );
      push.then((dynamic value) {
        _logger.finer('entry route was popped.');
        if (entry == _selectedEntry && mounted) {
          setState(() => _selectedEntry = null);
        }
      });
      setState(() {
        _selectedEntry = entry;
      });
    }
  }

  Widget _buildDesktopTopBar(BuildContext context, bool isDark) {
    final kdbxBloc = context.watch<KdbxBloc>();
    final scope = KeyNestVaultScope.instance;
    final selectedVault = scope.getSelectedVault(kdbxBloc);
    final vaultName = selectedVault?.body.meta.databaseName.get() ??
        (selectedVault != null ? 'Active Vault' : 'All Vaults');

    final canGoBack = _historyIndex > 0;
    final canGoForward =
        _historyIndex >= 0 && _historyIndex < _history.length - 1;

    final borderColor = isDark
        ? KeyNestPalette.cardBorderDark
        : KeyNestPalette.cardBorderLight;
    final topBarBg = isDark
        ? KeyNestPalette.surfaceContainerDark
        : KeyNestPalette.surfaceLight;

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: topBarBg,
        border: Border(
          bottom: BorderSide(color: borderColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          // Navigation History
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
            onPressed: canGoBack ? _navigateBack : null,
            tooltip: 'Back',
            splashRadius: 18,
            visualDensity: VisualDensity.compact,
            color: canGoBack
                ? (isDark ? Colors.white : Colors.black87)
                : (isDark ? Colors.white24 : Colors.black26),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward_rounded, size: 20),
            onPressed: canGoForward ? _navigateForward : null,
            tooltip: 'Forward',
            splashRadius: 18,
            visualDensity: VisualDensity.compact,
            color: canGoForward
                ? (isDark ? Colors.white : Colors.black87)
                : (isDark ? Colors.white24 : Colors.black26),
          ),
          const SizedBox(width: 8),
          // Search Pill
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E212B)
                        : const Color(0xFFF1F3F5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF333846)
                          : const Color(0xFFE2E4E8),
                      width: 1,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          onChanged: (val) {
                            KeyNestVaultScope.instance.setSearchQuery(val);
                          },
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 8),
                            border: InputBorder.none,
                            hintText: 'Search in $vaultName',
                            hintStyle: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            KeyNestVaultScope.instance.setSearchQuery('');
                          },
                          child: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Prominent + New Item Button
          FilledButton.icon(
            onPressed: _handleAddNewItem,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text(
              'New Item',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0A85EA),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktopOrWeb = KeyNestPlatform.isDesktopOrWeb;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isDesktopOrWeb) {
      return Scaffold(
        backgroundColor:
            isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
        body: Row(
          children: <Widget>[
            // 1. Desktop & Web Navigation Rail (Leftmost)
            KeyNestDesktopNavRail(
              currentIndex: _activeRailIndex,
              onTap: (index) {
                setState(() {
                  _activeRailIndex = index;
                });
                KeyNestVaultScope.instance.setActiveTab(index);
              },
            ),
            // 2. Right of Rail: Top Bar + List & Detail Panes
            Expanded(
              child: Column(
                children: [
                  _buildDesktopTopBar(context, isDark),
                  Expanded(
                    child: Row(
                      children: [
                        // Middle Pane: List
                        SizedBox(
                          width: _listPaneWidth,
                          child: KeyNestHomeShell(
                            selectedEntry: _selectedEntry,
                            isDesktopMaster: true,
                            onEntrySelected: _onEntrySelected,
                          ),
                        ),
                        // Splitter
                        _buildSplitterHandle(context, isDark),
                        // Right Pane: Detail
                        Expanded(
                          child: KeyNestDesktopDetailPane(
                            key: ValueKey(
                              _selectedEntry?.uuid.toString() ?? 'empty_detail',
                            ),
                            entry: _selectedEntry,
                            initialIsEditing: _isCreatingNew,
                            onEntrySaved: (saved) {
                              setState(() {
                                _selectedEntry = saved;
                                _isCreatingNew = false;
                              });
                            },
                            onEntryDeleted: () {
                              setState(() {
                                _selectedEntry = null;
                                _isCreatingNew = false;
                              });
                            },
                            onAddNewItem: _handleAddNewItem,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Touch Tablet Layout (iPad, Android Tablet)
    return Row(
      children: <Widget>[
        SizedBox(
          width: 384,
          child: Navigator(
            onGenerateRoute: (settings) {
              assert(settings.name == Navigator.defaultRouteName);
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (context) => KeyNestHomeShell(
                  selectedEntry: _selectedEntry,
                  isDesktopMaster: false,
                  onEntrySelected: _onEntrySelected,
                ),
              );
            },
          ),
        ),
        Expanded(
          child: Navigator(
            key: _navigatorKey,
            requestFocus: false,
            onGenerateRoute: (settings) {
              assert(settings.name == Navigator.defaultRouteName);
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (context) => EmptyStateInitialRoute(),
              );
            },
          ),
        ),
      ],
    );
  }
}

class EmptyStateInitialRoute extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary)
                    .withValues(alpha: isDark ? 0.16 : 0.10),
              ),
              padding: const EdgeInsets.all(16),
              child: Image.asset(
                AssetConstants.logoIcon,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              AppConstants.keyNest,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Select an item from the list to view or edit details',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () {
                final kdbxBloc = context.read<KdbxBloc>();
                final scope = KeyNestVaultScope.instance;
                final activeVault = scope.getSelectedVault(kdbxBloc) ??
                    kdbxBloc.openedFilesKdbx.firstOrNull;
                final activeFolder = (activeVault != null)
                    ? (scope.getCurrentFolder(kdbxBloc) ??
                        activeVault.body.rootGroup)
                    : null;
                final newEntry = kdbxBloc.createEntry(
                  file: activeVault,
                  group: activeFolder,
                );
                Navigator.of(context).push(
                  EntryDetailsScreen.route(entry: newEntry, isNew: true),
                );
              },
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(loc.addNewPasswordButtonLabel),
              style: FilledButton.styleFrom(
                backgroundColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                foregroundColor: isDark
                    ? const Color(0xFF00315D)
                    : Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
