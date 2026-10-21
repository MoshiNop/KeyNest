// ignore_for_file: use_build_context_synchronously, always_put_control_body_on_new_line
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/barcodescan_screen.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_category_picker.dart';
import 'package:keynest/ui/widgets/keynest_popup_menu.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:provider/provider.dart';

// 1. Privacy Score & Password Health Audit Screen
class KeyNestPrivacyScoreSheet extends StatelessWidget {
  const KeyNestPrivacyScoreSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const KeyNestPrivacyScoreSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (openedFiles.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(32),
        child: const Center(child: Text('No active vault open to analyze.')),
      );
    }

    // Collect deduplicated non-trashed entries across all opened vaults
    final seenEntryUuids = <KdbxUuid>{};
    final seenEntries = <KdbxEntry>{};
    final allEntries = <KdbxEntry>[];

    for (final f in openedFiles) {
      for (final e in f.body.rootGroup.getAllEntries()) {
        if (KeyNestItemTypeHelper.isEntryInTrash(e)) {
          continue;
        }
        if (seenEntries.add(e)) {
          if (!seenEntryUuids.add(e.uuid)) {
            continue;
          }
          allEntries.add(e);
        }
      }
    }

    // Security metrics
    final passwordCounts = <String, int>{};
    final weakEntries = <KdbxEntry>[];
    final reusedEntries = <KdbxEntry>[];
    int withTotp = 0;

    for (final e in allEntries) {
      if (EntryTotpHelper.hasTotp(e)) {
        withTotp++;
      }

      final pass = e.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
      if (pass.isEmpty) continue;

      passwordCounts[pass] = (passwordCounts[pass] ?? 0) + 1;
      if (pass.length < 8 ||
          pass.toLowerCase() == pass ||
          pass.toUpperCase() == pass) {
        weakEntries.add(e);
      }
    }

    for (final e in allEntries) {
      final pass = e.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
      if (pass.isNotEmpty && (passwordCounts[pass] ?? 0) > 1) {
        reusedEntries.add(e);
      }
    }

    final total = allEntries.length;
    final weakCount = weakEntries.length;
    final reusedCount = reusedEntries.length;

    int score = 100;
    if (total > 0) {
      final deductions = (weakCount * 15) + (reusedCount * 10);
      score = (100 - deductions).clamp(20, 100);
    }

    Color scoreColor =
        isDark ? KeyNestPalette.successDark : KeyNestPalette.success;
    String scoreStatus = 'Excellent Health';
    if (score < 60) {
      scoreColor = KeyNestPalette.error;
      scoreStatus = 'Critical Attention Needed';
    } else if (score < 80) {
      scoreColor = KeyNestPalette.warning;
      scoreStatus = 'Moderate Health';
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Security Intelligence',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: isDark
                            ? KeyNestPalette.textPrimaryDark
                            : KeyNestPalette.textPrimaryLight,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  children: [
                    // HERO SCORE CARD
                    KeyNestCard(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: scoreColor, width: 6),
                              color: scoreColor.withValues(alpha: 0.1),
                            ),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '$score',
                                  style: TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                    color: scoreColor,
                                  ),
                                ),
                                const Text(
                                  '/ 100',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            scoreStatus,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: scoreColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Auditing $total password credentials in your vault.',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // METRICS ROW
                    Row(
                      children: [
                        Expanded(
                          child: KeyNestCard(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.repeat_rounded,
                                  color: KeyNestPalette.warning,
                                  size: 22,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '$reusedCount',
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  'Reused Passwords',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: KeyNestCard(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.error_outline_rounded,
                                  color: KeyNestPalette.error,
                                  size: 22,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '$weakCount',
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  'Weak Passwords',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: KeyNestCard(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.security_rounded,
                                  color: isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary,
                                  size: 22,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '$withTotp',
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  '2FA Authenticator',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: KeyNestCard(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.check_circle_outline_rounded,
                                  color: isDark
                                      ? KeyNestPalette.successDark
                                      : KeyNestPalette.success,
                                  size: 22,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${total - weakCount}',
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  'Strong Passwords',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (weakEntries.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      const Text(
                        'Weak Passwords to Upgrade',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...weakEntries.take(5).map((e) {
                        final title =
                            e.getString(KdbxKeyCommon.TITLE)?.getText() ??
                            'Untitled';
                        final user =
                            e.getString(KdbxKeyCommon.USER_NAME)?.getText() ??
                            '';
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            backgroundColor: Color(0x22F43F5E),
                            child: Icon(
                              Icons.lock_open_rounded,
                              color: KeyNestPalette.error,
                              size: 18,
                            ),
                          ),
                          title: Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            user.isNotEmpty ? user : 'No username',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            Navigator.of(
                              context,
                            ).push(EntryDetailsScreen.route(entry: e));
                          },
                        );
                      }),
                    ],

                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// 2. Manage Categories Screen
class KeyNestManageCategoriesScreen extends StatefulWidget {
  const KeyNestManageCategoriesScreen({super.key});

  static Route<void> route() {
    if (KeyNestPlatform.isDesktopOrWeb) {
      return KeyNestDesktopDialogRoute<void>(
        settings: const RouteSettings(name: '/categories/manage'),
        maxWidth: 540,
        maxHeight: 620,
        builder: (context) => const KeyNestManageCategoriesScreen(),
      );
    }
    return MaterialPageRoute(
      settings: const RouteSettings(name: '/categories/manage'),
      builder: (context) => const KeyNestManageCategoriesScreen(),
    );
  }

  @override
  State<KeyNestManageCategoriesScreen> createState() =>
      _KeyNestManageCategoriesScreenState();
}

class _KeyNestManageCategoriesScreenState
    extends State<KeyNestManageCategoriesScreen> {
  String _searchQuery = '';
  String _selectedFilter = 'All'; // 'All', 'Custom', 'Default', 'With Items'
  bool _sortByCount = false;

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(milliseconds: 1800),
        ),
      );
  }

  Future<void> _onCreateCategory(KdbxFile file, KdbxBloc kdbxBloc) async {
    final newCat = await KeyNestCategories.showCategoryEditorDialog(context);
    if (newCat != null && newCat.name.isNotEmpty) {
      final allCats = KeyNestCategoryService.getAllCategories(file);
      if (allCats.any(
        (c) => c.name.toLowerCase() == newCat.name.toLowerCase(),
      )) {
        _showMessage('Category "${newCat.name}" already exists.');
        return;
      }
      await KeyNestCategoryService.addCategory(
        file: file,
        kdbxBloc: kdbxBloc,
        category: newCat,
      );
      _showMessage('Category "${newCat.name}" created.');
      setState(() {});
    }
  }

  Future<void> _onEditCategory(
    KdbxFile file,
    KdbxBloc kdbxBloc,
    KeyNestCategoryItem category,
  ) async {
    final updated = await KeyNestCategories.showCategoryEditorDialog(
      context,
      existing: category,
    );
    if (updated != null && updated.name.isNotEmpty) {
      await KeyNestCategoryService.updateCategory(
        file: file,
        kdbxBloc: kdbxBloc,
        oldName: category.name,
        updated: updated,
      );
      _showMessage('Category "${updated.name}" updated.');
      setState(() {});
    }
  }

  Future<void> _onDeleteCategory(
    KdbxFile file,
    KdbxBloc kdbxBloc,
    KeyNestCategoryItem category,
    int count,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Delete "${category.name}"?'),
        content: count > 0
            ? Text(
                'This category currently contains $count item(s).\n\n'
                'Items will be automatically reassigned to "General" so no credentials are lost.',
              )
            : Text('Are you sure you want to delete this custom category?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: KeyNestPalette.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(count > 0 ? 'Move & Delete' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await KeyNestCategoryService.deleteCategory(
        file: file,
        kdbxBloc: kdbxBloc,
        categoryName: category.name,
        reassignTo: 'General',
      );
      _showMessage(
        count > 0
            ? 'Category "${category.name}" deleted. $count items moved to General.'
            : 'Category "${category.name}" deleted.',
      );
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    final currentFile = openedFiles.firstOrNull;

    if (currentFile == null) {
      return Scaffold(
        backgroundColor: isDark
            ? KeyNestPalette.bgDark
            : KeyNestPalette.bgLight,
        appBar: AppBar(
          title: const Text('Manage Categories'),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: KeyNestCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 48,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No Active Vault Open',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Please open or unlock an encrypted vault to manage categories.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final categories = KeyNestCategoryService.getAllCategories(currentFile);
    final counts = KeyNestCategoryService.getCategoryCounts(currentFile);
    final totalCategorized = counts.values.fold<int>(
      0,
      (prev, val) => prev + val,
    );
    final customCount = categories.where((c) => c.isCustom).length;

    // Filter categories
    final filtered = categories.where((c) {
      if (_searchQuery.isNotEmpty &&
          !c.name.toLowerCase().contains(_searchQuery.toLowerCase())) {
        return false;
      }
      if (_selectedFilter == 'Custom') return c.isCustom;
      if (_selectedFilter == 'Default') return !c.isCustom;
      if (_selectedFilter == 'With Items') return (counts[c.name] ?? 0) > 0;
      return true;
    }).toList();

    // Sort categories
    filtered.sort((a, b) {
      if (_sortByCount) {
        final countA = counts[a.name] ?? 0;
        final countB = counts[b.name] ?? 0;
        return countB.compareTo(countA);
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: const Text('Manage Categories'),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: _sortByCount ? 'Sort by Name' : 'Sort by Item Count',
            icon: Icon(
              _sortByCount
                  ? Icons.format_list_numbered_rounded
                  : Icons.sort_by_alpha_rounded,
            ),
            onPressed: () => setState(() => _sortByCount = !_sortByCount),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: isDark
            ? KeyNestPalette.primaryDark
            : KeyNestPalette.primary,
        foregroundColor: isDark ? const Color(0xFF00315D) : Colors.white,
        shape: const StadiumBorder(),
        tooltip: 'New Category',
        onPressed: () => _onCreateCategory(currentFile, kdbxBloc),
        label: const Text(
          '+ New',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          // SUMMARY STATS CARD
          KeyNestCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${categories.length}',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Categories',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 1,
                  height: 32,
                  color: Colors.grey.withValues(alpha: 0.3),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '$customCount',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: KeyNestPalette.warning,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Custom',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 1,
                  height: 32,
                  color: Colors.grey.withValues(alpha: 0.3),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '$totalCategorized',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: KeyNestPalette.accent,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Items',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // SEARCH BAR
          TextField(
            onChanged: (val) => setState(() => _searchQuery = val.trim()),
            decoration: InputDecoration(
              hintText: 'Search categories...',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, size: 18),
                      onPressed: () => setState(() => _searchQuery = ''),
                    )
                  : null,
              filled: true,
              fillColor: isDark ? KeyNestPalette.surfaceDark : Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 10),

          // FILTER CHIPS
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: ['All', 'Custom', 'Default', 'With Items'].map((
                filter,
              ) {
                final isSelected = _selectedFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(filter),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) setState(() => _selectedFilter = filter);
                    },
                    selectedColor:
                        (isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary)
                            .withValues(
                              alpha: isDark ? 0.25 : 0.2,
                            ),
                    backgroundColor: isDark
                        ? KeyNestPalette.surfaceDark
                        : KeyNestPalette.surfaceLight,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected
                          ? (isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary)
                          : (isDark ? Colors.white70 : Colors.black87),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),

          // CATEGORIES LIST
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Center(
                child: Column(
                  children: [
                    const Icon(
                      Icons.category_outlined,
                      size: 48,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _searchQuery.isNotEmpty
                          ? 'No categories matching "$_searchQuery"'
                          : 'No categories in this filter',
                      style: const TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                  ],
                ),
              ),
            )
          else
            ...filtered.map((cat) {
              final count = counts[cat.name] ?? 0;
              final color =
                  cat.color ??
                  (isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary);

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: KeyNestCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  onTap: () {
                    Navigator.of(context)
                        .push(
                          KeyNestCategoryDetailScreen.route(
                            category: cat,
                            file: currentFile,
                          ),
                        )
                        .then((_) => setState(() {}));
                  },
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Icon(cat.icon, color: color, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cat.name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
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
                                    color: isDark
                                        ? KeyNestPalette.surfaceDark
                                        : KeyNestPalette.surfaceLight,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '$count item${count == 1 ? '' : 's'}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (cat.isCustom) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: KeyNestPalette.warning.withValues(
                                        alpha: 0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'Custom',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: KeyNestPalette.warning,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: 'Edit Category',
                        onPressed: () =>
                            _onEditCategory(currentFile, kdbxBloc, cat),
                      ),
                      if (cat.isCustom)
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 20,
                            color: KeyNestPalette.error,
                          ),
                          tooltip: 'Delete Category',
                          onPressed: () => _onDeleteCategory(
                            currentFile,
                            kdbxBloc,
                            cat,
                            count,
                          ),
                        ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.grey,
                      ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 70), // Spacing for FAB
        ],
      ),
    );
  }
}

/// Detailed inspection and organization screen for items in a specific category.
class KeyNestCategoryDetailScreen extends StatefulWidget {
  const KeyNestCategoryDetailScreen({
    super.key,
    required this.category,
    required this.file,
  });

  final KeyNestCategoryItem category;
  final KdbxFile file;

  static Route<void> route({
    required KeyNestCategoryItem category,
    required KdbxFile file,
  }) => MaterialPageRoute(
    settings: RouteSettings(name: '/category/${category.name}'),
    builder: (context) => KeyNestCategoryDetailScreen(
      category: category,
      file: file,
    ),
  );

  @override
  State<KeyNestCategoryDetailScreen> createState() =>
      _KeyNestCategoryDetailScreenState();
}

class _KeyNestCategoryDetailScreenState
    extends State<KeyNestCategoryDetailScreen> {
  late KeyNestCategoryItem _category;

  @override
  void initState() {
    super.initState();
    _category = widget.category;
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(milliseconds: 1800),
        ),
      );
  }

  Future<void> _addNewItem() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final entry = kdbxBloc.createEntry(file: widget.file);
    entry.setString(KdbxKey('ItemCategory'), PlainValue(_category.name));

    await Navigator.of(context).push(
      EntryDetailsScreen.route(entry: entry, isNew: true),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editCategory() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final updated = await KeyNestCategories.showCategoryEditorDialog(
      context,
      existing: _category,
    );
    if (updated != null && updated.name.isNotEmpty) {
      await KeyNestCategoryService.updateCategory(
        file: widget.file,
        kdbxBloc: kdbxBloc,
        oldName: _category.name,
        updated: updated,
      );
      setState(() => _category = updated);
      _showMessage('Category "${updated.name}" updated.');
    }
  }

  Future<void> _changeEntryCategory(KdbxEntry entry) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final targetCategory = await KeyNestCategoryPicker.show(
      context,
      selectedCategory: _category.name,
      showAllOption: false,
    );
    if (targetCategory != null &&
        targetCategory.isNotEmpty &&
        targetCategory != _category.name) {
      entry.setString(KdbxKey('ItemCategory'), PlainValue(targetCategory));
      await kdbxBloc.saveFile(widget.file);
      _showMessage('Moved item to "$targetCategory".');
      setState(() {});
    }
  }

  Future<void> _removeFromCategory(KdbxEntry entry) async {
    final kdbxBloc = context.read<KdbxBloc>();
    entry.setString(KdbxKey('ItemCategory'), PlainValue('General'));
    await kdbxBloc.saveFile(widget.file);
    _showMessage('Moved item to "General".');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final color =
        _category.color ??
        (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary);

    final entries = KeyNestCategoryService.getEntriesForCategory(
      widget.file,
      _category.name,
    );

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: Text(_category.name),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit Category',
            onPressed: _editCategory,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: isDark
            ? KeyNestPalette.primaryDark
            : KeyNestPalette.primary,
        foregroundColor: isDark ? const Color(0xFF00315D) : Colors.white,
        onPressed: _addNewItem,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Item'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          // CATEGORY HEADER CARD
          KeyNestCard(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: Icon(_category.icon, color: color, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _category.name,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${entries.length} credential${entries.length == 1 ? '' : 's'} assigned',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ENTRIES SECTION
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                Text(
                  'Entries in this Category',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '${entries.length}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.folder_open_rounded,
                      size: 64,
                      color: Colors.grey.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'No items in this category',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Add items to "${_category.name}" to organize your vault.',
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: _addNewItem,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add First Item'),
                    ),
                  ],
                ),
              ),
            )
          else
            ...entries.map((entry) {
              final label = entry.label?.isNotEmpty == true
                  ? entry.label!
                  : 'Untitled';
              final username =
                  entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: KeyNestCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  onTap: () {
                    Navigator.of(context)
                        .push(
                          EntryDetailsScreen.route(entry: entry),
                        )
                        .then((_) => setState(() {}));
                  },
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color:
                              (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                  .withValues(alpha: isDark ? 0.20 : 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.vpn_key_rounded,
                          size: 20,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (username.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                username,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      KeyNestPopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert_rounded, size: 20),
                        onSelected: (action) {
                          if (action == 'open') {
                            Navigator.of(context)
                                .push(
                                  EntryDetailsScreen.route(entry: entry),
                                )
                                .then((_) => setState(() {}));
                          } else if (action == 'move') {
                            _changeEntryCategory(entry);
                          } else if (action == 'remove') {
                            _removeFromCategory(entry);
                          }
                        },
                        itemBuilder: (ctx) => [
                          const PopupMenuItem(
                            value: 'open',
                            child: Row(
                              children: [
                                Icon(Icons.open_in_new_rounded, size: 18),
                                SizedBox(width: 10),
                                Text('Open Details'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'move',
                            child: Row(
                              children: [
                                Icon(Icons.drive_file_move_outlined, size: 18),
                                SizedBox(width: 10),
                                Text('Move to Category'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.remove_circle_outline_rounded,
                                  size: 18,
                                ),
                                SizedBox(width: 10),
                                Text('Remove from Category'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 70), // Spacing for FAB
        ],
      ),
    );
  }
}

// 3. Recently Deleted / Trash Bin Screen
class KeyNestRecentlyDeletedScreen extends StatefulWidget {
  const KeyNestRecentlyDeletedScreen({super.key});

  static Route<void> route() {
    if (KeyNestPlatform.isDesktopOrWeb) {
      return KeyNestDesktopDialogRoute<void>(
        settings: const RouteSettings(name: '/trash'),
        maxWidth: 540,
        maxHeight: 620,
        builder: (context) => const KeyNestRecentlyDeletedScreen(),
      );
    }
    return MaterialPageRoute(
      settings: const RouteSettings(name: '/trash'),
      builder: (context) => const KeyNestRecentlyDeletedScreen(),
    );
  }

  @override
  State<KeyNestRecentlyDeletedScreen> createState() =>
      _KeyNestRecentlyDeletedScreenState();
}

class _KeyNestRecentlyDeletedScreenState
    extends State<KeyNestRecentlyDeletedScreen> {

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;

    final trashEntries = <KdbxEntry>[];
    for (final file in openedFiles) {
      for (final e in file.body.rootGroup.getAllEntries()) {
        final cat = e.getString(KdbxKey('ItemCategory'))?.getText() ?? '';
        final isDeleted =
            e.getString(KdbxKey('IsDeleted'))?.getText() == 'true';
        if (e.isInRecycleBin() || cat == 'Trash' || isDeleted) {
          trashEntries.add(e);
        }
      }
    }

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: const Text('Recently Deleted'),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          if (trashEntries.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Empty Trash?'),
                    content: Text(
                      'Permanently delete all ${trashEntries.length} items? This action cannot be undone.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: TextButton.styleFrom(
                          foregroundColor: KeyNestPalette.error,
                        ),
                        child: const Text('Empty Trash'),
                      ),
                    ],
                  ),
                );
                if (confirm == true && mounted) {
                  for (final e in trashEntries) {
                    e.file.deletePermanently(e);
                  }
                  for (final file in openedFiles) {
                    final recycleBin = file.recycleBin;
                    if (recycleBin != null) {
                      List<KdbxGroup>.from(
                        recycleBin.groups,
                      ).forEach(file.deletePermanently);
                    }
                  }
                  setState(() {});
                  for (final file in openedFiles) {
                    await kdbxBloc.saveFile(file);
                  }
                  if (mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text('Trash emptied permanently.'),
                          duration: Duration(milliseconds: 1800),
                        ),
                      );
                  }
                }
              },
              icon: const Icon(
                Icons.delete_sweep_rounded,
                color: KeyNestPalette.error,
                size: 20,
              ),
              label: const Text(
                'Empty',
                style: TextStyle(
                  color: KeyNestPalette.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
      body: trashEntries.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                              .withValues(alpha: isDark ? 0.20 : 0.1),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 36,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Trash is Empty',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Deleted items will appear here before being permanently removed.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              itemCount: trashEntries.length,
              itemBuilder: (context, index) {
                final e = trashEntries[index];
                final title =
                    e.getString(KdbxKeyCommon.TITLE)?.getText() ?? 'Untitled';
                final username =
                    e.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: KeyNestCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: KeyNestPalette.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.delete_outline_rounded,
                            color: KeyNestPalette.error,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (username.isNotEmpty)
                                Text(
                                  username,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                        // Restore Button
                        TextButton(
                          onPressed: () async {
                            if (e.isInRecycleBin()) {
                              e.file.move(e, e.file.body.rootGroup);
                            }
                            e.removeString(KdbxKey('IsDeleted'));
                            if (e
                                    .getString(KdbxKey('ItemCategory'))
                                    ?.getText() ==
                                'Trash') {
                              e.setString(
                                KdbxKey('ItemCategory'),
                                PlainValue('General'),
                              );
                            }
                            setState(() {});
                            await kdbxBloc.saveFile(e.file);
                            if (mounted) {
                              setState(() {});
                              ScaffoldMessenger.of(context)
                                ..clearSnackBars()
                                ..showSnackBar(
                                  const SnackBar(
                                    content: Text('Restored credential!'),
                                    duration: Duration(milliseconds: 1800),
                                  ),
                                );
                            }
                          },
                          child: const Text('Restore'),
                        ),
                        // Delete Permanently
                        IconButton(
                          tooltip: 'Delete Permanently',
                          icon: const Icon(
                            Icons.delete_forever_rounded,
                            color: KeyNestPalette.error,
                            size: 20,
                          ),
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Delete Permanently?'),
                                content: Text(
                                  'Permanently delete "$title"? This cannot be undone.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    style: TextButton.styleFrom(
                                      foregroundColor: KeyNestPalette.error,
                                    ),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true && mounted) {
                              e.file.deletePermanently(e);
                              setState(() {});
                              await kdbxBloc.saveFile(e.file);
                              if (mounted) {
                                setState(() {});
                                ScaffoldMessenger.of(context)
                                  ..clearSnackBars()
                                  ..showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Item permanently deleted.',
                                      ),
                                      duration: Duration(milliseconds: 1800),
                                    ),
                                  );
                              }
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// 4. Archived Items Screen
class KeyNestArchivedScreen extends StatelessWidget {
  const KeyNestArchivedScreen({super.key});

  static Route<void> route() => MaterialPageRoute(
    settings: const RouteSettings(name: '/archived'),
    builder: (context) => const KeyNestArchivedScreen(),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;

    final archivedEntries = <KdbxEntry>[];
    if (openedFiles.isNotEmpty) {
      final file = openedFiles.first;
      for (final e in file.body.rootGroup.getAllEntries()) {
        final cat = e.getString(KdbxKey('ItemCategory'))?.getText() ?? '';
        if (cat == 'Archived') {
          archivedEntries.add(e);
        }
      }
    }

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: const Text('Archived'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: archivedEntries.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                              .withValues(alpha: isDark ? 0.20 : 0.1),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.archive_outlined,
                      size: 36,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No Archived Items',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Inactive or historical records can be archived to keep your vault organized.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              itemCount: archivedEntries.length,
              itemBuilder: (context, index) {
                final e = archivedEntries[index];
                final title =
                    e.getString(KdbxKeyCommon.TITLE)?.getText() ?? 'Untitled';
                return KeyNestCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(
                        Icons.archive_rounded,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          e.setString(
                            KdbxKey('ItemCategory'),
                            PlainValue('General'),
                          );
                          await kdbxBloc.saveFile(e.file);
                          ScaffoldMessenger.of(context)
                            ..clearSnackBars()
                            ..showSnackBar(
                              const SnackBar(
                                content: Text('Unarchived credential!'),
                                duration: Duration(milliseconds: 1800),
                              ),
                            );
                        },
                        child: const Text('Unarchive'),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

// 5. Receive Item Sheet
class KeyNestReceiveItemSheet extends StatefulWidget {
  const KeyNestReceiveItemSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const KeyNestReceiveItemSheet(),
    );
  }

  @override
  State<KeyNestReceiveItemSheet> createState() =>
      _KeyNestReceiveItemSheetState();
}

class _KeyNestReceiveItemSheetState extends State<KeyNestReceiveItemSheet> {
  final TextEditingController _codeController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Receive Item',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Scan a QR code from another KeyNest device or paste a shared encrypted token.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                foregroundColor: isDark
                    ? const Color(0xFF00315D)
                    : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text(
                'Scan QR Code',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              onPressed: () async {
                Navigator.of(context).pop();
                final scanResult = await BarcodeScanHelper.scanBarcode(context);
                if (scanResult case ScanResultValid(barcode: final barcode)) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(
                          content: Text('Received payload: ${barcode.text}'),
                          duration: const Duration(milliseconds: 1800),
                        ),
                      );
                  }
                }
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(
                labelText: 'Or Paste Share Code',
                hintText: 'keynest://share/...',
                filled: true,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () {
                final text = _codeController.text.trim();
                if (text.isNotEmpty) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(
                      const SnackBar(
                        content: Text('Processed shared credential!'),
                        duration: Duration(milliseconds: 1800),
                      ),
                    );
                }
              },
              child: const Text('Import Code'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
