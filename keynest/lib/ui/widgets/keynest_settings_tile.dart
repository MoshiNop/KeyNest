import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:keynest/theme.dart';

class KeyNestSettingsGroup extends StatelessWidget {
  const KeyNestSettingsGroup({
    super.key,
    this.header,
    this.headerIcon,
    this.subHeader,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
  });

  final String? header;
  final dynamic headerIcon;
  final String? subHeader;
  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final cardBg = (isDark ? const Color(0xFF161B26) : Colors.white).withValues(
      alpha: isDark ? 0.90 : 0.96,
    );
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (headerIcon != null) ...[
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: Center(
                        child: headerIcon is IconData
                            ? Icon(
                                headerIcon as IconData,
                                size: 19,
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                              )
                            : headerIcon as Widget,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    header!,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (subHeader != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(
                subHeader!,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
              ),
            ),
          ],
          Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(KeyNestShapes.radiusSection),
              border: Border.all(color: borderColor, width: 1.0),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.03),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(KeyNestShapes.radiusSection),
              child: Column(
                children: _buildDividedChildren(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildDividedChildren(bool isDark) {
    final result = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      result.add(children[i]);
      if (i < children.length - 1) {
        result.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 56,
            endIndent: 16,
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.05),
          ),
        );
      }
    }
    return result;
  }
}

class KeyNestSettingsTile extends StatelessWidget {
  const KeyNestSettingsTile({
    super.key,
    required this.title,
    this.titleWidget,
    this.subtitle,
    required this.icon,
    this.iconColor,
    this.iconBgColor,
    this.trailing,
    this.badge,
    this.onTap,
  });

  final String title;
  final Widget? titleWidget;
  final String? subtitle;
  final dynamic icon;
  final Color? iconColor;
  final Color? iconBgColor;
  final Widget? trailing;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final defaultIconColor = isDark
        ? KeyNestPalette.primaryDark
        : KeyNestPalette.primary;

    final effectiveColor = iconColor ?? defaultIconColor;
    Widget iconWidget;
    if (icon is Widget) {
      iconWidget = icon as Widget;
    } else if (icon is FaIconData) {
      iconWidget = FaIcon(icon as FaIconData, size: 22, color: effectiveColor);
    } else if (icon is IconData) {
      iconWidget = Icon(icon as IconData, size: 22, color: effectiveColor);
    } else {
      iconWidget = const SizedBox();
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              // Clean, borderless mini icon directly aligned
              SizedBox(
                width: 24,
                height: 24,
                child: Center(
                  child: iconWidget,
                ),
              ),
              const SizedBox(width: 16),
              // Title & Subtitle
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (titleWidget != null)
                      titleWidget!
                    else
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontSize: 15.5,
                                color: isDark
                                    ? KeyNestPalette.textPrimaryDark
                                    : KeyNestPalette.textPrimaryLight,
                              ),
                            ),
                          ),
                          if (badge != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: KeyNestPalette.warning,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.lock_rounded,
                                    size: 10,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    badge!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          height: 1.3,
                          color: isDark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Trailing
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ] else if (onTap != null) ...[
                const SizedBox(width: 12),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: isDark
                      ? KeyNestPalette.textTertiaryDark
                      : KeyNestPalette.textTertiaryLight,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
