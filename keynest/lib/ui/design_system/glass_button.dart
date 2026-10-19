import 'package:flutter/material.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

enum KeyNestBottomActionTone { neutral, accent, highlight, destructive }

/// Frosted translucent button pairing an optional [icon] with a [label].
class KeyNestGlassButton extends StatelessWidget {
  KeyNestGlassButton({
    super.key,
    String? label,
    String? text,
    VoidCallback? onClick,
    dynamic icon,
    this.selected = false,
    bool? enabled,
    this.showProgress = false,
    this.showLabel = true,
    dynamic tone = KeyNestBottomActionTone.neutral,
    this.height = KeyNestTokens.glassButtonHeight,
    this.cornerRadius = KeyNestTokens.radiusCard,
    this.pressScale = true,
    this.tooltip,
    this.fullWidth = false,
  }) : label = label ?? text ?? '',
       onClick = onClick ?? _noop,
       enabled = enabled ?? (onClick != null),
       icon = icon is IconData ? Icon(icon) : icon as Widget?,
       tone = _resolveTone(tone);

  static void _noop() {}

  static KeyNestBottomActionTone _resolveTone(dynamic t) {
    if (t is KeyNestBottomActionTone) {
      return t;
    }
    if (t is KeyNestSemanticTone) {
      switch (t) {
        case KeyNestSemanticTone.primary:
          return KeyNestBottomActionTone.accent;
        case KeyNestSemanticTone.error:
          return KeyNestBottomActionTone.destructive;
        case KeyNestSemanticTone.warning:
        case KeyNestSemanticTone.success:
          return KeyNestBottomActionTone.highlight;
        case KeyNestSemanticTone.neutral:
          return KeyNestBottomActionTone.neutral;
      }
    }
    return KeyNestBottomActionTone.neutral;
  }

  final String label;
  final VoidCallback onClick;
  final Widget? icon;
  final bool selected;
  final bool enabled;
  final bool showProgress;
  final bool showLabel;
  final KeyNestBottomActionTone tone;
  final double height;
  final double cornerRadius;
  final bool pressScale;
  final String? tooltip;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Resolve glass colors matching design tokens
    Color containerColor;
    Color contentColor;
    Color borderColor;

    switch (tone) {
      case KeyNestBottomActionTone.accent:
        containerColor = isDark
            ? KeyNestTokens.darkPrimaryContainer.withValues(
                alpha: selected ? 0.65 : 0.45,
              )
            : KeyNestTokens.lightPrimaryContainer.withValues(
                alpha: selected ? 0.8 : 0.6,
              );
        contentColor = isDark
            ? KeyNestTokens.darkOnPrimaryContainer
            : KeyNestTokens.lightOnPrimaryContainer;
        borderColor = isDark
            ? KeyNestTokens.darkPrimary.withValues(alpha: selected ? 0.6 : 0.4)
            : KeyNestTokens.lightPrimary.withValues(
                alpha: selected ? 0.6 : 0.4,
              );
        break;

      case KeyNestBottomActionTone.highlight:
        containerColor = isDark
            ? KeyNestTokens.darkTertiaryContainer.withValues(
                alpha: selected ? 0.65 : 0.45,
              )
            : KeyNestTokens.lightTertiaryContainer.withValues(
                alpha: selected ? 0.8 : 0.6,
              );
        contentColor = isDark
            ? KeyNestTokens.darkOnTertiaryContainer
            : KeyNestTokens.lightOnTertiaryContainer;
        borderColor = isDark
            ? KeyNestTokens.darkTertiary.withValues(alpha: selected ? 0.6 : 0.4)
            : KeyNestTokens.lightTertiary.withValues(
                alpha: selected ? 0.6 : 0.4,
              );
        break;

      case KeyNestBottomActionTone.destructive:
        containerColor = isDark
            ? KeyNestTokens.darkErrorContainer.withValues(
                alpha: selected ? 0.5 : 0.35,
              )
            : KeyNestTokens.lightErrorContainer.withValues(
                alpha: selected ? 0.6 : 0.4,
              );
        contentColor = isDark
            ? KeyNestTokens.darkError
            : KeyNestTokens.lightError;
        borderColor = isDark
            ? KeyNestTokens.darkError.withValues(alpha: 0.5)
            : KeyNestTokens.lightError.withValues(alpha: 0.5);
        break;

      case KeyNestBottomActionTone.neutral:
        if (selected) {
          containerColor = isDark
              ? KeyNestTokens.darkPrimaryContainer.withValues(alpha: 0.55)
              : KeyNestTokens.lightPrimaryContainer.withValues(alpha: 0.72);
          contentColor = isDark
              ? KeyNestTokens.darkOnPrimaryContainer
              : KeyNestTokens.lightOnPrimaryContainer;
          borderColor = isDark
              ? KeyNestTokens.darkPrimary.withValues(alpha: 0.55)
              : KeyNestTokens.lightPrimary.withValues(alpha: 0.45);
        } else {
          containerColor = isDark
              ? KeyNestTokens.darkSurfaceVariant.withValues(alpha: 0.35)
              : KeyNestTokens.lightSurfaceVariant.withValues(alpha: 0.6);
          contentColor = isDark
              ? KeyNestTokens.darkOnSurfaceVariant
              : KeyNestTokens.lightOnSurfaceVariant;
          borderColor = isDark
              ? KeyNestTokens.darkOutline.withValues(alpha: 0.4)
              : KeyNestTokens.lightOutline.withValues(alpha: 0.6);
        }
        break;
    }

    if (!enabled) {
      containerColor = containerColor.withValues(alpha: containerColor.a * 0.5);
      contentColor = contentColor.withValues(alpha: contentColor.a * 0.5);
      borderColor = borderColor.withValues(alpha: borderColor.a * 0.5);
    }

    Widget innerContent;
    if (showProgress) {
      innerContent = SizedBox(
        width: KeyNestTokens.iconSize,
        height: KeyNestTokens.iconSize,
        child: CircularProgressIndicator(
          strokeWidth: 2.0,
          valueColor: AlwaysStoppedAnimation(contentColor),
        ),
      );
    } else {
      final children = <Widget>[];
      if (icon != null) {
        children.add(
          IconTheme(
            data: IconThemeData(
              color: contentColor,
              size: KeyNestTokens.iconSize,
            ),
            child: icon!,
          ),
        );
      }

      if (showLabel) {
        if (icon != null) {
          children.add(const SizedBox(width: 8.0));
        }
        children.add(
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: contentColor,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }

      innerContent = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      );
    }

    Widget button = Container(
      width: fullWidth ? double.infinity : null,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(cornerRadius),
        border: Border.all(
          color: borderColor,
          width: KeyNestTokens.borderWidth,
        ),
      ),
      alignment: Alignment.center,
      child: innerContent,
    );

    if (pressScale && enabled) {
      button = KeyNestPressScale(
        onTap: onClick,
        enabled: enabled,
        child: button,
      );
    } else if (enabled) {
      button = GestureDetector(
        onTap: onClick,
        child: button,
      );
    }

    if (tooltip != null || !showLabel) {
      button = Tooltip(
        message: tooltip ?? label,
        child: button,
      );
    }

    return button;
  }
}

/// Data model for an action item in [KeyNestBottomActionBar].
class KeyNestBottomActionItem {
  const KeyNestBottomActionItem({
    required this.label,
    required this.onClick,
    this.icon,
    this.selected = false,
    this.enabled = true,
    this.showProgress = false,
    this.tone = KeyNestBottomActionTone.neutral,
    this.tooltip,
  });

  final String label;
  final VoidCallback onClick;
  final Widget? icon;
  final bool selected;
  final bool enabled;
  final bool showProgress;
  final KeyNestBottomActionTone tone;
  final String? tooltip;
}

/// Bottom action bar: Centered, width-capped row of action buttons with responsive layout.
class KeyNestBottomActionBar extends StatelessWidget {
  const KeyNestBottomActionBar({
    super.key,
    required this.actions,
    this.maxWidth = KeyNestTokens.contentMaxWidth,
    this.horizontalPadding = KeyNestTokens.contentPadding,
    this.bottomPadding = KeyNestTokens.itemSpacing,
  });

  final List<KeyNestBottomActionItem> actions;
  final double maxWidth;
  final double horizontalPadding;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final barWidth = constraints.maxWidth > maxWidth
            ? maxWidth
            : constraints.maxWidth;
        // Check if labels fit: if slot width < 80dp, hide labels to preserve clean iconography
        final availableWidth =
            barWidth -
            (horizontalPadding * 2) -
            ((actions.length - 1) * KeyNestTokens.itemSpacing);
        final slotWidth = availableWidth / actions.length;
        final showLabels = slotWidth >= 80.0;

        return Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: barWidth,
            padding: EdgeInsets.only(
              left: horizontalPadding,
              right: horizontalPadding,
              bottom: bottomPadding,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: KeyNestTokens.itemSpacing),
                  Expanded(
                    child: KeyNestGlassButton(
                      label: actions[i].label,
                      onClick: actions[i].onClick,
                      icon: actions[i].icon,
                      selected: actions[i].selected,
                      enabled: actions[i].enabled,
                      showProgress: actions[i].showProgress,
                      showLabel: showLabels,
                      tone: actions[i].tone,
                      tooltip: actions[i].tooltip,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
