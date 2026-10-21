import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/main.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/add_payment_card.dart';
import 'package:keynest/ui/screens/add_record_catalog.dart';
import 'package:keynest/ui/screens/card_details.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/screens/keynest_home_shell.dart';
import 'package:keynest/ui/screens/note_details.dart';
import 'package:keynest/ui/screens/password_list.dart';
import 'package:keynest/ui/widgets/keyboard_handler.dart';
import 'package:keynest/ui/widgets/keynest_category_picker.dart';
import 'package:keynest/ui/widgets/keynest_chips.dart';
import 'package:keynest/ui/widgets/keynest_desktop_nav_rail.dart';
import 'package:keynest/ui/widgets/keynest_top_chips_bar.dart';
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
  final FocusNode _searchFocusNode = FocusNode();
  final List<KdbxEntry> _history = [];
  int _historyIndex = -1;
  KdbxEntry? _selectedEntry;
  double _listPaneWidth = 380.0;
  bool _isDraggingSplitter = false;
  int _activeRailIndex = 0;
  bool _isNarrowLayout = false;

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
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onVaultScopeChanged() {
    final idx = KeyNestVaultScope.instance.activeTabIndex;
    if (idx != null && idx != _activeRailIndex) {
      _activeRailIndex = idx;
    }
    final q = KeyNestVaultScope.instance.searchQuery;
    if (_searchController.text != q) {
      _searchController.text = q;
    }

    if (_selectedEntry != null &&
        (KeyNestItemTypeHelper.isEntryInTrash(_selectedEntry!) ||
            _selectedEntry!.parent == null)) {
      _selectedEntry = null;
      _history.removeWhere((e) =>
          KeyNestItemTypeHelper.isEntryInTrash(e) || e.parent == null);
      if (_historyIndex >= _history.length) {
        _historyIndex = _history.length - 1;
      }
      _navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (context) => EmptyStateInitialRoute(
            onAddNewItem: _handleAddNewItem,
          ),
        ),
        (route) => route.isFirst,
      );
    }

    if (mounted) {
      setState(() {});
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
    });

    if (entry != null) {
      _navigatorKey.currentState?.pushAndRemoveUntil(
        _routeForEntry(entry, isNew),
        (route) => route.isFirst,
      );
    } else {
      _navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (context) => EmptyStateInitialRoute(
            onAddNewItem: _handleAddNewItem,
          ),
        ),
        (route) => route.isFirst,
      );
    }
  }

  bool get _canGoBack {
    if (_isNarrowLayout) {
      return Navigator.of(context).canPop() || _historyIndex > 0;
    }
    return (_navigatorKey.currentState?.canPop() ?? false) ||
        _historyIndex > 0 ||
        (_historyIndex == 0 && _selectedEntry != null);
  }

  bool get _canGoForward {
    return _historyIndex >= 0 && _historyIndex < _history.length - 1;
  }

  void _navigateBack() {
    if (_isNarrowLayout) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
        return;
      }
    } else {
      if (_navigatorKey.currentState?.canPop() ?? false) {
        _navigatorKey.currentState!.pop();
        return;
      }
    }
    if (_historyIndex > 0) {
      setState(() {
        _historyIndex--;
        _selectedEntry = _history[_historyIndex];
      });
      _navigatorKey.currentState?.pushAndRemoveUntil(
        _routeForEntry(_selectedEntry!, false),
        (route) => route.isFirst,
      );
    } else if (_historyIndex == 0 && _selectedEntry != null) {
      setState(() {
        _historyIndex = -1;
        _selectedEntry = null;
      });
      _navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (context) => EmptyStateInitialRoute(
            onAddNewItem: _handleAddNewItem,
          ),
        ),
        (route) => route.isFirst,
      );
    }
  }

  void _navigateForward() {
    if (_historyIndex < _history.length - 1) {
      setState(() {
        _historyIndex++;
        _selectedEntry = _history[_historyIndex];
      });
      _navigatorKey.currentState?.pushAndRemoveUntil(
        _routeForEntry(_selectedEntry!, false),
        (route) => route.isFirst,
      );
    }
  }

  Future<void> _handleAddNewItem() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final scope = KeyNestVaultScope.instance;
    final activeVault = scope.getSelectedVault(kdbxBloc) ??
        kdbxBloc.openedFilesKdbx.firstOrNull;
    final activeFolder = (activeVault != null)
        ? (scope.getCurrentFolder(kdbxBloc) ?? activeVault.body.rootGroup)
        : null;

    final currentTab = scope.activeTabIndex ?? _activeRailIndex;

    if (_isNarrowLayout) {
      switch (currentTab) {
        case 2: // Cards tab
          Navigator.of(context).push(
            AddPaymentCardScreen.route(
              initialFile: activeVault,
              initialGroup: activeFolder,
            ),
          );
          break;
        case 3: // Notes tab
          Navigator.of(context).push(
            NoteDetailsScreen.route(
              isEditing: true,
              initialFile: activeVault,
              initialGroup: activeFolder,
            ),
          );
          break;
        case 1: // Records tab
          final result = await Navigator.of(context).push<dynamic>(
            AddRecordCatalogScreen.route(
              initialFile: activeVault,
              initialGroup: activeFolder,
            ),
          );
          if (result is KdbxEntry && mounted) {
            Navigator.of(context).push(
              EntryDetailsScreen.route(entry: result, isNew: true),
            );
          }
          break;
        case 4: // Authenticator tab
          final newEntry = kdbxBloc.createEntry(
            file: activeVault,
            group: activeFolder,
          );
          KeyNestItemTypeHelper.setItemType(newEntry, KeyNestItemType.twoFactor);
          Navigator.of(context).push(
            EntryDetailsScreen.route(entry: newEntry, isNew: true),
          );
          break;
        case 0: // Secrets tab
        default:
          final newEntry = kdbxBloc.createEntry(
            file: activeVault,
            group: activeFolder,
          );
          Navigator.of(context).push(
            EntryDetailsScreen.route(entry: newEntry, isNew: true),
          );
          break;
      }
      return;
    }

    switch (currentTab) {
      case 2: // Cards tab
        _navigatorKey.currentState?.pushAndRemoveUntil(
          AddPaymentCardScreen.route(
            initialFile: activeVault,
            initialGroup: activeFolder,
          ),
          (route) => route.isFirst,
        );
        setState(() {
          _selectedEntry = null;
        });
        break;
      case 3: // Notes tab
        _navigatorKey.currentState?.pushAndRemoveUntil(
          NoteDetailsScreen.route(
            isEditing: true,
            initialFile: activeVault,
            initialGroup: activeFolder,
          ),
          (route) => route.isFirst,
        );
        setState(() {
          _selectedEntry = null;
        });
        break;
      case 1: // Records tab
        final result = await Navigator.of(context).push<dynamic>(
          AddRecordCatalogScreen.route(
            initialFile: activeVault,
            initialGroup: activeFolder,
          ),
        );
        if (result is KdbxEntry) {
          _navigateToEntry(result, isNew: true);
        }
        break;
      case 4: // Authenticator tab
        final newEntry = kdbxBloc.createEntry(
          file: activeVault,
          group: activeFolder,
        );
        KeyNestItemTypeHelper.setItemType(newEntry, KeyNestItemType.twoFactor);
        _navigateToEntry(newEntry, isNew: true);
        break;
      case 0: // Secrets tab
      default:
        final newEntry = kdbxBloc.createEntry(
          file: activeVault,
          group: activeFolder,
        );
        _navigateToEntry(newEntry, isNew: true);
        break;
    }
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
              1600.0,
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
      if (_isNarrowLayout) {
        if (_historyIndex >= 0 && _historyIndex < _history.length - 1) {
          _history.removeRange(_historyIndex + 1, _history.length);
        }
        _history.add(entry);
        _historyIndex = _history.length - 1;
        setState(() => _selectedEntry = entry);
        Navigator.of(context).push(
          _routeForEntry(entry, type == EntrySelectionType.newEntry),
        ).then((_) {
          if (mounted) {
            setState(() => _selectedEntry = null);
          }
        });
        return;
      }
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

  Widget _buildDesktopTopBar(
    BuildContext context,
    bool isDark, {
    bool isNarrow = false,
  }) {
    final kdbxBloc = context.watch<KdbxBloc>();
    final scope = KeyNestVaultScope.instance;
    final selectedVault = scope.getSelectedVault(kdbxBloc);
    final vaultName = selectedVault?.body.meta.databaseName.get() ??
        (selectedVault != null ? 'Active Vault' : 'All Vaults');

    final canGoBack = _canGoBack;
    final canGoForward = _canGoForward;

    final borderColor = isDark
        ? KeyNestPalette.cardBorderDark
        : KeyNestPalette.cardBorderLight;
    final topBarBg = isDark
        ? KeyNestPalette.surfaceContainerDark
        : KeyNestPalette.surfaceLight;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
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
            icon: const Icon(Icons.arrow_back_rounded, size: 19),
            onPressed: canGoBack ? _navigateBack : null,
            tooltip: 'Back',
            splashRadius: 16,
            visualDensity: VisualDensity.compact,
            color: canGoBack
                ? (isDark ? Colors.white : Colors.black87)
                : (isDark ? Colors.white24 : Colors.black26),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward_rounded, size: 19),
            onPressed: canGoForward ? _navigateForward : null,
            tooltip: 'Forward',
            splashRadius: 16,
            visualDensity: VisualDensity.compact,
            color: canGoForward
                ? (isDark ? Colors.white : Colors.black87)
                : (isDark ? Colors.white24 : Colors.black26),
          ),
          const SizedBox(width: 6),
          // Search Pill
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Container(
                  height: 32,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E212B)
                        : const Color(0xFFF1F3F5),
                    borderRadius: BorderRadius.circular(8),
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
                        size: 16,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          onChanged: (val) {
                            KeyNestVaultScope.instance.setSearchQuery(val);
                          },
                          style: TextStyle(
                            fontSize: 12.5,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 6),
                            border: InputBorder.none,
                            hintText: 'Search in $vaultName',
                            hintStyle: TextStyle(
                              fontSize: 12.5,
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
                            size: 15,
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
          const SizedBox(width: 10),
          // Prominent / Compact New Item Button
          isNarrow
              ? IconButton.filled(
                  onPressed: _handleAddNewItem,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  tooltip: 'New Item',
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF0A85EA),
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                )
              : FilledButton.icon(
                  onPressed: _handleAddNewItem,
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: const Text(
                    'New Item',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0A85EA),
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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

  Widget _buildDesktopChipsBar(BuildContext context, bool isDark) {
    return ListenableBuilder(
      listenable: KeyNestVaultScope.instance,
      builder: (context, _) {
        final kdbxBloc = context.watch<KdbxBloc>();
        final scope = KeyNestVaultScope.instance;
        final selectedVault = scope.getSelectedVault(kdbxBloc);
        final borderColor = isDark
            ? KeyNestPalette.cardBorderDark
            : KeyNestPalette.cardBorderLight;
        final currentTab = scope.activeTabIndex ?? _activeRailIndex;

        return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: isDark ? KeyNestPalette.surfaceDark : Colors.white,
        border: Border(
          bottom: BorderSide(color: borderColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          // 1. Vault Chip
          Builder(
            builder: (chipCtx) => KeyNestChip(
              label: selectedVault == null
                  ? 'All Vault Items'
                  : KeyNestVaultScope.cleanVaultName(kdbxBloc, selectedVault),
              icon: Icons.keyboard_arrow_down_rounded,
              isSelected: selectedVault != null,
              onTap: () => KeyNestTopChipsBar.showVaultSelectionSheet(
                chipCtx,
                kdbxBloc,
                tab: scope.currentActiveTab,
              ),
            ),
          ),
          const SizedBox(width: 8),

          // 2. Sort Chip
          Builder(
            builder: (chipCtx) => KeyNestChip(
              label: KeyNestTopChipsBar.sortLabel(scope.sortMode),
              icon: Icons.sort_rounded,
              isSelected: scope.sortMode != VaultSortMode.alphabeticalAsc,
              onTap: () => _showDesktopSortDialog(chipCtx, scope),
            ),
          ),
          const SizedBox(width: 8),

          // 3. Category Chip (for secrets/passwords tab)
          if (currentTab == 0) ...[
            Builder(
              builder: (chipCtx) => KeyNestChip(
                label: scope.selectedCategory ?? 'Category',
                icon: Icons.keyboard_arrow_down_rounded,
                isSelected: scope.selectedCategory != null,
                onTap: () async {
                  final cat = await KeyNestCategoryPicker.show(
                    chipCtx,
                    selectedCategory: scope.selectedCategory,
                  );
                  if (cat == null || cat == 'All') {
                    scope.setSelectedCategory(null);
                  } else {
                    scope.setSelectedCategory(cat);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
          ],

          // 4. Favorites Chip
          KeyNestChip(
            label: 'Favorites',
            icon: Icons.star_rounded,
            isSelected: scope.favoritesOnly,
            onTap: () {
              scope.setFavoritesOnly(!scope.favoritesOnly);
            },
          ),

          // 5. Clear Filter Chip if active
          if (scope.selectedCategory != null || scope.favoritesOnly) ...[
            const SizedBox(width: 8),
            KeyNestChip(
              label: 'Clear filter',
              icon: Icons.close_rounded,
              onTap: () {
                scope.setSelectedCategory(null);
                scope.setFavoritesOnly(false);
              },
            ),
          ],
        ],
      ),
    );
  },
);
}

  void _showDesktopSortDialog(
    BuildContext anchorContext,
    KeyNestVaultScope scope,
  ) {
    showAnchoredPopover<void>(
      anchorContext: anchorContext,
      width: 250,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final isDark = theme.brightness == Brightness.dark;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Text(
                  'Sort entries by',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ),
              const Divider(height: 8),
              ...VaultSortMode.values.map((mode) {
                final isSelected = scope.sortMode == mode;
                return InkWell(
                  onTap: () {
                    scope.setSortMode(mode);
                    Navigator.of(dialogContext).pop();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isSelected ? Icons.check_rounded : null,
                          size: 16,
                          color: const Color(0xFF0A85EA),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            KeyNestTopChipsBar.sortLabel(mode),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: isSelected
                                  ? const Color(0xFF0A85EA)
                                  : (isDark ? Colors.white : Colors.black87),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktopOrWeb = KeyNestPlatform.isDesktopOrWeb;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isDesktopOrWeb) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 780.0;
          _isNarrowLayout = isNarrow;

          final maxAllowedListWidth =
              (constraints.maxWidth - 340.0).clamp(280.0, 1600.0);
          final effectiveListWidth =
              _listPaneWidth.clamp(280.0, maxAllowedListWidth);

          return CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.digit1, control: true): () {
                setState(() => _activeRailIndex = 0);
                KeyNestVaultScope.instance.setActiveTab(0);
              },
              const SingleActivator(LogicalKeyboardKey.digit2, control: true): () {
                setState(() => _activeRailIndex = 1);
                KeyNestVaultScope.instance.setActiveTab(1);
              },
              const SingleActivator(LogicalKeyboardKey.digit3, control: true): () {
                setState(() => _activeRailIndex = 2);
                KeyNestVaultScope.instance.setActiveTab(2);
              },
              const SingleActivator(LogicalKeyboardKey.digit4, control: true): () {
                setState(() => _activeRailIndex = 3);
                KeyNestVaultScope.instance.setActiveTab(3);
              },
              const SingleActivator(LogicalKeyboardKey.digit5, control: true): () {
                setState(() => _activeRailIndex = 4);
                KeyNestVaultScope.instance.setActiveTab(4);
              },
              const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
                _searchFocusNode.requestFocus();
              },
              const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
                _handleAddNewItem();
              },
            },
            child: Scaffold(
              backgroundColor:
                  isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
              body: Row(
                children: <Widget>[
                  // 1. Desktop & Web Navigation Rail (Leftmost) - hidden in narrow mode
                  if (!isNarrow)
                    KeyNestDesktopNavRail(
                      currentIndex: _activeRailIndex,
                      onTap: (index) {
                        setState(() {
                          _activeRailIndex = index;
                        });
                        KeyNestVaultScope.instance.setActiveTab(index);
                      },
                    ),
                  // 2. Right of Rail: Top Bar + Chips Bar + List & Detail Panes
                  Expanded(
                    child: Column(
                      children: [
                        _buildDesktopTopBar(
                          context,
                          isDark,
                          isNarrow: isNarrow,
                        ),
                        _buildDesktopChipsBar(context, isDark),
                        Expanded(
                          child: isNarrow
                              ? ScaffoldMessenger(
                                  child: KeyNestHomeShell(
                                    selectedEntry: _selectedEntry,
                                    isDesktopMaster: false,
                                    onEntrySelected: _onEntrySelected,
                                    onAddNewItem: _handleAddNewItem,
                                  ),
                                )
                              : Row(
                                  children: [
                                    // Middle Pane: List
                                    SizedBox(
                                      width: effectiveListWidth,
                                      child: ScaffoldMessenger(
                                        child: KeyNestHomeShell(
                                          selectedEntry: _selectedEntry,
                                          isDesktopMaster: true,
                                          onEntrySelected: _onEntrySelected,
                                          onAddNewItem: _handleAddNewItem,
                                        ),
                                      ),
                                    ),
                                    // Splitter
                                    _buildSplitterHandle(context, isDark),
                                    // Right Pane: Detail (Full-featured screens via Navigator)
                                    Expanded(
                                      child: ScaffoldMessenger(
                                        child: Navigator(
                                          key: _navigatorKey,
                                        requestFocus: false,
                                        onGenerateRoute: (settings) {
                                          assert(
                                            settings.name ==
                                                Navigator.defaultRouteName,
                                          );
                                          return MaterialPageRoute<void>(
                                            settings: settings,
                                            builder: (context) =>
                                                EmptyStateInitialRoute(
                                              onAddNewItem: _handleAddNewItem,
                                            ),
                                          );
                                        },
                                      ),
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
            ),
          );
        },
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
  const EmptyStateInitialRoute({super.key, this.onAddNewItem});

  final VoidCallback? onAddNewItem;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: KeyNestVaultScope.instance,
      builder: (context, _) {
        final activeTab = KeyNestVaultScope.instance.activeTabIndex ?? 0;
        final String buttonLabel;
        final String typeDescription;
        switch (activeTab) {
          case 1:
            buttonLabel = 'Add Record';
            typeDescription =
                'Select a record from the list to view or edit details';
            break;
          case 2:
            buttonLabel = 'Add Card';
            typeDescription =
                'Select a card from the list to view or edit details';
            break;
          case 3:
            buttonLabel = 'Add Note';
            typeDescription =
                'Select a note from the list to view or edit details';
            break;
          case 4:
            buttonLabel = 'Add 2FA Code';
            typeDescription =
                'Select a 2FA account from the list to view or edit details';
            break;
          case 0:
          default:
            buttonLabel = loc.addNewPasswordButtonLabel;
            typeDescription =
                'Select an item from the list to view or edit details';
            break;
        }

        return Scaffold(
          backgroundColor:
              isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
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
                  typeDescription,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: onAddNewItem,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: Text(buttonLabel),
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
      },
    );
  }
}
