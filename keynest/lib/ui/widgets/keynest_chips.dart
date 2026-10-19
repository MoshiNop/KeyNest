import 'package:flutter/material.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

/// Clean styled chip component for KeyNest filters and selectors.
class KeyNestChip extends StatelessWidget {
  const KeyNestChip({
    super.key,
    required this.label,
    this.icon,
    this.isSelected = false,
    this.onTap,
    this.trailingIcon,
  });

  final String label;
  final dynamic icon;
  final dynamic trailingIcon;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isSelected
        ? (isDark
              ? const Color(0xFF434657)
              : KeyNestTokens.lightPrimaryContainer)
        : (isDark ? const Color(0xFF222938) : const Color(0xFFEDEBF2));

    final textColor = isSelected
        ? (isDark
              ? KeyNestTokens.primaryAccent
              : KeyNestTokens.lightOnPrimaryContainer)
        : (isDark
              ? KeyNestTokens.darkOnSurfaceVariant
              : KeyNestTokens.lightOnSurfaceVariant);

    Widget? iconWidget;
    if (icon != null) {
      if (icon is IconData) {
        iconWidget = Icon(icon as IconData, size: 16, color: textColor);
      } else if (icon is Widget) {
        iconWidget = icon as Widget;
      }
    }

    Widget? trailingWidget;
    if (trailingIcon != null) {
      if (trailingIcon is IconData) {
        trailingWidget = Icon(
          trailingIcon as IconData,
          size: 16,
          color: textColor,
        );
      } else if (trailingIcon is Widget) {
        trailingWidget = trailingIcon as Widget;
      }
    }

    return KeyNestPressScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: KeyNestTokens.durationShort,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusChip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (iconWidget != null) ...[
              iconWidget,
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: textColor,
              ),
            ),
            if (trailingWidget != null) ...[
              const SizedBox(width: 6),
              trailingWidget,
            ],
          ],
        ),
      ),
    );
  }
}
