import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/add_record_catalog.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:provider/provider.dart';

/// Representation of a category in KeyNest.
class KeyNestCategoryItem {
  const KeyNestCategoryItem({
    required this.name,
    required this.icon,
    this.color,
    this.isDefault = false,
    this.isCustom = false,
  });

  factory KeyNestCategoryItem.fromJson(Map<String, dynamic> json) {
    return KeyNestCategoryItem(
      name: json['name'] as String? ?? 'Custom',
      icon: KeyNestCategories.getIconFromCode(json['iconCode'] as int?),
      color: json['color'] != null ? Color(json['color'] as int) : null,
      isDefault: json['isDefault'] as bool? ?? false,
      isCustom: json['isCustom'] as bool? ?? true,
    );
  }

  final String name;
  final IconData icon;
  final Color? color;
  final bool isDefault;
  final bool isCustom;

  Map<String, dynamic> toJson() => {
    'name': name,
    'iconCode': icon.codePoint,
    'iconFontFamily': icon.fontFamily,
    'iconFontPackage': icon.fontPackage,
    'color': color?.toARGB32(),
    'isDefault': isDefault,
    'isCustom': isCustom,
  };

  KeyNestCategoryItem copyWith({
    String? name,
    IconData? icon,
    Color? color,
    bool? isDefault,
    bool? isCustom,
  }) {
    return KeyNestCategoryItem(
      name: name ?? this.name,
      icon: icon ?? this.icon,
      color: color ?? this.color,
      isDefault: isDefault ?? this.isDefault,
      isCustom: isCustom ?? this.isCustom,
    );
  }
}

/// Central catalog of categories, icons, and colors.
class KeyNestCategories {
  static const List<KeyNestCategoryItem> defaultCategories = [
    KeyNestCategoryItem(
      name: 'General',
      icon: Icons.vpn_key_rounded,
      color: Color(0xFF6C5CE7),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Social Media',
      icon: Icons.people_outline_rounded,
      color: Color(0xFF0984E3),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Email',
      icon: Icons.mail_outline_rounded,
      color: Color(0xFF00CEC9),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Banking',
      icon: Icons.account_balance_outlined,
      color: Color(0xFF00B894),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Mobile Banking',
      icon: Icons.smartphone_rounded,
      color: Color(0xFF20BF6B),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Shopping',
      icon: Icons.shopping_bag_outlined,
      color: Color(0xFFE17055),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Entertainment',
      icon: Icons.movie_outlined,
      color: Color(0xFFFD79A8),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Work',
      icon: Icons.work_outline_rounded,
      color: Color(0xFF636E72),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Gaming',
      icon: Icons.sports_esports_outlined,
      color: Color(0xFFE84393),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Crypto',
      icon: Icons.currency_bitcoin_rounded,
      color: Color(0xFFF39C12),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Personal',
      icon: Icons.favorite_border_rounded,
      color: Color(0xFFE056FD),
      isDefault: true,
    ),
    KeyNestCategoryItem(
      name: 'Other',
      icon: Icons.category_outlined,
      color: Color(0xFF7F8C8D),
      isDefault: true,
    ),
  ];

  static List<KeyNestCategoryItem> get allCategories => defaultCategories;

  static const List<Color> availableColors = [
    Color(0xFF6C5CE7), // KeyNest Violet
    Color(0xFF4834D4), // Deep Purple
    Color(0xFF0984E3), // Electric Blue
    Color(0xFF00CEC9), // Cyan
    Color(0xFF00B894), // Mint Green
    Color(0xFF20BF6B), // Emerald
    Color(0xFFF39C12), // Amber
    Color(0xFFE17055), // Coral
    Color(0xFFD63031), // Crimson Red
    Color(0xFFFD79A8), // Pastel Pink
    Color(0xFFE84393), // Fuchsia
    Color(0xFF636E72), // Slate Grey
  ];

  static const List<IconData> availableIcons = [
    Icons.vpn_key_rounded,
    Icons.lock_rounded,
    Icons.shield_rounded,
    Icons.person_rounded,
    Icons.people_outline_rounded,
    Icons.mail_outline_rounded,
    Icons.account_balance_outlined,
    Icons.credit_card_rounded,
    Icons.account_balance_wallet_outlined,
    Icons.smartphone_rounded,
    Icons.shopping_bag_outlined,
    Icons.shopping_cart_outlined,
    Icons.movie_outlined,
    Icons.music_note_rounded,
    Icons.sports_esports_outlined,
    Icons.work_outline_rounded,
    Icons.business_center_outlined,
    Icons.code_rounded,
    Icons.terminal_rounded,
    Icons.dns_rounded,
    Icons.cloud_outlined,
    Icons.folder_rounded,
    Icons.description_outlined,
    Icons.bookmark_border_rounded,
    Icons.star_border_rounded,
    Icons.favorite_border_rounded,
    Icons.home_outlined,
    Icons.directions_car_outlined,
    Icons.flight_takeoff_rounded,
    Icons.local_cafe_outlined,
    Icons.medical_services_outlined,
    Icons.school_outlined,
    Icons.currency_bitcoin_rounded,
    Icons.wifi_rounded,
    Icons.label_outline_rounded,
    Icons.category_outlined,
  ];

  static IconData getIconFromCode(int? codePoint) {
    if (codePoint == null) {
      return Icons.folder_rounded;
    }
    for (final icon in availableIcons) {
      if (icon.codePoint == codePoint) {
        return icon;
      }
    }
    return Icons.folder_rounded;
  }

  static Future<String?> showCategoryBottomSheet({
    required BuildContext context,
    String? selectedCategory,
    bool showAllOption = true,
  }) {
    if (KeyNestPlatform.isDesktopOrWeb) {
      return showAnchoredPopover<String>(
        anchorContext: context,
        width: 340,
        maxHeight: 480,
        builder: (ctx) => _CategoryBottomSheet(
          selectedCategory: selectedCategory,
          showAllOption: showAllOption,
          isDialog: true,
        ),
      );
    }
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CategoryBottomSheet(
        selectedCategory: selectedCategory,
        showAllOption: showAllOption,
      ),
    );
  }

  static Future<KeyNestCategoryItem?> showCategoryEditorDialog(
    BuildContext context, {
    KeyNestCategoryItem? existing,
  }) {
    return showDialog<KeyNestCategoryItem>(
      context: context,
      builder: (ctx) => _CategoryEditorDialog(existing: existing),
    );
  }
}

/// Service that persists and manages custom categories within the active KDBX vault.
class KeyNestCategoryService {
  static const String customDataKey = 'keynest.custom_categories';

  /// Returns all available categories for the given KdbxFile,
  /// including default categories, custom categories stored in file metadata,
  /// and any discovered categories present on vault entries.
  static List<KeyNestCategoryItem> getAllCategories(KdbxFile? file) {
    final Map<String, KeyNestCategoryItem> map = {};

    for (final def in KeyNestCategories.defaultCategories) {
      map[def.name.toLowerCase()] = def;
    }

    if (file != null) {
      final jsonStr = file.body.meta.customData[customDataKey];
      if (jsonStr != null && jsonStr.isNotEmpty) {
        try {
          final list = jsonDecode(jsonStr) as List<dynamic>;
          for (final item in list) {
            final cat = KeyNestCategoryItem.fromJson(
              item as Map<String, dynamic>,
            );
            map[cat.name.toLowerCase()] = cat;
          }
        } catch (_) {}
      }

      // Discover any categories already assigned to entries
      for (final entry in file.body.rootGroup.getAllEntries()) {
        final catName = KeyNestItemTypeHelper.getCategory(entry);
        if (catName != 'General' && !map.containsKey(catName.toLowerCase())) {
          final recordItem = RecordTypeHelper.findType(catName);
          map[catName.toLowerCase()] = KeyNestCategoryItem(
            name: catName,
            icon: recordItem?.icon ?? Icons.label_outline_rounded,
            color: const Color(0xFF6C5CE7),
            isCustom: true,
          );
        }
      }
    }

    return map.values.toList();
  }

  static List<KeyNestCategoryItem> getCustomCategories(KdbxFile file) {
    final jsonStr = file.body.meta.customData[customDataKey];
    if (jsonStr == null || jsonStr.isEmpty) {
      return [];
    }
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map(
            (item) =>
                KeyNestCategoryItem.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Map<String, int> getCategoryCounts(KdbxFile? file) {
    final counts = <String, int>{};
    if (file == null) {
      return counts;
    }

    for (final entry in file.body.rootGroup.getAllEntries()) {
      if (entry.parent?.isInRecycleBin() == true ||
          entry.parent == file.recycleBin) {
        continue;
      }
      final cat = KeyNestItemTypeHelper.getCategory(entry);
      counts[cat] = (counts[cat] ?? 0) + 1;
    }
    return counts;
  }

  static List<KdbxEntry> getEntriesForCategory(
    KdbxFile? file,
    String categoryName,
  ) {
    if (file == null) {
      return [];
    }
    return file.body.rootGroup.getAllEntries().where((entry) {
      if (entry.parent?.isInRecycleBin() == true ||
          entry.parent == file.recycleBin) {
        return false;
      }
      final cat = KeyNestItemTypeHelper.getCategory(entry);
      if (categoryName.toLowerCase() == 'general') {
        return cat.toLowerCase() == 'general';
      }
      return cat.toLowerCase() == categoryName.toLowerCase();
    }).toList();
  }

  static Future<void> saveCustomCategories(
    KdbxFile file,
    KdbxBloc kdbxBloc,
    List<KeyNestCategoryItem> customCategories,
  ) async {
    final jsonList = customCategories.map((c) => c.toJson()).toList();
    file.body.meta.customData[customDataKey] = jsonEncode(jsonList);
    await kdbxBloc.saveFile(file);
  }

  static Future<void> addCategory({
    required KdbxFile file,
    required KdbxBloc kdbxBloc,
    required KeyNestCategoryItem category,
  }) async {
    final list = getCustomCategories(file);
    list.removeWhere(
      (c) => c.name.toLowerCase() == category.name.toLowerCase(),
    );
    list.add(category);
    await saveCustomCategories(file, kdbxBloc, list);
  }

  static Future<void> updateCategory({
    required KdbxFile file,
    required KdbxBloc kdbxBloc,
    required String oldName,
    required KeyNestCategoryItem updated,
  }) async {
    final list = getCustomCategories(file);
    final idx = list.indexWhere(
      (c) => c.name.toLowerCase() == oldName.toLowerCase(),
    );
    if (idx != -1) {
      list[idx] = updated;
    } else {
      list.add(updated);
    }

    if (oldName.toLowerCase() != updated.name.toLowerCase()) {
      for (final entry in file.body.rootGroup.getAllEntries()) {
        final cat = KeyNestItemTypeHelper.getCategory(entry);
        if (cat.toLowerCase() == oldName.toLowerCase()) {
          KeyNestItemTypeHelper.setCategory(entry, updated.name);
        }
      }
    }

    await saveCustomCategories(file, kdbxBloc, list);
  }

  static Future<void> deleteCategory({
    required KdbxFile file,
    required KdbxBloc kdbxBloc,
    required String categoryName,
    String? reassignTo = 'General',
  }) async {
    final list = getCustomCategories(file);
    list.removeWhere((c) => c.name.toLowerCase() == categoryName.toLowerCase());

    for (final entry in file.body.rootGroup.getAllEntries()) {
      final cat = KeyNestItemTypeHelper.getCategory(entry);
      if (cat.toLowerCase() == categoryName.toLowerCase()) {
        if (reassignTo != null && reassignTo.isNotEmpty) {
          KeyNestItemTypeHelper.setCategory(entry, reassignTo);
        } else {
          entry.removeString(KdbxKey('ItemCategory'));
        }
      }
    }

    await saveCustomCategories(file, kdbxBloc, list);
  }
}

/// Interactive modal bottom sheet or dialog for picking a category.
class _CategoryBottomSheet extends StatefulWidget {
  const _CategoryBottomSheet({
    required this.selectedCategory,
    required this.showAllOption,
    this.isDialog = false,
  });

  final String? selectedCategory;
  final bool showAllOption;
  final bool isDialog;

  @override
  State<_CategoryBottomSheet> createState() => _CategoryBottomSheetState();
}

class _CategoryBottomSheetState extends State<_CategoryBottomSheet> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    final currentFile = openedFiles.firstOrNull;

    final categories = KeyNestCategoryService.getAllCategories(currentFile);
    final bg = isDark
        ? KeyNestPalette.surfaceDark
        : KeyNestPalette.surfaceLight;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: widget.isDialog
            ? BorderRadius.circular(16)
            : const BorderRadius.vertical(
                top: Radius.circular(KeyNestShapes.radiusSheet),
              ),
      ),
      padding: EdgeInsets.symmetric(vertical: widget.isDialog ? 12 : 20),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.isDialog) ...[
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark
                        ? KeyNestPalette.cardBorderDark
                        : KeyNestPalette.dividerLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
            ],
            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Filter by Category',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isDark
                            ? KeyNestPalette.textPrimaryDark
                            : KeyNestPalette.textPrimaryLight,
                      ),
                    ),
                  ),
                  if (widget.isDialog)
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      splashRadius: 18,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Add Category button
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: Icon(
                Icons.add_circle_outline_rounded,
                color: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                size: 24,
              ),
              title: Text(
                'New Category',
                style: TextStyle(
                  color: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              onTap: () async {
                final navigator = Navigator.of(context);
                final newCat = await KeyNestCategories.showCategoryEditorDialog(
                  context,
                );
                if (newCat != null && newCat.name.isNotEmpty) {
                  if (currentFile != null) {
                    await KeyNestCategoryService.addCategory(
                      file: currentFile,
                      kdbxBloc: kdbxBloc,
                      category: newCat,
                    );
                  }
                  navigator.pop(newCat.name);
                }
              },
            ),
            Divider(
              height: 1,
              color: isDark
                  ? KeyNestPalette.cardBorderDark
                  : KeyNestPalette.dividerLight,
            ),
            // List of categories
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  if (widget.showAllOption)
                    _CategoryRadioTile(
                      name: 'All',
                      icon: Icons.all_inclusive_rounded,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      isSelected:
                          widget.selectedCategory == null ||
                          widget.selectedCategory == 'All',
                      onTap: () => Navigator.pop(context, 'All'),
                    ),
                  ...categories.map(
                    (cat) => _CategoryRadioTile(
                      name: cat.name,
                      icon: cat.icon,
                      color:
                          cat.color ??
                          (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary),
                      isSelected: widget.selectedCategory == cat.name,
                      onTap: () => Navigator.pop(context, cat.name),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRadioTile extends StatelessWidget {
  const _CategoryRadioTile({
    required this.name,
    required this.icon,
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  final String name;
  final IconData icon;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final textColor = isSelected
        ? (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
        : (isDark
              ? KeyNestPalette.textPrimaryDark
              : KeyNestPalette.textPrimaryLight);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
      onTap: onTap,
      leading: Icon(
        isSelected
            ? Icons.check_circle_rounded
            : Icons.radio_button_unchecked_rounded,
        color: isSelected
            ? (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
            : (isDark
                  ? KeyNestPalette.textTertiaryDark
                  : KeyNestPalette.textTertiaryLight),
        size: 22,
      ),
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 14),
          Text(
            name,
            style: TextStyle(
              fontSize: 16,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog for creating or editing a category.
class _CategoryEditorDialog extends StatefulWidget {
  const _CategoryEditorDialog({this.existing});

  final KeyNestCategoryItem? existing;

  @override
  State<_CategoryEditorDialog> createState() => _CategoryEditorDialogState();
}

class _CategoryEditorDialogState extends State<_CategoryEditorDialog> {
  late final TextEditingController _nameController;
  late Color _selectedColor;
  late IconData _selectedIcon;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _selectedColor =
        widget.existing?.color ?? KeyNestCategories.availableColors.first;
    _selectedIcon = widget.existing?.icon ?? Icons.folder_rounded;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isEditing = widget.existing != null;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: isDark ? KeyNestPalette.surfaceDark : Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: KeyNestPlatform.isDesktopOrWeb ? 460 : double.infinity,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title
              Row(
                children: [
                  Icon(
                    isEditing
                        ? Icons.edit_rounded
                        : Icons.add_circle_outline_rounded,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isEditing ? 'Edit Category' : 'New Custom Category',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Live Preview Pill
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? KeyNestPalette.bgDark
                      : KeyNestPalette.bgLight,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark
                        ? KeyNestPalette.cardBorderDark
                        : KeyNestPalette.dividerLight,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _selectedColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        _selectedIcon,
                        color: _selectedColor,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _nameController,
                            builder: (context, value, _) {
                              final text = value.text.trim();
                              return Text(
                                text.isEmpty ? 'Category Name' : text,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: text.isEmpty ? Colors.grey : null,
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isEditing ? 'Editing Category' : 'Live Preview',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Name input
              TextField(
                controller: _nameController,
                autofocus: !isEditing,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Category Name',
                  hintText: 'e.g., Gaming, Crypto, Taxes',
                  prefixIcon: const Icon(Icons.label_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Color Selection
              const Text(
                'Category Color',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: KeyNestCategories.availableColors.map((color) {
                  final isSelected =
                      _selectedColor.toARGB32() == color.toARGB32();
                  return GestureDetector(
                    onTap: () => setState(() => _selectedColor = color),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.white : Colors.transparent,
                          width: 2.5,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: color.withValues(alpha: 0.5),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      child: isSelected
                          ? const Icon(
                              Icons.check,
                              size: 20,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),

              // Icon Selection
              const Text(
                'Category Icon',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 160,
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 6,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: KeyNestCategories.availableIcons.length,
                  itemBuilder: (context, index) {
                    final icon = KeyNestCategories.availableIcons[index];
                    final isSelected =
                        _selectedIcon.codePoint == icon.codePoint;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedIcon = icon),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? _selectedColor.withValues(alpha: 0.2)
                              : (isDark
                                    ? KeyNestPalette.surfaceDark
                                    : KeyNestPalette.surfaceLight),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected
                                ? _selectedColor
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          icon,
                          size: 22,
                          color: isSelected
                              ? _selectedColor
                              : (isDark ? Colors.white70 : Colors.black87),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),

              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      foregroundColor: isDark
                          ? const Color(0xFF00315D)
                          : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                    onPressed: () {
                      final name = _nameController.text.trim();
                      if (name.isEmpty) {
                        return;
                      }
                      Navigator.of(context).pop(
                        KeyNestCategoryItem(
                          name: name,
                          icon: _selectedIcon,
                          color: _selectedColor,
                          isCustom: true,
                        ),
                      );
                    },
                    child: Text(isEditing ? 'Save Changes' : 'Create Category'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
}

class KeyNestCategoryPicker {
  static Future<String?> show(
    BuildContext context, {
    String? selectedCategory,
    bool showAllOption = true,
  }) {
    return KeyNestCategories.showCategoryBottomSheet(
      context: context,
      selectedCategory: selectedCategory,
      showAllOption: showAllOption,
    );
  }
}
