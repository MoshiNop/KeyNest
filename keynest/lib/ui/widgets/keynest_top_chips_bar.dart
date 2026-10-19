import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/password_list.dart' show VaultSortMode;
import 'package:keynest/ui/widgets/keynest_category_picker.dart';
import 'package:keynest/ui/widgets/keynest_chips.dart';
import 'package:keynest/ui/widgets/keynest_search_bar.dart';
import 'package:provider/provider.dart';

/// Standard, unified top chip toolbar used consistently across all tabs.
/// Contains expandable search, vault selector, sort mode, optional category
/// (exclusive to Secrets), and favorites toggle.
class KeyNestTopChipsBar extends StatelessWidget {
  const KeyNestTopChipsBar({
    super.key,
    required this.searchController,
    required this.searchFocusNode,
    required this.isSearchExpanded,
    required this.onSearchExpandedChanged,
    required this.onSearchChanged,
    this.tab = KeyNestTab.secrets,
    this.searchHintText = 'Search vault...',
    this.showCategoryChip = false,
    this.extraChips = const [],
    this.scrollController,
  });

  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final bool isSearchExpanded;
  final ValueChanged<bool> onSearchExpandedChanged;
  final ValueChanged<String> onSearchChanged;
  final KeyNestTab tab;
  final String searchHintText;
  final bool showCategoryChip;
  final List<Widget> extraChips;
  final ScrollController? scrollController;

  static String sortLabel(VaultSortMode mode) {
    switch (mode) {
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

  static void sortEntries(List<KdbxEntry> entries, VaultSortMode mode) {
    switch (mode) {
      case VaultSortMode.alphabeticalAsc:
        entries.sort(
          (a, b) => (a.label ?? '').toLowerCase().compareTo(
            (b.label ?? '').toLowerCase(),
          ),
        );
        break;
      case VaultSortMode.alphabeticalDesc:
        entries.sort(
          (a, b) => (b.label ?? '').toLowerCase().compareTo(
            (a.label ?? '').toLowerCase(),
          ),
        );
        break;
      case VaultSortMode.lastModified:
        entries.sort((a, b) {
          final aMod =
              a.times.lastModificationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final bMod =
              b.times.lastModificationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return bMod.compareTo(aMod);
        });
        break;
      case VaultSortMode.dateCreated:
        entries.sort((a, b) {
          final aCreated =
              a.times.creationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final bCreated =
              b.times.creationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return bCreated.compareTo(aCreated);
        });
        break;
    }
  }

  static void showVaultSelectionSheet(
    BuildContext context,
    KdbxBloc kdbxBloc, {
    KeyNestTab tab = KeyNestTab.secrets,
  }) {
    final openedFiles = kdbxBloc.openedFilesKdbx;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selectedVault = KeyNestVaultScope.instance.getSelectedVault(
      kdbxBloc,
      tab,
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
                      tab,
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
                      .where((e) => !e.isInRecycleBin())
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
                        tab,
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

  static void showSortModal(
    BuildContext context, {
    KeyNestTab tab = KeyNestTab.secrets,
  }) {
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
                  groupValue: KeyNestVaultScope.instance.getSortMode(tab),
                  onChanged: (val) {
                    if (val != null) {
                      KeyNestVaultScope.instance.setSortMode(val, tab);
                      Navigator.pop(ctx);
                    }
                  },
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<VaultSortMode>(
                        title: Text('Title (A → Z)'),
                        subtitle: Text('Alphabetical order'),
                        value: VaultSortMode.alphabeticalAsc,
                      ),
                      RadioListTile<VaultSortMode>(
                        title: Text('Title (Z → A)'),
                        subtitle: Text('Reverse alphabetical order'),
                        value: VaultSortMode.alphabeticalDesc,
                      ),
                      RadioListTile<VaultSortMode>(
                        title: Text('Date Modified'),
                        subtitle: Text('Recently updated items first'),
                        value: VaultSortMode.lastModified,
                      ),
                      RadioListTile<VaultSortMode>(
                        title: Text('Date Created'),
                        subtitle: Text('Newest items first'),
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

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = context.watch<KdbxBloc>();
    final scope = KeyNestVaultScope.instance;
    final selectedVault = scope.getSelectedVault(kdbxBloc, tab);
    final sortMode = scope.getSortMode(tab);
    final isSearchActive =
        isSearchExpanded || searchController.text.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        controller: scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            KeyNestExpandableSearchChip(
              controller: searchController,
              focusNode: searchFocusNode,
              isExpanded: isSearchActive,
              hintText: searchHintText,
              onChanged: onSearchChanged,
              onExpand: () {
                onSearchExpandedChanged(true);
                if (scrollController != null &&
                    scrollController!.hasClients &&
                    scrollController!.offset > 0) {
                  scrollController!.animateTo(
                    0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (searchFocusNode.canRequestFocus) {
                    searchFocusNode.requestFocus();
                  }
                });
              },
              onCollapse: () {
                searchController.clear();
                onSearchChanged('');
                searchFocusNode.unfocus();
                onSearchExpandedChanged(false);
              },
            ),
            const SizedBox(width: 8),
            KeyNestChip(
              label: selectedVault == null
                  ? 'All Vault Items'
                  : KeyNestVaultScope.cleanVaultName(kdbxBloc, selectedVault),
              icon: Icons.keyboard_arrow_down_rounded,
              isSelected: selectedVault != null,
              onTap: () => showVaultSelectionSheet(context, kdbxBloc, tab: tab),
            ),
            const SizedBox(width: 8),
            KeyNestChip(
              label: sortLabel(sortMode),
              icon: Icons.sort_rounded,
              isSelected: sortMode != VaultSortMode.alphabeticalAsc,
              onTap: () => showSortModal(context, tab: tab),
            ),
            if (showCategoryChip) ...[
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
            ],
            const SizedBox(width: 8),
            KeyNestChip(
              label: 'Favorites',
              icon: Icons.star_rounded,
              isSelected: scope.favoritesOnly,
              onTap: () {
                scope.setFavoritesOnly(!scope.favoritesOnly);
              },
            ),
            if (showCategoryChip && scope.selectedCategory != null) ...[
              const SizedBox(width: 8),
              KeyNestChip(
                label: 'Clear category',
                icon: Icons.close_rounded,
                onTap: () {
                  scope.setSelectedCategory(null);
                },
              ),
            ],
            ...extraChips,
          ],
        ),
      ),
    );
  }
}
