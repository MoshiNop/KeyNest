import 'package:flutter/material.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

/// Elevated card with proper Material 3 theming, clean outlines,
/// and spring-scaled press feedback.
class KeyNestSurfaceCard extends StatelessWidget {
  const KeyNestSurfaceCard({
    super.key,
    required this.child,
    this.onClick,
    this.onLongPress,
    this.enabled = true,
    this.cornerRadius = KeyNestTokens.radiusCard,
    this.showBorder = true,
    this.borderColor,
    this.backgroundColor,
    this.accentColor,
    this.padding,
    this.margin,
  });

  final Widget child;
  final VoidCallback? onClick;
  final VoidCallback? onLongPress;
  final bool enabled;
  final double cornerRadius;
  final bool showBorder;
  final Color? borderColor;
  final Color? backgroundColor;
  final Color? accentColor;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Default card fill based on theme
    final defaultBg = isDark
        ? (accentColor != null
              ? Color.alphaBlend(
                  accentColor!.withValues(alpha: 0.12),
                  KeyNestTokens.darkSurface,
                )
              : KeyNestTokens.darkSurfaceVariant.withValues(alpha: 0.45))
        : (accentColor != null
              ? Color.alphaBlend(
                  accentColor!.withValues(alpha: 0.08),
                  KeyNestTokens.lightSurface,
                )
              : KeyNestTokens.lightSurface.withValues(alpha: 0.88));

    final bg = backgroundColor ?? defaultBg;

    // Card border following theme tokens
    final effectiveBorderColor =
        borderColor ??
        (accentColor != null
            ? accentColor!.withValues(alpha: KeyNestTokens.tintedBorderAlpha)
            : (isDark
                  ? KeyNestTokens.entryBorderDark
                  : KeyNestTokens.entryBorderLight));

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(cornerRadius),
      side: showBorder
          ? BorderSide(
              color: effectiveBorderColor,
              width: KeyNestTokens.borderWidth,
            )
          : BorderSide.none,
    );

    Widget cardBody = Container(
      decoration: ShapeDecoration(
        color: bg,
        shape: shape,
      ),
      padding: padding ?? const EdgeInsets.all(KeyNestTokens.contentPadding),
      child: child,
    );

    if (onClick != null || onLongPress != null) {
      cardBody = KeyNestPressScale(
        onTap: enabled ? onClick : null,
        onLongPress: enabled ? onLongPress : null,
        enabled: enabled,
        child: cardBody,
      );
    }

    if (margin != null) {
      cardBody = Padding(
        padding: margin!,
        child: cardBody,
      );
    }

    return cardBody;
  }
}

/// Compact list card for items (credentials, records, cards, notes).
class KeyNestCompactCard extends StatelessWidget {
  KeyNestCompactCard({
    super.key,
    Widget? child,
    Widget? leading,
    dynamic title,
    dynamic subtitle,
    Widget? trailing,
    VoidCallback? onTap,
    this.onClick,
    this.onLongPress,
    this.enabled = true,
    this.showBorder = true,
    this.borderColor,
    this.backgroundColor,
    this.margin,
    this.padding = const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
  }) : _effectiveOnClick = onClick ?? onTap,
       child =
           child ??
           Builder(
             builder: (context) {
               final theme = Theme.of(context);
               final isDark = theme.brightness == Brightness.dark;

               Widget? titleWidget;
               if (title is Widget) {
                 titleWidget = title;
               } else if (title is String) {
                 titleWidget = Text(
                   title,
                   style: theme.textTheme.titleMedium?.copyWith(
                     fontWeight: FontWeight.w600,
                     color: isDark
                         ? KeyNestTokens.textPrimaryDark
                         : KeyNestTokens.textPrimaryLight,
                   ),
                 );
               }

               Widget? subtitleWidget;
               if (subtitle is Widget) {
                 subtitleWidget = subtitle;
               } else if (subtitle is String) {
                 subtitleWidget = Text(
                   subtitle,
                   style: theme.textTheme.bodySmall?.copyWith(
                     color: isDark
                         ? KeyNestTokens.textSecondaryDark
                         : KeyNestTokens.textSecondaryLight,
                   ),
                 );
               }

               return Row(
                 children: [
                   if (leading != null) ...[leading, const SizedBox(width: 12)],
                   Expanded(
                     child: Column(
                       crossAxisAlignment: CrossAxisAlignment.start,
                       mainAxisSize: MainAxisSize.min,
                       children: [
                         ?titleWidget,
                         if (subtitleWidget != null) ...[
                           const SizedBox(height: 2),
                           subtitleWidget,
                         ],
                       ],
                     ),
                   ),
                   ?trailing,
                 ],
               );
             },
           );

  final Widget child;
  final VoidCallback? onClick;
  final VoidCallback? _effectiveOnClick;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool showBorder;
  final Color? borderColor;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return KeyNestSurfaceCard(
      cornerRadius: KeyNestTokens.radiusCompact,
      onClick: _effectiveOnClick,
      onLongPress: onLongPress,
      enabled: enabled,
      showBorder: showBorder,
      borderColor: borderColor,
      backgroundColor: backgroundColor,
      padding: padding,
      margin:
          margin ??
          const EdgeInsets.symmetric(
            vertical: KeyNestTokens.compactCardSpacing / 2,
          ),
      child: child,
    );
  }
}

/// Tinted tile leading a compact card with centered glyph or icon.
class KeyNestCompactIconTile extends StatelessWidget {
  KeyNestCompactIconTile({
    super.key,
    Widget? child,
    IconData? icon,
    Color? tint,
    Color? backgroundColor,
    Color? containerColor,
    Color? contentColor,
    this.size = KeyNestTokens.compactCardIconSize,
    this.cornerRadius = KeyNestTokens.radiusCompact,
  }) : child =
           child ??
           (icon != null
               ? Icon(icon, color: tint ?? contentColor)
               : const SizedBox.shrink()),
       containerColor = containerColor ?? backgroundColor,
       contentColor = contentColor ?? tint;

  final Widget child;
  final Color? containerColor;
  final Color? contentColor;
  final double size;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final defaultContainer = isDark
        ? KeyNestTokens.darkSecondaryContainer
        : KeyNestTokens.lightPrimaryContainer;

    final defaultContent = isDark
        ? KeyNestTokens.primaryAccent
        : KeyNestTokens.lightIcon;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: containerColor ?? defaultContainer,
        borderRadius: BorderRadius.circular(cornerRadius),
      ),
      alignment: Alignment.center,
      child: IconTheme(
        data: IconThemeData(
          color: contentColor ?? defaultContent,
          size: KeyNestTokens.compactCardGlyphSize,
        ),
        child: DefaultTextStyle(
          style: theme.textTheme.labelMedium!.copyWith(
            color: contentColor ?? defaultContent,
            fontWeight: FontWeight.bold,
          ),
          child: child,
        ),
      ),
    );
  }
}
