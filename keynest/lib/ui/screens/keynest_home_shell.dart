import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/ui/screens/add_payment_card.dart';
import 'package:keynest/ui/screens/add_record_catalog.dart';
import 'package:keynest/ui/screens/authenticator_tab.dart';
import 'package:keynest/ui/screens/card_details.dart';
import 'package:keynest/ui/screens/cards_tab.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/screens/note_details.dart';
import 'package:keynest/ui/screens/notes_tab.dart';
import 'package:keynest/ui/screens/password_list.dart';
import 'package:keynest/ui/screens/records_tab.dart';
import 'package:keynest/ui/widgets/keynest_header.dart';
import 'package:keynest/ui/widgets/keynest_nav_bar.dart';
import 'package:keynest/ui/widgets/keynest_tab_navigation_handler.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:provider/provider.dart';

class KeyNestHomeShell extends StatefulWidget {
  const KeyNestHomeShell({
    super.key,
    this.onEntrySelected,
    this.selectedEntry,
    this.isDesktopMaster = false,
    this.onAddNewItem,
  });

  static const routeSettings = RouteSettings(name: '/home');

  static Future<void> openEntry(
    BuildContext context,
    KdbxEntry entry, {
    bool isNew = false,
  }) async {
    if (isNew) {
      await Navigator.of(context).push(
        EntryDetailsScreen.route(entry: entry, isNew: true, isEditing: true),
      );
    } else {
      final itemType = KeyNestItemTypeHelper.getItemType(entry);
      if (itemType == KeyNestItemType.card) {
        await Navigator.of(context).push(CardDetailsScreen.route(entry: entry));
      } else if (itemType == KeyNestItemType.note) {
        await Navigator.of(context).push(NoteDetailsScreen.route(entry: entry));
      } else {
        await Navigator.of(context).push(
          EntryDetailsScreen.route(entry: entry, isEditing: false),
        );
      }
    }
    KeyNestVaultScope.instance.notifyScopeChanged();
  }

  static Widget phoneHomeShell(BuildContext context) {
    return KeyNestHomeShell(
      onEntrySelected: (entry, type) {
        openEntry(
          context,
          entry,
          isNew: type == EntrySelectionType.newEntry,
        );
      },
    );
  }

  static Route<void> route({
    OnEntrySelected? onEntrySelected,
    KdbxEntry? selectedEntry,
    bool isDesktopMaster = false,
  }) => KeyNestPageRoute(
    settings: routeSettings,
    builder: (context) => onEntrySelected != null
        ? KeyNestHomeShell(
            onEntrySelected: onEntrySelected,
            selectedEntry: selectedEntry,
            isDesktopMaster: isDesktopMaster,
          )
        : phoneHomeShell(context),
  );

  final OnEntrySelected? onEntrySelected;
  final KdbxEntry? selectedEntry;
  final bool isDesktopMaster;
  final VoidCallback? onAddNewItem;

  @override
  State<KeyNestHomeShell> createState() => _KeyNestHomeShellState();
}

class _KeyNestHomeShellState extends State<KeyNestHomeShell>
    with TickerProviderStateMixin {
  int _currentTabIndex = 0;
  int? _animatingFromIndex;
  late final AnimationController _tabAnimationController;
  late Animation<Offset> _incomingSlideAnimation;
  late Animation<Offset> _outgoingSlideAnimation;
  bool _isSelectionMode = false;
  final Map<int, int> _tabCounts = {};
  final Map<int, KeyNestTabNavigationHandler> _tabHandlers = {};
  late final Set<int> _activatedTabs;

  @override
  void initState() {
    super.initState();
    final initialTab = KeyNestVaultScope.instance.activeTabIndex ?? 0;
    _currentTabIndex = initialTab;
    _activatedTabs = {initialTab};
    _tabAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _incomingSlideAnimation = const AlwaysStoppedAnimation(Offset.zero);
    _outgoingSlideAnimation = const AlwaysStoppedAnimation(Offset.zero);
    _tabAnimationController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (mounted) {
          setState(() {
            _animatingFromIndex = null;
          });
        }
      }
    });
    KeyNestVaultScope.instance.addListener(_onVaultScopeChanged);
  }

  @override
  void dispose() {
    KeyNestVaultScope.instance.removeListener(_onVaultScopeChanged);
    _tabAnimationController.dispose();
    super.dispose();
  }

  void _onVaultScopeChanged() {
    if (mounted) {
      final scope = KeyNestVaultScope.instance;
      final targetTab = scope.activeTabIndex;

      if (targetTab != null) {
        _activatedTabs.add(targetTab);
        if (targetTab != _currentTabIndex) {
          _animateToTab(targetTab);
        }
      }
      _tabCounts.clear();
      _isComputingTabCounts = false;
      setState(() {});
    }
  }

  void _updateTabCount(int tabIndex, int count) {
    if (_tabCounts[tabIndex] != count) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabCounts[tabIndex] != count) {
          setState(() {
            _tabCounts[tabIndex] = count;
          });
        }
      });
    }
  }

  void _computeAllBaselineTabCounts(KdbxBloc kdbxBloc) {
    final scope = KeyNestVaultScope.instance;
    final currentFolder = scope.getCurrentFolder(kdbxBloc);
    final isInsideTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(
      currentFolder,
    );
    final candidateEntries = scope.getScopedEntries(
      kdbxBloc,
      directOnlyForFolder: false,
    );

    int secrets = 0;
    int records = 0;
    int cards = 0;
    int notes = 0;
    int tfas = 0;

    final favOnly = scope.favoritesOnly;
    final selectedCat = scope.selectedCategory?.toLowerCase();
    for (final e in candidateEntries) {
      // candidateEntries is already filtered by excludeTrash: !isInsideTrash
      if (isInsideTrash && !KeyNestItemTypeHelper.isEntryInTrash(e)) {
        continue;
      }
      if (favOnly) {
        final isFav =
            e.getString(KdbxKey('is_favorite'))?.getText() == 'true' ||
            e.getString(KdbxKey('IsFavorite'))?.getText() == 'true';
        if (!isFav) {
          continue;
        }
      }

      final type = KeyNestItemTypeHelper.getItemType(e);
      if (type == KeyNestItemType.record) {
        records++;
      } else if (type == KeyNestItemType.card) {
        cards++;
      } else if (type == KeyNestItemType.note) {
        notes++;
      } else {
        if (selectedCat != null) {
          if (KeyNestItemTypeHelper.getCategory(e).toLowerCase() ==
              selectedCat) {
            secrets++;
          }
        } else {
          secrets++;
        }
      }

      if (EntryTotpHelper.hasTotp(e)) {
        tfas++;
      }
    }

    _tabCounts[0] = secrets;
    _tabCounts[1] = records;
    _tabCounts[2] = cards;
    _tabCounts[3] = notes;
    _tabCounts[4] = tfas;
  }

  bool _isComputingTabCounts = false;

  int _getTabCount(int tabIndex, KdbxBloc kdbxBloc) {
    if (!_tabCounts.containsKey(tabIndex)) {
      if (!_isComputingTabCounts) {
        _isComputingTabCounts = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _computeAllBaselineTabCounts(kdbxBloc);
            _isComputingTabCounts = false;
            if (mounted) {
              setState(() {});
            }
          }
        });
      }
    }
    return _tabCounts[tabIndex] ?? 0;
  }

  void _handleEntrySelected(KdbxEntry entry, EntrySelectionType type) {
    if (type == EntrySelectionType.passiveHighlight) {
      return;
    }
    if (widget.onEntrySelected != null) {
      widget.onEntrySelected!(entry, type);
    } else {
      KeyNestHomeShell.openEntry(
        context,
        entry,
        isNew: type == EntrySelectionType.newEntry,
      );
    }
  }

  Future<void> _onFabPressed() async {
    if (widget.onAddNewItem != null) {
      widget.onAddNewItem!();
      return;
    }
    final kdbxBloc = context.read<KdbxBloc>();
    final scope = KeyNestVaultScope.instance;
    final t = switch (_currentTabIndex) {
      1 => KeyNestTab.records,
      2 => KeyNestTab.cards,
      3 => KeyNestTab.notes,
      4 => KeyNestTab.twoFactor,
      _ => KeyNestTab.secrets,
    };
    final activeVault =
        scope.getSelectedVault(kdbxBloc, t) ??
        kdbxBloc.openedFilesKdbx.firstOrNull;
    final activeFolder = (activeVault != null)
        ? (scope.getCurrentFolder(kdbxBloc, t) ?? activeVault.body.rootGroup)
        : null;

    switch (_currentTabIndex) {
      case 0: // Secrets
        final entry = kdbxBloc.createEntry(
          file: activeVault,
          group: activeFolder,
        );
        if (widget.onEntrySelected != null) {
          widget.onEntrySelected!(entry, EntrySelectionType.newEntry);
        } else {
          await Navigator.of(context).push(
            EntryDetailsScreen.route(entry: entry, isNew: true),
          );
        }
        break;
      case 1: // Records
        await Navigator.of(context).push(
          AddRecordCatalogScreen.route(
            initialFile: activeVault,
            initialGroup: activeFolder,
          ),
        );
        break;
      case 2: // Cards
        await Navigator.of(context).push(
          AddPaymentCardScreen.route(
            initialFile: activeVault,
            initialGroup: activeFolder,
          ),
        );
        break;
      case 3: // Notes
        await Navigator.of(context).push(
          NoteDetailsScreen.route(
            isEditing: true,
            initialFile: activeVault,
            initialGroup: activeFolder,
          ),
        );
        break;
      case 4: // 2FA
        await AuthenticatorTab.showAddOptions(
          context,
          initialFile: activeVault,
          initialGroup: activeFolder,
        );
        break;
    }
    if (mounted) {
      KeyNestVaultScope.instance.notifyScopeChanged();
      setState(() {});
    }
  }

  IconData _tabIcon() {
    switch (_currentTabIndex) {
      case 0:
        return Icons.vpn_key_rounded;
      case 1:
        return Icons.badge_rounded;
      case 2:
        return Icons.credit_card_rounded;
      case 3:
        return Icons.edit_note_rounded;
      case 4:
        return Icons.verified_user_rounded;
      default:
        return Icons.shield_rounded;
    }
  }

  Color _tabColor(bool isDark) {
    switch (_currentTabIndex) {
      case 0:
        return isDark
            ? const Color(0xFF434657)
            : KeyNestTokens.lightPrimaryContainer;
      case 1:
        return isDark ? const Color(0xFF1E2E42) : const Color(0xFFDCEAFE);
      case 2:
        return isDark ? const Color(0xFF14352D) : const Color(0xFFD1FAE5);
      case 3:
        return isDark ? const Color(0xFF382A16) : const Color(0xFFFEF3C7);
      case 4:
        return isDark ? const Color(0xFF153347) : const Color(0xFFE0F2FE);
      default:
        return isDark
            ? const Color(0xFF434657)
            : KeyNestTokens.lightPrimaryContainer;
    }
  }

  Color _tabIconColor(bool isDark) {
    switch (_currentTabIndex) {
      case 0:
        return isDark ? KeyNestTokens.primaryAccent : KeyNestTokens.lightIcon;
      case 1:
        return isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
      case 2:
        return isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857);
      case 3:
        return isDark ? const Color(0xFFFCD34D) : const Color(0xFFB45309);
      case 4:
        return isDark ? const Color(0xFF7DD3FC) : const Color(0xFF0369A1);
      default:
        return isDark ? KeyNestTokens.primaryAccent : KeyNestTokens.lightIcon;
    }
  }

  String _tabTitle() {
    switch (_currentTabIndex) {
      case 0:
        return 'Secrets';
      case 1:
        return 'Records';
      case 2:
        return 'Cards';
      case 3:
        return 'Notes';
      case 4:
        return 'Authenticator';
      default:
        return 'Secrets';
    }
  }

  String _tabSubtitle() {
    switch (_currentTabIndex) {
      case 0:
        return 'Your vault, secured';
      case 1:
        return 'Personal records';
      case 2:
        return 'Payment cards';
      case 3:
        return 'Encrypted notes';
      case 4:
        return '2FA & OTP codes';
      default:
        return 'Your vault, secured';
    }
  }

  void _switchToTab(int index) {
    if (_currentTabIndex != index) {
      if (_isSelectionMode) {
        _isSelectionMode = false;
      }
      _animateToTab(index);
      KeyNestVaultScope.instance.setActiveTab(index);
    }
  }

  void _animateToTab(int targetIndex) {
    if (targetIndex == _currentTabIndex && _animatingFromIndex == null) {
      return;
    }
    final fromIndex = _currentTabIndex;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    if (reduceMotion) {
      _tabAnimationController.stop();
      setState(() {
        _currentTabIndex = targetIndex;
        _animatingFromIndex = null;
      });
      return;
    }

    final slideFromRight = targetIndex > fromIndex;
    _tabAnimationController.stop();

    final curvedAnimation = CurvedAnimation(
      parent: _tabAnimationController,
      curve: KeyNestTokens.fastOutSlowIn,
    );

    _outgoingSlideAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: Offset(slideFromRight ? -1.0 : 1.0, 0.0),
    ).animate(curvedAnimation);

    _incomingSlideAnimation = Tween<Offset>(
      begin: Offset(slideFromRight ? 1.0 : -1.0, 0.0),
      end: Offset.zero,
    ).animate(curvedAnimation);

    _activatedTabs.add(targetIndex);

    setState(() {
      _animatingFromIndex = fromIndex;
      _currentTabIndex = targetIndex;
    });

    _tabAnimationController.forward(from: 0.0);
  }

  Widget _buildTabItem(int index, Widget child) {
    if (!_activatedTabs.contains(index)) {
      return const SizedBox.shrink();
    }
    final isCurrent = index == _currentTabIndex;
    final isOutgoing = index == _animatingFromIndex;
    final isVisible = isCurrent || isOutgoing;

    Widget content = _KeepAlivePage(
      key: PageStorageKey<String>('keynest_tab_page_$index'),
      child: child,
    );

    if (isOutgoing) {
      content = SlideTransition(
        position: _outgoingSlideAnimation,
        child: content,
      );
    } else if (isCurrent && _animatingFromIndex != null) {
      content = SlideTransition(
        position: _incomingSlideAnimation,
        child: content,
      );
    }

    return Offstage(
      offstage: !isVisible,
      child: TickerMode(
        enabled: isVisible,
        child: content,
      ),
    );
  }

  bool _canShellPop(KdbxBloc kdbxBloc) {
    final handler = _tabHandlers[_currentTabIndex];
    // (1) Exit multi-selection
    if (handler?.isSelectionActive() == true) {
      return false;
    }
    // (2) Clear active search
    if (handler?.isSearchActive() == true) {
      return false;
    }
    // (3) Clear folder / Trash / category / favorites filter
    final scope = KeyNestVaultScope.instance;
    final selectedVault = scope.getSelectedVault(kdbxBloc);
    final currentFolder = (selectedVault != null)
        ? scope.getCurrentFolder(kdbxBloc)
        : null;
    final isInsideSubfolder =
        selectedVault != null &&
        currentFolder != null &&
        currentFolder != selectedVault.body.rootGroup;
    final isInsideTrash =
        currentFolder != null &&
        KeyNestItemTypeHelper.isTrashOrRecycleBin(currentFolder);
    final hasCategoryFilter = scope.selectedCategory != null;
    final hasFavoritesFilter = scope.favoritesOnly;

    if (isInsideSubfolder ||
        isInsideTrash ||
        hasCategoryFilter ||
        hasFavoritesFilter) {
      return false;
    }
    // (4) Switch from Cards/Notes/Authenticator to Records, and from Records to Secrets
    if (_currentTabIndex != 0) {
      return false;
    }
    // (5) Only then lock/exit
    return true;
  }

  void _handleShellBack(KdbxBloc kdbxBloc) {
    final handler = _tabHandlers[_currentTabIndex];

    // (1) Exit multi-selection
    if (handler?.isSelectionActive() == true) {
      handler!.exitSelection();
      return;
    }

    // (2) Clear active search
    if (handler?.isSearchActive() == true) {
      handler!.clearSearch();
      return;
    }

    // (3) Clear folder / Trash / category / favorites filter
    final scope = KeyNestVaultScope.instance;
    final selectedVault = scope.getSelectedVault(kdbxBloc);
    final currentFolder = (selectedVault != null)
        ? scope.getCurrentFolder(kdbxBloc)
        : null;
    final isInsideSubfolder =
        selectedVault != null &&
        currentFolder != null &&
        currentFolder != selectedVault.body.rootGroup;
    final isInsideTrash =
        currentFolder != null &&
        KeyNestItemTypeHelper.isTrashOrRecycleBin(currentFolder);
    final hasCategoryFilter = scope.selectedCategory != null;
    final hasFavoritesFilter = scope.favoritesOnly;

    if (isInsideSubfolder) {
      final parent = currentFolder.parent ?? selectedVault.body.rootGroup;
      scope.setCurrentFolder(parent);
      return;
    }
    if (isInsideTrash) {
      if (selectedVault != null) {
        scope.setCurrentFolder(selectedVault.body.rootGroup);
      }
      return;
    }
    if (hasCategoryFilter) {
      scope.setSelectedCategory(null);
      return;
    }
    if (hasFavoritesFilter) {
      scope.setFavoritesOnly(false);
      return;
    }

    // (4) Switch from Cards/Notes/Authenticator to Records, and from Records to Secrets
    if (_currentTabIndex == 2 ||
        _currentTabIndex == 3 ||
        _currentTabIndex == 4) {
      _switchToTab(1); // Records
      return;
    }
    if (_currentTabIndex == 1) {
      _switchToTab(0); // Secrets
      return;
    }

    // (5) Only then lock/exit
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();

    return PopScope(
      canPop: _canShellPop(kdbxBloc),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        _handleShellBack(kdbxBloc);
      },
      child: Scaffold(
        backgroundColor: isDark
            ? KeyNestPalette.bgDark
            : KeyNestPalette.bgLight,
        extendBody: true,
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  // Top Header: User avatar/tab icon, Title, Subtitle, Lock, Settings
                  if (!widget.isDesktopMaster)
                    KeyNestHeader(
                      title: _tabTitle(),
                      subtitle: _tabSubtitle(),
                      icon: _tabIcon(),
                      iconBgColor: _tabColor(isDark),
                      iconColor: _tabIconColor(isDark),
                      onAdd: null,
                    ),

                  // Tab Content with smooth direct slide transitions without flashing
                  Expanded(
                    child: ClipRect(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Tab 0: Secrets (Passwords)
                          _buildTabItem(
                            0,
                            _activatedTabs.contains(0)
                                ? PasswordList(
                                    selectedEntry: widget.selectedEntry,
                                    onEntrySelected: _handleEntrySelected,
                                    embedded: true,
                                    onCountChanged: (count) =>
                                        _updateTabCount(0, count),
                                    onSelectionModeChanged: (isSelecting) {
                                      if (_isSelectionMode != isSelecting) {
                                        setState(() {
                                          _isSelectionMode = isSelecting;
                                        });
                                      }
                                    },
                                    onRegisterNavigationHandler: (h) =>
                                        _tabHandlers[0] = h,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          // Tab 1: Records
                          _buildTabItem(
                            1,
                            _activatedTabs.contains(1)
                                ? RecordsTab(
                                    selectedEntry: widget.selectedEntry,
                                    onEntrySelected:
                                        widget.onEntrySelected != null
                                        ? (entry) => _handleEntrySelected(
                                            entry,
                                            EntrySelectionType.activeOpen,
                                          )
                                        : null,
                                    onCountChanged: (count) =>
                                        _updateTabCount(1, count),
                                    onRegisterNavigationHandler: (h) =>
                                        _tabHandlers[1] = h,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          // Tab 2: Cards
                          _buildTabItem(
                            2,
                            _activatedTabs.contains(2)
                                ? CardsTab(
                                    selectedEntry: widget.selectedEntry,
                                    onEntrySelected:
                                        widget.onEntrySelected != null
                                        ? (entry) => _handleEntrySelected(
                                            entry,
                                            EntrySelectionType.activeOpen,
                                          )
                                        : null,
                                    onCountChanged: (count) =>
                                        _updateTabCount(2, count),
                                    onRegisterNavigationHandler: (h) =>
                                        _tabHandlers[2] = h,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          // Tab 3: Notes
                          _buildTabItem(
                            3,
                            _activatedTabs.contains(3)
                                ? NotesTab(
                                    selectedEntry: widget.selectedEntry,
                                    onEntrySelected:
                                        widget.onEntrySelected != null
                                        ? (entry) => _handleEntrySelected(
                                            entry,
                                            EntrySelectionType.activeOpen,
                                          )
                                        : null,
                                    onCountChanged: (count) =>
                                        _updateTabCount(3, count),
                                    onRegisterNavigationHandler: (h) =>
                                        _tabHandlers[3] = h,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          // Tab 4: 2FA
                          _buildTabItem(
                            4,
                            _activatedTabs.contains(4)
                                ? AuthenticatorTab(
                                    isActive: _currentTabIndex == 4,
                                    selectedEntry: widget.selectedEntry,
                                    onEntrySelected:
                                        widget.onEntrySelected != null
                                        ? (entry) => _handleEntrySelected(
                                            entry,
                                            EntrySelectionType.activeOpen,
                                          )
                                        : null,
                                    onCountChanged: (count) =>
                                        _updateTabCount(4, count),
                                    onRegisterNavigationHandler: (h) =>
                                        _tabHandlers[4] = h,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Smooth localized content fade for items approaching bottom navigation area
            if (!widget.isDesktopMaster)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 96,
                child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        (isDark
                                ? KeyNestPalette.bgDark
                                : KeyNestPalette.bgLight)
                            .withValues(alpha: 0.0),
                        (isDark
                                ? KeyNestPalette.bgDark
                                : KeyNestPalette.bgLight)
                            .withValues(alpha: 0.45),
                        (isDark
                                ? KeyNestPalette.bgDark
                                : KeyNestPalette.bgLight)
                            .withValues(alpha: 0.90),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButton: (widget.isDesktopMaster ||
                (_currentTabIndex == 0 && _isSelectionMode))
            ? null
            : Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FloatingActionButton(
                  tooltip: 'Add item',
                  backgroundColor: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                  foregroundColor: isDark
                      ? const Color(0xFF00315D)
                      : Colors.white,
                  elevation: 4,
                  shape: const CircleBorder(),
                  onPressed: _onFabPressed,
                  child: const Icon(Icons.add_rounded, size: 28),
                ),
              ),
        bottomNavigationBar: widget.isDesktopMaster
            ? null
            : KeyNestBottomNav(
                currentIndex: _currentTabIndex,
                counts: {
                  0: _getTabCount(0, kdbxBloc),
                  1: _getTabCount(1, kdbxBloc),
                  2: _getTabCount(2, kdbxBloc),
                  3: _getTabCount(3, kdbxBloc),
                  4: _getTabCount(4, kdbxBloc),
                },
                onTap: _switchToTab,
              ),
      ),
    );
  }
}

class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({super.key, required this.child});
  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
