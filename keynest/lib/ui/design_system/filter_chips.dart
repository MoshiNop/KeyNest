import 'package:flutter/material.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

/// Filter chip for selection and filtering sheets.
class KeyNestFilterChip extends StatelessWidget {
  const KeyNestFilterChip({
    super.key,
    required this.selected,
    required this.onClick,
    required this.label,
    this.selectedIcon = Icons.done_rounded,
    this.leadingIcon,
  });

  final bool selected;
  final VoidCallback onClick;
  final String label;
  final IconData selectedIcon;
  final Widget? leadingIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final containerColor = selected
        ? (isDark
              ? const Color(0xFF434657)
              : KeyNestTokens.lightPrimaryContainer)
        : (isDark ? const Color(0xFF222938) : const Color(0xFFEDEBF2));

    final contentColor = selected
        ? (isDark
              ? KeyNestTokens.primaryAccent
              : KeyNestTokens.lightOnPrimaryContainer)
        : (isDark
              ? KeyNestTokens.darkOnSurfaceVariant
              : KeyNestTokens.lightOnSurfaceVariant);

    return KeyNestPressScale(
      onTap: onClick,
      child: AnimatedContainer(
        duration: KeyNestTokens.durationShort,
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 7.0),
        decoration: BoxDecoration(
          color: containerColor,
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusCompact),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(selectedIcon, size: 16.0, color: contentColor),
              const SizedBox(width: 6.0),
            ] else if (leadingIcon != null) ...[
              IconTheme(
                data: IconThemeData(size: 16.0, color: contentColor),
                child: leadingIcon!,
              ),
              const SizedBox(width: 6.0),
            ],
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: contentColor,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Removable input chip for active filter criteria and tags.
class KeyNestInputChip extends StatelessWidget {
  const KeyNestInputChip({
    super.key,
    required this.label,
    required this.onRemove,
  });

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final containerColor = isDark
        ? KeyNestTokens.darkSurfaceVariant.withValues(alpha: 0.35)
        : KeyNestTokens.lightSurface;

    final contentColor = isDark
        ? KeyNestTokens.darkOnSurface
        : KeyNestTokens.lightOnSurface;

    return Container(
      padding: const EdgeInsets.only(
        left: 10.0,
        right: 4.0,
        top: 4.0,
        bottom: 4.0,
      ),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(KeyNestTokens.radiusCompact),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: contentColor,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4.0),
          GestureDetector(
            onTap: onRemove,
            child: Padding(
              padding: const EdgeInsets.all(2.0),
              child: Icon(
                Icons.close_rounded,
                size: 16.0,
                color: isDark
                    ? KeyNestTokens.darkOnSurfaceVariant
                    : KeyNestTokens.lightOnSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline status marker badge with semantic coloring.
class KeyNestStatusBadge extends StatelessWidget {
  const KeyNestStatusBadge({
    super.key,
    String? text,
    String? label,
    this.icon,
    this.tone = KeyNestSemanticTone.neutral,
    this.onClick,
    this.containerColor,
    this.contentColor,
    this.padding,
    this.textStyle,
  }) : text = text ?? label;

  const KeyNestStatusBadge.compact({
    super.key,
    String? text,
    String? label,
    this.icon,
    this.tone = KeyNestSemanticTone.neutral,
    this.onClick,
    this.containerColor,
    this.contentColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 6.0, vertical: 2.0),
    this.textStyle = const TextStyle(
      fontSize: 9.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    ),
  }) : text = text ?? label;

  final String? text;
  final IconData? icon;
  final KeyNestSemanticTone tone;
  final VoidCallback? onClick;
  final Color? containerColor;
  final Color? contentColor;
  final EdgeInsetsGeometry? padding;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = containerColor ?? tone.container(context);
    final fg = contentColor ?? tone.content(context);

    final resolvedPadding =
        padding ?? const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0);
    final resolvedTextStyle =
        (textStyle ?? theme.textTheme.labelMedium)?.copyWith(
          color: fg,
          fontWeight: textStyle?.fontWeight ?? FontWeight.w600,
        );

    Widget badge = AnimatedContainer(
      duration: KeyNestTokens.durationShort,
      padding: resolvedPadding,
      decoration: ShapeDecoration(
        color: bg,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: (resolvedTextStyle?.fontSize != null)
                  ? (resolvedTextStyle!.fontSize! + 3.0)
                  : 14.0,
              color: fg,
            ),
            if (text != null) const SizedBox(width: 4.0),
          ],
          if (text != null)
            Text(
              text!,
              style: resolvedTextStyle,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );

    if (onClick != null) {
      badge = KeyNestPressScale(
        onTap: onClick,
        child: badge,
      );
    }

    return badge;
  }
}

/// Badges on a line of their own, wrapping when out of room.
class KeyNestStatusBadgeRow extends StatelessWidget {
  const KeyNestStatusBadgeRow({
    super.key,
    required this.children,
    this.spacing = 5.0,
    this.runSpacing = 5.0,
  });

  final List<Widget> children;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}
