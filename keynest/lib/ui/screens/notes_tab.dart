import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/note_details.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_empty_state.dart';
import 'package:keynest/ui/widgets/keynest_entry_count_header.dart';
import 'package:keynest/ui/widgets/keynest_search_highlight.dart';
import 'package:keynest/ui/widgets/keynest_tab_navigation_handler.dart';
import 'package:keynest/ui/widgets/keynest_top_chips_bar.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:provider/provider.dart';

class NotesTab extends StatefulWidget {
  const NotesTab({
    super.key,
    this.onEntrySelected,
    this.onCountChanged,
    this.onRegisterNavigationHandler,
  });

  final void Function(KdbxEntry entry)? onEntrySelected;
  final void Function(int count)? onCountChanged;
  final ValueChanged<KeyNestTabNavigationHandler>? onRegisterNavigationHandler;

  @override
  State<NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends State<NotesTab> with WidgetsBindingObserver {
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

    // Find all entries in the open vault/folder that are Notes
    final candidateEntries = scope.getScopedEntries(
      kdbxBloc,
      tab: KeyNestTab.notes,
    );
    final currentFolder = scope.getCurrentFolder(kdbxBloc, KeyNestTab.notes);
    final isInsideTrash = KeyNestItemTypeHelper.isTrashOrRecycleBin(
      currentFolder,
    );

    var allNoteEntries = candidateEntries.where((e) {
      if (!isInsideTrash && KeyNestItemTypeHelper.isEntryInTrash(e)) {
        return false;
      }
      return KeyNestItemTypeHelper.getItemType(e) == KeyNestItemType.note;
    }).toList();

    // Favorites filtering
    if (scope.favoritesOnly) {
      allNoteEntries = allNoteEntries
          .where(
            (e) =>
                e.getString(KdbxKey('is_favorite'))?.getText() == 'true' ||
                e.getString(KdbxKey('IsFavorite'))?.getText() == 'true',
          )
          .toList();
    }

    final displayedNoteEntries = allNoteEntries.where((entry) {
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final title = entry.label?.toLowerCase() ?? '';
        final notes =
            entry.getString(KdbxKey('Notes'))?.getText()?.toLowerCase() ?? '';
        if (!title.contains(query) && !notes.contains(query)) {
          return false;
        }
      }
      return true;
    }).toList();

    // Sort entries according to active VaultSortMode
    KeyNestTopChipsBar.sortEntries(
      displayedNoteEntries,
      scope.getSortMode(KeyNestTab.notes),
    );

    if (widget.onCountChanged != null &&
        _lastReportedCount != displayedNoteEntries.length) {
      _lastReportedCount = displayedNoteEntries.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onCountChanged!(displayedNoteEntries.length);
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
          KeyNestTopChipsBar(
            tab: KeyNestTab.notes,
            searchController: _searchController,
            searchFocusNode: _searchFocusNode,
            isSearchExpanded: _isSearchExpanded,
            scrollController: _chipsScrollController,
            searchHintText: 'Search notes...',
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

          // List of Notes or Empty State
          Expanded(
            child: allNoteEntries.isEmpty && _searchQuery.isEmpty
                ? KeyNestEmptyState(
                    type: EmptyStateType.notes,
                    actionLabel: 'Add Note',
                    onAction: () {
                      Navigator.of(
                        context,
                      ).push(NoteDetailsScreen.route(isEditing: true));
                    },
                  )
                : displayedNoteEntries.isEmpty
                ? Center(
                    child: Text(
                      _searchQuery.isNotEmpty
                          ? 'No notes found matching "$_searchQuery"'
                          : (scope.favoritesOnly
                                ? 'No favorite notes found'
                                : 'No notes found'),
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
                        itemCount: displayedNoteEntries.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return KeyNestEntryCountHeader(
                              count: displayedNoteEntries.length,
                              singularLabel: 'note',
                              pluralLabel: 'notes',
                              padding: const EdgeInsets.fromLTRB(0, 4, 0, 10),
                            );
                          }
                          final entry = displayedNoteEntries[index - 1];
                          final title = entry.label?.trim().isNotEmpty == true
                              ? entry.label!
                              : 'Untitled Note';
                          final body =
                              entry
                                  .getString(KdbxKey('Notes'))
                                  ?.getText()
                                  ?.trim() ??
                              '';
                          String snippet = 'No content';
                          if (body.isNotEmpty) {
                            if (_searchQuery.isNotEmpty) {
                              final lines = body.split('\n');
                              final matchingLine = lines.firstWhere(
                                (l) => l.toLowerCase().contains(
                                  _searchQuery.toLowerCase(),
                                ),
                                orElse: () => lines.first,
                              );
                              snippet = matchingLine.trim();
                            } else {
                              snippet = body.split('\n').first.trim();
                            }
                          }

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: KeyNestCard(
                              onTap: () {
                                if (widget.onEntrySelected != null) {
                                  widget.onEntrySelected!(entry);
                                } else {
                                  Navigator.of(context).push(
                                    NoteDetailsScreen.route(entry: entry),
                                  );
                                }
                              },
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? KeyNestPalette.primaryContainerDark
                                          : KeyNestPalette
                                                .primaryContainerLight,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Icons.edit_note_rounded,
                                      size: 24,
                                      color: isDark
                                          ? KeyNestPalette.primaryDark
                                          : KeyNestPalette.primary,
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
                                        const SizedBox(height: 4),
                                        KeyNestSearchHighlight.text(
                                          text: snippet,
                                          query: _searchQuery,
                                          isDark: isDark,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
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
