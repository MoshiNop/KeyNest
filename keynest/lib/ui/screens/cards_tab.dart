import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/add_payment_card.dart';
import 'package:keynest/ui/screens/card_details.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_chips.dart';
import 'package:keynest/ui/widgets/keynest_empty_state.dart';
import 'package:keynest/ui/widgets/keynest_entry_count_header.dart';
import 'package:keynest/ui/widgets/keynest_payment_card.dart';
import 'package:keynest/ui/widgets/keynest_search_highlight.dart';
import 'package:keynest/ui/widgets/keynest_tab_navigation_handler.dart';
import 'package:keynest/ui/widgets/keynest_top_chips_bar.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:provider/provider.dart';

class CardsTab extends StatefulWidget {
  const CardsTab({
    super.key,
    this.onEntrySelected,
    this.onCountChanged,
    this.onRegisterNavigationHandler,
    this.selectedEntry,
  });

  final void Function(KdbxEntry entry)? onEntrySelected;
  final void Function(int count)? onCountChanged;
  final ValueChanged<KeyNestTabNavigationHandler>? onRegisterNavigationHandler;
  final KdbxEntry? selectedEntry;

  @override
  State<CardsTab> createState() => _CardsTabState();
}

class _CardsTabState extends State<CardsTab> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _chipsScrollController = ScrollController();

  bool _isSearchExpanded = false;
  String? _cardTypeFilter;
  String _searchQuery = '';
  DateTime? _searchOpenedAt;
  bool _keyboardWasVisible = false;
  int? _lastReportedCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    KeyNestVaultScope.instance.addListener(_onVaultScopeChanged);
    widget.onRegisterNavigationHandler?.call(
      KeyNestTabNavigationHandler(
        isSelectionActive: () => false,
        exitSelection: () {},
        isSearchActive: () => _isSearchExpanded || _searchQuery.isNotEmpty,
        clearSearch: () {
          _searchController.clear();
          _searchFocusNode.unfocus();
          if (mounted) {
            setState(() {
              _isSearchExpanded = false;
              _searchQuery = '';
            });
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    KeyNestVaultScope.instance.removeListener(_onVaultScopeChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _chipsScrollController.dispose();
    super.dispose();
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
        if (_searchController.text.trim().isEmpty) {
          setState(() {
            _isSearchExpanded = false;
          });
          _searchFocusNode.unfocus();
        }
      }
    }
  }

  void _onVaultScopeChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  static Color _parseCardColor(String? rawColorHex) =>
      KeyNestPaymentCardView.parseCardColor(rawColorHex);

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = context.watch<KdbxBloc>();
    final scope = KeyNestVaultScope.instance;

    // Find all entries in the open vault/folder that are Payment Cards
    final candidateEntries = scope.getScopedEntries(
      kdbxBloc,
      tab: KeyNestTab.cards,
    );
    final currentFolder = scope.getCurrentFolder(kdbxBloc, KeyNestTab.cards);
    final isInsideTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(
      currentFolder,
    );

    var allCardEntries = candidateEntries.where((e) {
      if (!isInsideTrash && KeyNestItemTypeHelper.isEntryInTrash(e)) {
        return false;
      }
      return KeyNestItemTypeHelper.getItemType(e) == KeyNestItemType.card;
    }).toList();

    // Favorites filtering
    if (scope.favoritesOnly) {
      allCardEntries = allCardEntries
          .where(
            (e) =>
                e.getString(KdbxKey('is_favorite'))?.getText() == 'true' ||
                e.getString(KdbxKey('IsFavorite'))?.getText() == 'true',
          )
          .toList();
    }

    final effectiveQuery = KeyNestPlatform.isDesktopOrWeb
        ? scope.searchQuery
        : _searchQuery;

    final displayedCardEntries = allCardEntries.where((entry) {
      if (effectiveQuery.isNotEmpty) {
        final query = effectiveQuery.toLowerCase();
        final title = entry.label?.toLowerCase() ?? '';
        final holder =
            entry.getString(KdbxKey('Cardholder'))?.getText()?.toLowerCase() ??
            '';
        final network =
            entry.getString(KdbxKey('Network'))?.getText()?.toLowerCase() ?? '';
        final cardType =
            entry.getString(KdbxKey('CardType'))?.getText()?.toLowerCase() ??
            '';
        final number = entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
        final last4 = number.replaceAll(RegExp(r'\s+'), '');
        final matches =
            title.contains(query) ||
            holder.contains(query) ||
            network.contains(query) ||
            cardType.contains(query) ||
            (last4.length >= 4 && last4.endsWith(query));
        if (!matches) {
          return false;
        }
      }

      if (_cardTypeFilter == 'Credit') {
        final cardType =
            entry.getString(KdbxKey('CardType'))?.getText()?.toLowerCase() ??
            '';
        final network =
            entry.getString(KdbxKey('Network'))?.getText()?.toLowerCase() ?? '';
        final title = entry.label?.toLowerCase() ?? '';
        return cardType == 'credit' ||
            title.contains('credit') ||
            network.contains('credit');
      } else if (_cardTypeFilter == 'Debit') {
        final cardType =
            entry.getString(KdbxKey('CardType'))?.getText()?.toLowerCase() ??
            '';
        final network =
            entry.getString(KdbxKey('Network'))?.getText()?.toLowerCase() ?? '';
        final title = entry.label?.toLowerCase() ?? '';
        return cardType == 'debit' ||
            title.contains('debit') ||
            network.contains('debit');
      }
      return true;
    }).toList();

    // Sort entries according to active VaultSortMode
    KeyNestTopChipsBar.sortEntries(
      displayedCardEntries,
      scope.getSortMode(KeyNestTab.cards),
    );

    if (widget.onCountChanged != null &&
        _lastReportedCount != displayedCardEntries.length) {
      _lastReportedCount = displayedCardEntries.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onCountChanged!(displayedCardEntries.length);
        }
      });
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final childContent = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            notification is UserScrollNotification) {
          if (_searchFocusNode.hasFocus) {
            _searchFocusNode.unfocus();
          }
        }
        return false;
      },
      child: Column(
        children: [
          // Consistent Top Chip Bar Across Tabs (No Category chip)
          if (!KeyNestPlatform.isDesktopOrWeb)
            KeyNestTopChipsBar(
            tab: KeyNestTab.cards,
            searchController: _searchController,
            searchFocusNode: _searchFocusNode,
            isSearchExpanded: _isSearchExpanded,
            scrollController: _chipsScrollController,
            searchHintText: 'Search cards...',
            showCategoryChip: false,
            extraChips: [
              const SizedBox(width: 8),
              KeyNestChip(
                label: 'Credit',
                isSelected: _cardTypeFilter == 'Credit',
                onTap: () {
                  setState(() {
                    _cardTypeFilter = _cardTypeFilter == 'Credit'
                        ? null
                        : 'Credit';
                  });
                },
              ),
              const SizedBox(width: 8),
              KeyNestChip(
                label: 'Debit',
                isSelected: _cardTypeFilter == 'Debit',
                onTap: () {
                  setState(() {
                    _cardTypeFilter = _cardTypeFilter == 'Debit'
                        ? null
                        : 'Debit';
                  });
                },
              ),
            ],
            onSearchExpandedChanged: (expanded) {
              if (expanded) {
                _searchOpenedAt = clock.now();
                _keyboardWasVisible = false;
              }
              setState(() {
                _isSearchExpanded = expanded;
                if (!expanded) {
                  _searchQuery = '';
                  _searchController.clear();
                  _searchFocusNode.unfocus();
                }
              });
            },
            onSearchChanged: (val) {
              setState(() {
                _searchQuery = val.trim();
              });
            },
          ),

          // List of Cards or Empty State
          Expanded(
            child:
                allCardEntries.isEmpty &&
                    effectiveQuery.isEmpty &&
                    _cardTypeFilter == null
                ? KeyNestEmptyState(
                    type: EmptyStateType.cards,
                    actionLabel: 'Add Card',
                    onAction: () {
                      if (KeyNestPlatform.isDesktopOrWeb &&
                          widget.onEntrySelected != null) {
                        final newEntry = kdbxBloc.createEntry(
                          file: scope.getSelectedVault(kdbxBloc) ??
                              kdbxBloc.openedFilesKdbx.firstOrNull,
                          group: scope.getCurrentFolder(
                            kdbxBloc,
                            KeyNestTab.cards,
                          ),
                        );
                        KeyNestItemTypeHelper.setItemType(
                          newEntry,
                          KeyNestItemType.card,
                        );
                        widget.onEntrySelected!(newEntry);
                        return;
                      }
                      Navigator.of(context).push(AddPaymentCardScreen.route());
                    },
                  )
                : displayedCardEntries.isEmpty
                ? Center(
                    child: Text(
                      effectiveQuery.isNotEmpty
                          ? 'No cards found matching "$effectiveQuery"'
                          : (scope.favoritesOnly
                                ? 'No favorite cards found'
                                : 'No cards found'),
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                      ),
                    ),
                  )
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: KeyNestTokens.contentMaxWidth,
                      ),
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
                        itemCount: displayedCardEntries.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return KeyNestEntryCountHeader(
                              count: displayedCardEntries.length,
                              singularLabel: 'card',
                              pluralLabel: 'cards',
                              padding: const EdgeInsets.fromLTRB(0, 4, 0, 10),
                            );
                          }
                          final entry = displayedCardEntries[index - 1];
                          final holder =
                              entry
                                  .getString(KdbxKey('Cardholder'))
                                  ?.getText() ??
                              'CARDHOLDER NAME';
                          final number =
                              entry
                                  .getString(KdbxKeyCommon.PASSWORD)
                                  ?.getText() ??
                              '';
                          final expiry =
                              entry.getString(KdbxKey('Expiry'))?.getText() ??
                              'MM/YY';
                          final network =
                              entry.getString(KdbxKey('Network'))?.getText() ??
                              'Auto';
                          final colorHex = entry
                              .getString(KdbxKey('CardColorHex'))
                              ?.getText();
                          final color = _parseCardColor(colorHex);
                          final title = entry.label?.trim() ?? '';
                          final showCustomTitle =
                              title.isNotEmpty &&
                              title.toLowerCase() != 'payment card' &&
                              title.toLowerCase() != holder.toLowerCase();

                          final isSelected = widget.selectedEntry == entry;

                          if (KeyNestPlatform.isDesktopOrWeb) {
                            final cleanNumber = number.replaceAll(RegExp(r'\D'), '');
                            final last4 = cleanNumber.length >= 4
                                ? cleanNumber.substring(cleanNumber.length - 4)
                                : (cleanNumber.isNotEmpty ? cleanNumber : '••••');
                            final maskedDisplay = '•••• $last4';
                            final effectiveTitle = title.isNotEmpty
                                ? title
                                : (holder.isNotEmpty && holder.toLowerCase() != 'cardholder name'
                                    ? holder
                                    : 'Payment Card');

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: KeyNestCard(
                                isSelected: isSelected,
                                onTap: () {
                                  if (widget.onEntrySelected != null) {
                                    widget.onEntrySelected!(entry);
                                  } else {
                                    Navigator.of(context).push(
                                      CardDetailsScreen.route(entry: entry),
                                    );
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  child: Row(
                                    children: [
                                      // Mini stylized card preview
                                      Container(
                                        width: 44,
                                        height: 30,
                                        decoration: BoxDecoration(
                                          color: color,
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(
                                            color: Colors.white.withValues(alpha: 0.15),
                                            width: 1,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: color.withValues(alpha: 0.35),
                                              blurRadius: 4,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Stack(
                                          children: [
                                            Positioned(
                                              left: 4,
                                              top: 5,
                                              child: Container(
                                                width: 10,
                                                height: 7,
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFEAB308),
                                                  borderRadius: BorderRadius.circular(1.5),
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              right: 4,
                                              bottom: 3,
                                              child: Icon(
                                                Icons.credit_card_rounded,
                                                color: Colors.white.withValues(alpha: 0.8),
                                                size: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      // Details
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            KeyNestSearchHighlight.text(
                                              text: effectiveTitle,
                                              query: effectiveQuery,
                                              isDark: isDark,
                                              style: theme.textTheme.titleSmall?.copyWith(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 14,
                                                color: isDark
                                                    ? KeyNestPalette.textPrimaryDark
                                                    : KeyNestPalette.textPrimaryLight,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Row(
                                              children: [
                                                Text(
                                                  maskedDisplay,
                                                  style: TextStyle(
                                                    fontFamily: KeyNestTheme.monoFontFamily,
                                                    fontSize: 12,
                                                    color: isDark
                                                        ? KeyNestPalette.textSecondaryDark
                                                        : KeyNestPalette.textSecondaryLight,
                                                  ),
                                                ),
                                                if (expiry.isNotEmpty && expiry != 'MM/YY') ...[
                                                  Text(
                                                    ' • ',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: isDark
                                                          ? KeyNestPalette.textSecondaryDark
                                                          : KeyNestPalette.textSecondaryLight,
                                                    ),
                                                  ),
                                                  Text(
                                                    expiry,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: isDark
                                                          ? KeyNestPalette.textSecondaryDark
                                                          : KeyNestPalette.textSecondaryLight,
                                                    ),
                                                  ),
                                                ],
                                                if (holder.isNotEmpty &&
                                                    holder != effectiveTitle &&
                                                    holder.toLowerCase() != 'cardholder name') ...[
                                                  Text(
                                                    ' • ',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: isDark
                                                          ? KeyNestPalette.textSecondaryDark
                                                          : KeyNestPalette.textSecondaryLight,
                                                    ),
                                                  ),
                                                  Flexible(
                                                    child: Text(
                                                      holder,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: isDark
                                                            ? KeyNestPalette.textSecondaryDark
                                                            : KeyNestPalette.textSecondaryLight,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? Colors.white.withValues(alpha: 0.08)
                                              : Colors.black.withValues(alpha: 0.05),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          network != 'Auto' ? network : 'Card',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: isDark
                                                ? KeyNestPalette.textSecondaryDark
                                                : KeyNestPalette.textSecondaryLight,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: KeyNestPressScale(
                              onTap: () {
                                if (widget.onEntrySelected != null) {
                                  widget.onEntrySelected!(entry);
                                } else {
                                  Navigator.of(context).push(
                                    CardDetailsScreen.route(entry: entry),
                                  );
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: isSelected
                                    ? BoxDecoration(
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: isDark
                                              ? KeyNestPalette.primaryDark
                                              : KeyNestPalette.primary,
                                          width: 2.5,
                                        ),
                                      )
                                    : null,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (showCustomTitle)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 6,
                                          left: 4,
                                        ),
                                        child: KeyNestSearchHighlight.text(
                                          text: title,
                                          query: effectiveQuery,
                                          isDark: isDark,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                color: isDark
                                                    ? KeyNestPalette
                                                          .textPrimaryDark
                                                    : KeyNestPalette
                                                          .textPrimaryLight,
                                              ),
                                        ),
                                      ),
                                    KeyNestPaymentCardView(
                                      cardholderName: holder,
                                      cardNumber: number,
                                      expiry: expiry,
                                      cardNetwork: network,
                                      cardColor: color,
                                      searchQuery: effectiveQuery,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );

    if (widget.onRegisterNavigationHandler != null) {
      return childContent;
    }

    return PopScope(
      canPop: !_isSearchExpanded && _searchQuery.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        if (_isSearchExpanded || _searchQuery.isNotEmpty) {
          _searchController.clear();
          _searchFocusNode.unfocus();
          setState(() {
            _isSearchExpanded = false;
            _searchQuery = '';
          });
        }
      },
      child: childContent,
    );
  }
}
