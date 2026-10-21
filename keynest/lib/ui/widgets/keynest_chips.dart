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
    this.showCheckmark = true,
    this.onTap,
    this.trailingIcon,
  });

  final String label;
  final dynamic icon;
  final dynamic trailingIcon;
  final bool isSelected;
  final bool showCheckmark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isSelected
        ? (isDark
              ? const Color(0xFF1E2D4A)
              : const Color(0xFFE0F2FE))
        : (isDark ? const Color(0xFF1B1E28) : const Color(0xFFF1F3F5));

    final textColor = isSelected
        ? (isDark
              ? const Color(0xFF93C5FD)
              : const Color(0xFF0284C7))
        : (isDark
              ? Colors.white70
              : Colors.black87);

    final border = isSelected
        ? Border.all(
            color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF0284C7),
            width: 1.4,
          )
        : Border.all(
            color: isDark ? const Color(0xFF2C3242) : const Color(0xFFE2E4E8),
            width: 1.0,
          );

    Widget? iconWidget;
    if (icon != null) {
      if (icon is IconData) {
        iconWidget = Icon(icon as IconData, size: 15, color: textColor);
      } else if (icon is Widget) {
        iconWidget = icon as Widget;
      }
    }

    Widget? trailingWidget;
    if (trailingIcon != null) {
      if (trailingIcon is IconData) {
        trailingWidget = Icon(
          trailingIcon as IconData,
          size: 15,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          border: border,
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusChip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected && showCheckmark) ...[
              Icon(
                Icons.check_rounded,
                size: 14,
                color: textColor,
              ),
              const SizedBox(width: 5),
            ],
            if (iconWidget != null && (!isSelected || !showCheckmark || icon == Icons.keyboard_arrow_down_rounded)) ...[
              iconWidget,
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: textColor,
                fontSize: 12.5,
              ),
            ),
            if (trailingWidget != null) ...[
              const SizedBox(width: 5),
              trailingWidget,
            ],
          ],
        ),
      ),
    );
  }
}
