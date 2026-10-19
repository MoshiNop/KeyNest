import 'package:flutter/material.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

enum KeyNestActionPillTone {
  neutral,
  primary,
  warning,
  tertiary,
  destructive,
}

/// Pill-shaped action button with icon and optional text label.
class KeyNestActionPillButton extends StatefulWidget {
  const KeyNestActionPillButton({
    super.key,
    required this.onClick,
    required this.icon,
    this.label,
    this.tooltip,
    this.enabled = true,
    this.large = false,
    this.tone = KeyNestActionPillTone.neutral,
    this.destructive = false,
    this.confirmationMessage,
    this.pressScale = true,
  });

  final VoidCallback onClick;
  final Widget icon;
  final String? label;
  final String? tooltip;
  final bool enabled;
  final bool large;
  final KeyNestActionPillTone tone;
  final bool destructive;
  final String? confirmationMessage;
  final bool pressScale;

  @override
  State<KeyNestActionPillButton> createState() =>
      _KeyNestActionPillButtonState();
}

class _KeyNestActionPillButtonState extends State<KeyNestActionPillButton> {
  String? _activeConfirmation;

  void _handleClick() {
    if (!widget.enabled) {
      return;
    }
    widget.onClick();

    if (widget.confirmationMessage != null) {
      setState(() {
        _activeConfirmation = widget.confirmationMessage;
      });
      Future.delayed(const Duration(milliseconds: 1800), () {
        if (mounted) {
          setState(() {
            _activeConfirmation = null;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final height = widget.large
        ? KeyNestTokens.pillHeightLarge
        : KeyNestTokens.pillHeight;
    final iconSize = widget.large ? 20.0 : 18.0;
    final textStyle =
        (widget.large
            ? theme.textTheme.labelLarge
            : theme.textTheme.labelSmall) ??
        const TextStyle();

    // Color resolution based on tone
    Color containerColor;
    Color contentColor;
    BorderSide? border;

    if (widget.destructive ||
        widget.tone == KeyNestActionPillTone.destructive) {
      containerColor = isDark
          ? KeyNestTokens.darkErrorContainer.withValues(alpha: 0.35)
          : KeyNestTokens.lightErrorContainer.withValues(alpha: 0.5);
      contentColor = isDark
          ? KeyNestTokens.darkError
          : KeyNestTokens.lightError;
      border = BorderSide(
        color: contentColor.withValues(alpha: 0.4),
        width: 1.0,
      );
    } else {
      switch (widget.tone) {
        case KeyNestActionPillTone.primary:
          containerColor = isDark
              ? KeyNestTokens.darkPrimaryContainer
              : KeyNestTokens.lightPrimaryContainer;
          contentColor = isDark
              ? KeyNestTokens.darkOnPrimaryContainer
              : KeyNestTokens.lightOnPrimaryContainer;
          break;
        case KeyNestActionPillTone.warning:
          containerColor = isDark
              ? KeyNestTokens.darkWarningContainer
              : KeyNestTokens.lightWarningContainer;
          contentColor = isDark
              ? KeyNestTokens.darkOnWarningContainer
              : KeyNestTokens.lightOnWarningContainer;
          break;
        case KeyNestActionPillTone.tertiary:
          containerColor = isDark
              ? KeyNestTokens.darkTertiaryContainer
              : KeyNestTokens.lightTertiaryContainer;
          contentColor = isDark
              ? KeyNestTokens.darkOnTertiaryContainer
              : KeyNestTokens.lightOnTertiaryContainer;
          break;
        case KeyNestActionPillTone.neutral:
        default:
          containerColor = isDark
              ? KeyNestTokens.darkSurfaceVariant.withValues(alpha: 0.55)
              : KeyNestTokens.lightSurfaceVariant.withValues(alpha: 0.7);
          contentColor = isDark
              ? KeyNestTokens.darkOnSurfaceVariant
              : KeyNestTokens.lightOnSurfaceVariant;
          break;
      }
    }

    if (!widget.enabled && _activeConfirmation == null) {
      containerColor = containerColor.withValues(
        alpha: KeyNestTokens.disabledAlpha,
      );
      contentColor = contentColor.withValues(
        alpha: KeyNestTokens.disabledAlpha,
      );
      if (border != null) {
        border = BorderSide(
          color: border.color.withValues(
            alpha: border.color.a * KeyNestTokens.disabledAlpha,
          ),
          width: border.width,
        );
      }
    }

    Widget content;
    if (_activeConfirmation != null) {
      content = AnimatedSwitcher(
        duration: KeyNestTokens.durationShort,
        child: Padding(
          key: ValueKey(_activeConfirmation),
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Text(
            _activeConfirmation!,
            style: textStyle.copyWith(
              color: contentColor,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconTheme(
            data: IconThemeData(
              color: contentColor,
              size: iconSize,
            ),
            child: widget.icon,
          ),
          if (widget.label != null) ...[
            const SizedBox(width: 6.0),
            Flexible(
              child: Text(
                widget.label!,
                style: textStyle.copyWith(
                  color: contentColor,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      );
    }

    Widget button = Container(
      height: height,
      padding: EdgeInsets.symmetric(
        horizontal: widget.label != null ? 14.0 : 12.0,
      ),
      decoration: ShapeDecoration(
        color: containerColor,
        shape: StadiumBorder(side: border ?? BorderSide.none),
      ),
      alignment: Alignment.center,
      child: content,
    );

    if (widget.pressScale && widget.enabled) {
      button = KeyNestPressScale(
        onTap: _handleClick,
        enabled: widget.enabled,
        child: button,
      );
    } else if (widget.enabled) {
      button = GestureDetector(
        onTap: _handleClick,
        child: button,
      );
    }

    if (widget.tooltip != null) {
      button = Tooltip(
        message: widget.tooltip!,
        child: button,
      );
    }

    return button;
  }
}

/// Action row item data model for [KeyNestCardActionRow].
class KeyNestCardAction {
  const KeyNestCardAction({
    required this.icon,
    required this.label,
    required this.onClick,
    this.enabled = true,
    this.destructive = false,
    this.tone = KeyNestActionPillTone.neutral,
    this.tooltip,
  });

  final Widget icon;
  final String label;
  final VoidCallback onClick;
  final bool enabled;
  final bool destructive;
  final KeyNestActionPillTone tone;
  final String? tooltip;
}

/// Wide action row anchored to the bottom of a card.
class KeyNestCardActionRow extends StatelessWidget {
  const KeyNestCardActionRow({
    super.key,
    required this.actions,
  }) : assert(
         actions.length >= 1 && actions.length <= 2,
         'CardActionRow supports 1 or 2 actions',
       );

  final List<KeyNestCardAction> actions;

  @override
  Widget build(BuildContext context) {
    final hasBoth = actions.length == 2;

    return Row(
      mainAxisAlignment: hasBoth
          ? MainAxisAlignment.spaceBetween
          : MainAxisAlignment.center,
      children: [
        for (int i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 8.0),
          Expanded(
            flex: hasBoth ? 1 : 0,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: hasBoth ? 0 : 160.0,
              ),
              child: KeyNestActionPillButton(
                onClick: actions[i].onClick,
                icon: actions[i].icon,
                label: actions[i].label,
                tooltip: actions[i].tooltip,
                enabled: actions[i].enabled,
                destructive: actions[i].destructive,
                tone: actions[i].destructive
                    ? KeyNestActionPillTone.destructive
                    : actions[i].tone,
                large: true,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
