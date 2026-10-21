import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/add_record_catalog.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_empty_state.dart';
import 'package:keynest/ui/widgets/keynest_entry_count_header.dart';
import 'package:keynest/ui/widgets/keynest_search_highlight.dart';
import 'package:keynest/ui/widgets/keynest_tab_navigation_handler.dart';
import 'package:keynest/ui/widgets/keynest_top_chips_bar.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:provider/provider.dart';

class RecordsTab extends StatefulWidget {
  const RecordsTab({
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
  State<RecordsTab> createState() => _RecordsTabState();
}

class _RecordsTabState extends State<RecordsTab> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _chipsScrollController = ScrollController();

  bool _isSearchExpanded = false;
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

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = context.watch<KdbxBloc>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final scope = KeyNestVaultScope.instance;

    // Find all entries in the open vault/folder that are Records
    final candidateEntries = scope.getScopedEntries(
      kdbxBloc,
      tab: KeyNestTab.records,
    );
    final currentFolder = scope.getCurrentFolder(kdbxBloc, KeyNestTab.records);
    final isInsideTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(
      currentFolder,
    );

    var allRecordEntries = candidateEntries.where((e) {
      if (!isInsideTrash && KeyNestItemTypeHelper.isEntryInTrash(e)) {
        return false;
      }
      return KeyNestItemTypeHelper.getItemType(e) == KeyNestItemType.record;
    }).toList();

    // Favorites filtering
    if (scope.favoritesOnly) {
      allRecordEntries = allRecordEntries
          .where(
            (e) =>
                e.getString(KdbxKey('is_favorite'))?.getText() == 'true' ||
                e.getString(KdbxKey('IsFavorite'))?.getText() == 'true',
          )
          .toList();
    }

    final displayedRecordEntries = allRecordEntries.where((entry) {
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final title = entry.label?.toLowerCase() ?? '';
        final recordType =
            entry.getString(KdbxKey('RecordType'))?.getText()?.toLowerCase() ??
            '';
        final primaryVal =
            RecordTypeHelper.findPrimaryFieldValue(
              entry,
              recordType,
            )?.toLowerCase() ??
            '';
        if (!title.contains(query) &&
            !recordType.contains(query) &&
            !primaryVal.contains(query)) {
          return false;
        }
      }
      return true;
    }).toList();

    // Sort entries according to active VaultSortMode
    KeyNestTopChipsBar.sortEntries(
      displayedRecordEntries,
      scope.getSortMode(KeyNestTab.records),
    );

    if (widget.onCountChanged != null &&
        _lastReportedCount != displayedRecordEntries.length) {
      _lastReportedCount = displayedRecordEntries.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onCountChanged!(displayedRecordEntries.length);
        }
      });
    }

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
            tab: KeyNestTab.records,
            searchController: _searchController,
            searchFocusNode: _searchFocusNode,
            isSearchExpanded: _isSearchExpanded,
            scrollController: _chipsScrollController,
            searchHintText: 'Search records...',
            showCategoryChip: false,
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

          Expanded(
            child: allRecordEntries.isEmpty && _searchQuery.isEmpty
                ? KeyNestEmptyState(
                    type: EmptyStateType.records,
                    actionLabel: 'Add Record',
                    onAction: () async {
                      await Navigator.of(
                        context,
                      ).push(AddRecordCatalogScreen.route());
                      if (mounted) {
                        setState(() {});
                      }
                    },
                  )
                : displayedRecordEntries.isEmpty
                ? Center(
                    child: Text(
                      _searchQuery.isNotEmpty
                          ? 'No records found for "$_searchQuery"'
                          : (scope.favoritesOnly
                                ? 'No favorite records found'
                                : 'No records found'),
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
                        itemCount: displayedRecordEntries.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return KeyNestEntryCountHeader(
                              count: displayedRecordEntries.length,
                              singularLabel: 'record',
                              pluralLabel: 'records',
                              padding: const EdgeInsets.fromLTRB(0, 4, 0, 10),
                            );
                          }
                          final entry = displayedRecordEntries[index - 1];
                          final recordType =
                              entry
                                  .getString(KdbxKey('RecordType'))
                                  ?.getText() ??
                              'Record';
                          final rawTitle = entry.label?.trim();
                          final primaryVal =
                              RecordTypeHelper.findPrimaryFieldValue(
                                entry,
                                recordType,
                              );

                          final String title;
                          String subtitle;

                          if (rawTitle != null &&
                              rawTitle.isNotEmpty &&
                              rawTitle != 'Record') {
                            title = rawTitle;
                            subtitle =
                                (rawTitle == recordType &&
                                    primaryVal != null &&
                                    primaryVal.isNotEmpty)
                                ? primaryVal
                                : recordType;
                          } else {
                            title = primaryVal ?? recordType;
                            subtitle = recordType;
                          }

                          if (_searchQuery.isNotEmpty &&
                              primaryVal != null &&
                              primaryVal.isNotEmpty &&
                              primaryVal.toLowerCase().contains(
                                _searchQuery.toLowerCase(),
                              ) &&
                              !subtitle.toLowerCase().contains(
                                primaryVal.toLowerCase(),
                              )) {
                            subtitle = '$subtitle • $primaryVal';
                          }

                          final typeIcon = RecordTypeHelper.iconForType(
                            recordType,
                          );

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: KeyNestCard(
                              onTap: () {
                                if (widget.onEntrySelected != null) {
                                  widget.onEntrySelected!(entry);
                                } else {
                                  Navigator.of(context).push(
                                    EntryDetailsScreen.route(entry: entry),
                                  );
                                }
                              },
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF434657)
                                          : KeyNestPalette
                                                .primaryContainerLight,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      typeIcon,
                                      size: 22,
                                      color: isDark
                                          ? KeyNestPalette.primaryDark
                                          : KeyNestPalette.lightIcon,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        KeyNestSearchHighlight.text(
                                          text: title,
                                          query: _searchQuery,
                                          isDark: isDark,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                color: isDark
                                                    ? KeyNestPalette
                                                          .textPrimaryDark
                                                    : KeyNestPalette
                                                          .textPrimaryLight,
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        KeyNestSearchHighlight.text(
                                          text: subtitle,
                                          query: _searchQuery,
                                          isDark: isDark,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: isDark
                                                    ? KeyNestPalette
                                                          .textSecondaryDark
                                                    : KeyNestPalette
                                                          .textSecondaryLight,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 20,
                                    color: isDark
                                        ? KeyNestPalette.textTertiaryDark
                                        : KeyNestPalette.textTertiaryLight,
                                  ),
                                ],
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
