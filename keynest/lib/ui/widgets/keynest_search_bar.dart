import 'package:flutter/material.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

class KeyNestSearchBar extends StatelessWidget {
  const KeyNestSearchBar({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = 'Search vault...',
    this.onChanged,
    this.onClear,
    this.trailing,
    this.onSortPressed,
    this.onViewModeToggle,
    this.isGridView = false,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 8),
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;
  final Widget? trailing;
  final VoidCallback? onSortPressed;
  final VoidCallback? onViewModeToggle;
  final bool isGridView;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark
        ? KeyNestPalette.surfaceContainerDark
        : KeyNestPalette.surfaceLight;
    final borderColor = isDark
        ? KeyNestPalette.cardBorderDark
        : KeyNestPalette.cardBorderLight;

    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                textAlignVertical: TextAlignVertical.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                  fontSize: 14.5,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: bg,
                  hintText: hintText,
                  hintStyle: TextStyle(
                    color:
                        (isDark
                                ? KeyNestTokens.darkOnSurface
                                : KeyNestTokens.lightOnSurface)
                            .withValues(alpha: 0.38),
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: isDark
                        ? KeyNestPalette.textTertiaryDark
                        : KeyNestPalette.textSecondaryLight,
                    size: 20,
                  ),
                  suffixIcon: controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          splashRadius: 18,
                          onPressed: () {
                            controller.clear();
                            onClear?.call();
                            onChanged?.call('');
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      KeyNestShapes.radiusCard,
                    ),
                    borderSide: BorderSide(color: borderColor, width: 1.0),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      KeyNestShapes.radiusCard,
                    ),
                    borderSide: BorderSide(color: borderColor, width: 1.0),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      KeyNestShapes.radiusCard,
                    ),
                    borderSide: BorderSide(
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (onSortPressed != null) ...[
            const SizedBox(width: 10),
            _ActionSquareButton(
              icon: Icons.sort_rounded,
              tooltip: 'Sort items',
              onPressed: onSortPressed!,
            ),
          ],
          if (onViewModeToggle != null) ...[
            const SizedBox(width: 8),
            _ActionSquareButton(
              icon: isGridView
                  ? Icons.view_list_rounded
                  : Icons.grid_view_rounded,
              tooltip: isGridView ? 'List view' : 'Grid view',
              onPressed: onViewModeToggle!,
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _ActionSquareButton extends StatelessWidget {
  const _ActionSquareButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark
        ? KeyNestPalette.surfaceContainerDark
        : KeyNestPalette.surfaceLight;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 20,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.lightIcon,
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact search button that smoothly expands horizontally into a search
/// input field when clicked, causing adjacent chips to shift fluidly.
class KeyNestExpandableSearchChip extends StatelessWidget {
  const KeyNestExpandableSearchChip({
    super.key,
    required this.controller,
    required this.focusNode,
    this.isExpanded = false,
    this.hintText = 'Search vault...',
    this.onChanged,
    this.onExpand,
    this.onCollapse,
    this.expandedWidth = 220.0,
    this.collapsedWidth = 38.0,
    this.height = 36.0,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isExpanded;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onExpand;
  final VoidCallback? onCollapse;
  final double expandedWidth;
  final double collapsedWidth;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isExpanded
        ? (isDark
              ? KeyNestPalette.surfaceContainerDark
              : KeyNestPalette.surfaceLight)
        : (isDark ? const Color(0xFF222938) : const Color(0xFFEDEBF2));

    final borderColor = isExpanded
        ? (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
        : (isDark
              ? KeyNestPalette.cardBorderDark
              : KeyNestPalette.cardBorderLight);

    final iconColor = isExpanded
        ? (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
        : (isDark
              ? KeyNestPalette.textSecondaryDark
              : KeyNestPalette.lightIcon);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.fastOutSlowIn,
      width: isExpanded ? expandedWidth : collapsedWidth,
      height: height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusChip),
        border: isExpanded
            ? Border.all(
                color: borderColor,
                width: 1.4,
              )
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusChip),
        child: Material(
          color: Colors.transparent,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeIn,
            switchOutCurve: Curves.easeOut,
            child: isExpanded
                ? SizedBox(
                    key: const ValueKey('search_expanded'),
                    width: expandedWidth,
                    height: height,
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: iconColor,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextField(
                            controller: controller,
                            focusNode: focusNode,
                            onChanged: onChanged,
                            textAlignVertical: TextAlignVertical.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: isDark
                                  ? KeyNestPalette.textPrimaryDark
                                  : KeyNestPalette.textPrimaryLight,
                              fontSize: 13.5,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                              hintText: hintText,
                              hintStyle: TextStyle(
                                color:
                                    (isDark
                                            ? KeyNestTokens.darkOnSurface
                                            : KeyNestTokens.lightOnSurface)
                                        .withValues(alpha: 0.38),
                                fontSize: 13.5,
                                fontWeight: FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(
                            KeyNestShapes.radiusChip,
                          ),
                          onTap: () {
                            if (controller.text.isNotEmpty) {
                              controller.clear();
                              onChanged?.call('');
                            }
                            onCollapse?.call();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Tooltip(
                    key: const ValueKey('search_collapsed'),
                    message: 'Search',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(
                        KeyNestShapes.radiusChip,
                      ),
                      onTap: onExpand,
                      child: Center(
                        child: Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: iconColor,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
