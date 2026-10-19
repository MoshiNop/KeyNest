import 'package:flutter/material.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

/// Clean styled Card container for KeyNest, featuring 16dp radii,
/// subtle 1dp border, and spring press-scale feedback.
class KeyNestCard extends StatelessWidget {
  const KeyNestCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(KeyNestTokens.contentPadding),
    this.margin,
    this.borderRadius,
    this.border,
    this.backgroundColor,
    this.onTap,
    this.onLongPress,
    this.accentColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius? borderRadius;
  final BoxBorder? border;
  final Color? backgroundColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final r = borderRadius ?? BorderRadius.circular(KeyNestShapes.radiusCard);

    final bg =
        backgroundColor ??
        (isDark
            ? (accentColor != null
                  ? Color.alphaBlend(
                      accentColor!.withValues(alpha: 0.12),
                      KeyNestTokens.darkSurface,
                    )
                  : KeyNestTokens.darkSurface)
            : (accentColor != null
                  ? Color.alphaBlend(
                      accentColor!.withValues(alpha: 0.08),
                      KeyNestTokens.lightSurface,
                    )
                  : KeyNestTokens.lightSurface));

    final effectiveBorderColor = accentColor != null
        ? accentColor!.withValues(alpha: KeyNestTokens.tintedBorderAlpha)
        : (isDark
              ? KeyNestPalette.entryBorderDark
              : KeyNestPalette.entryBorderLight);

    Widget content = Container(
      margin: margin,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: r,
        border:
            border ??
            Border.all(
              color: effectiveBorderColor,
              width: KeyNestTokens.borderWidth,
            ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.04),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: r,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    if (onTap != null || onLongPress != null) {
      content = KeyNestPressScale(
        onTap: onTap,
        onLongPress: onLongPress,
        child: content,
      );
    }

    return content;
  }
}
