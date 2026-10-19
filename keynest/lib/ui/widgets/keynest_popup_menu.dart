import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:keynest/theme.dart';

/// A drop-in replacement for [PopupMenuButton] that does not block underlying scrolling.
///
/// When a scroll gesture (drag or mouse wheel) starts with the menu open, this menu
/// automatically dismisses and passes the gesture through to the scrollable below it,
/// allowing the user to scroll in the exact same gesture.
class KeyNestPopupMenuButton<T> extends StatefulWidget {
  const KeyNestPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.initialValue,
    this.onSelected,
    this.onCanceled,
    this.tooltip,
    this.elevation,
    this.padding = const EdgeInsets.all(8.0),
    this.child,
    this.splashRadius,
    this.icon,
    this.iconSize,
    this.offset = Offset.zero,
    this.enabled = true,
    this.shape,
    this.color,
    this.enableFeedback,
    this.constraints,
    this.position = PopupMenuPosition.over,
    this.clipBehavior = Clip.none,
  }) : assert(
         !(child != null && icon != null),
         'You can only pass [child] or [icon], not both.',
       );

  final PopupMenuItemBuilder<T> itemBuilder;
  final T? initialValue;
  final PopupMenuItemSelected<T>? onSelected;
  final PopupMenuCanceled? onCanceled;
  final String? tooltip;
  final double? elevation;
  final EdgeInsetsGeometry padding;
  final Widget? child;
  final double? splashRadius;
  final Widget? icon;
  final double? iconSize;
  final Offset offset;
  final bool enabled;
  final ShapeBorder? shape;
  final Color? color;
  final bool? enableFeedback;
  final BoxConstraints? constraints;
  final PopupMenuPosition position;
  final Clip clipBehavior;

  @override
  State<KeyNestPopupMenuButton<T>> createState() =>
      _KeyNestPopupMenuButtonState<T>();
}

class _KeyNestPopupMenuButtonState<T> extends State<KeyNestPopupMenuButton<T>> {
  void showButtonMenu() {
    final RenderBox? button = context.findRenderObject() as RenderBox?;
    if (button == null || !button.hasSize) {
      return;
    }

    final RenderBox? overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (overlay == null || !overlay.hasSize) {
      return;
    }

    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(widget.offset, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero) + widget.offset,
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final List<PopupMenuEntry<T>> items = widget.itemBuilder(context);
    if (items.isEmpty) {
      return;
    }

    showKeyNestMenu<T>(
      context: context,
      position: position,
      items: items,
      initialValue: widget.initialValue,
      elevation: widget.elevation,
      color: widget.color,
      shape: widget.shape,
      constraints: widget.constraints,
      clipBehavior: widget.clipBehavior,
      popupMenuPosition: widget.position,
    ).then((T? newValue) {
      if (!mounted) {
        return;
      }
      if (newValue == null) {
        widget.onCanceled?.call();
      } else {
        widget.onSelected?.call(newValue);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool enable = widget.enabled;

    if (widget.child != null) {
      return Tooltip(
        message: widget.tooltip ?? '',
        child: InkWell(
          onTap: enable ? showButtonMenu : null,
          canRequestFocus: enable,
          radius: widget.splashRadius,
          enableFeedback: widget.enableFeedback ?? true,
          child: widget.child,
        ),
      );
    }

    return IconButton(
      icon: widget.icon ?? const Icon(Icons.more_vert_rounded),
      padding: widget.padding,
      splashRadius: widget.splashRadius,
      iconSize: widget.iconSize,
      tooltip: widget.tooltip,
      onPressed: enable ? showButtonMenu : null,
      enableFeedback: widget.enableFeedback,
    );
  }
}

/// Pushes a popup menu route that uses a scroll-dismissible barrier.
Future<T?> showKeyNestMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  double? elevation,
  Color? color,
  ShapeBorder? shape,
  BoxConstraints? constraints,
  Clip clipBehavior = Clip.none,
  PopupMenuPosition popupMenuPosition = PopupMenuPosition.over,
}) {
  final NavigatorState navigator = Navigator.of(context);
  return navigator.push<T>(
    _KeyNestPopupMenuRoute<T>(
      position: position,
      items: items,
      initialValue: initialValue,
      elevation: elevation,
      color: color,
      shape: shape,
      constraints: constraints,
      clipBehavior: clipBehavior,
      popupMenuPosition: popupMenuPosition,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
    ),
  );
}

class _KeyNestPopupMenuRoute<T> extends PopupRoute<T> {
  _KeyNestPopupMenuRoute({
    required this.position,
    required this.items,
    this.initialValue,
    this.elevation,
    this.color,
    this.shape,
    this.constraints,
    this.clipBehavior = Clip.none,
    this.popupMenuPosition = PopupMenuPosition.over,
    required this.capturedThemes,
  }) {
    // Initial anchor approximation based on button relative to screen bounds
    final double x = position.left > position.right ? 1.0 : -1.0;
    final double y = position.bottom < 260.0 && position.top > position.bottom
        ? 1.0
        : -1.0;
    _alignment = Alignment(x, y);
  }

  final RelativeRect position;
  final List<PopupMenuEntry<T>> items;
  final T? initialValue;
  final double? elevation;
  final Color? color;
  final ShapeBorder? shape;
  final BoxConstraints? constraints;
  final Clip clipBehavior;
  final PopupMenuPosition popupMenuPosition;
  final CapturedThemes capturedThemes;

  Alignment _alignment = Alignment.topRight;
  Alignment get alignment => _alignment;

  void updateAlignment(Alignment newAlignment) {
    _alignment = newAlignment;
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Widget buildModalBarrier() {
    return _ScrollDismissibleBarrier(
      onDismiss: () {
        if (isActive) {
          navigator?.pop();
        }
      },
    );
  }

  CurvedAnimation? _opacity;
  Animation<double>? _scale;

  CurvedAnimation get opacityAnimation => _opacity ??= CurvedAnimation(
    parent: animation!,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  Animation<double> get scaleAnimation => _scale ??=
      Tween<double>(
        begin: 0.88,
        end: 1.0,
      ).animate(
        CurvedAnimation(
          parent: animation!,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
      );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Transitions are applied directly to the menu card in _KeyNestPopupMenuCard so the animation
    // originates precisely from the triggering button rather than scaling the full-screen layout.
    return child;
  }

  @override
  void dispose() {
    _opacity?.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final mediaQuery = MediaQuery.of(context);
    final textDirection = Directionality.of(context);
    return CustomSingleChildLayout(
      delegate: _KeyNestPopupMenuLayout(
        position: position,
        padding: mediaQuery.padding,
        textDirection: textDirection,
        popupMenuPosition: popupMenuPosition,
        route: this,
      ),
      child: capturedThemes.wrap(
        _KeyNestPopupMenuCard<T>(
          route: this,
          items: items,
          color: color,
          shape: shape,
          elevation: elevation,
          constraints: constraints,
          clipBehavior: clipBehavior,
        ),
      ),
    );
  }
}

/// A modal barrier that allows pointer events to pass through to underlying widgets.
///
/// If pointer moves > 4 pixels or a scroll signal is detected, it immediately
/// dismisses the menu while allowing the underlying scroll view to receive the same gesture.
/// If an outside tap occurs (movement <= 8 pixels on pointer up), it dismisses the menu.
class _ScrollDismissibleBarrier extends StatefulWidget {
  const _ScrollDismissibleBarrier({required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  State<_ScrollDismissibleBarrier> createState() =>
      _ScrollDismissibleBarrierState();
}

class _ScrollDismissibleBarrierState extends State<_ScrollDismissibleBarrier> {
  Offset? _downPos;
  bool _dismissed = false;

  void _triggerDismiss() {
    if (!_dismissed) {
      _dismissed = true;
      widget.onDismiss();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _downPos = event.position;
      },
      onPointerMove: (event) {
        if (_downPos != null) {
          final delta = (event.position - _downPos!).distance;
          if (delta > 4.0) {
            _triggerDismiss();
          }
        }
      },
      onPointerUp: (event) {
        if (_downPos != null) {
          final delta = (event.position - _downPos!).distance;
          if (delta <= 8.0) {
            _triggerDismiss();
          }
        }
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          _triggerDismiss();
        }
      },
      onPointerCancel: (_) {
        _triggerDismiss();
      },
    );
  }
}

class _KeyNestPopupMenuLayout extends SingleChildLayoutDelegate {
  _KeyNestPopupMenuLayout({
    required this.position,
    required this.padding,
    required this.textDirection,
    this.popupMenuPosition = PopupMenuPosition.over,
    this.route,
  });

  final RelativeRect position;
  final EdgeInsets padding;
  final TextDirection textDirection;
  final PopupMenuPosition popupMenuPosition;
  final _KeyNestPopupMenuRoute<dynamic>? route;

  static const double _kMenuScreenPadding = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final double maxW = math.max(
      0.0,
      constraints.maxWidth - padding.horizontal - (_kMenuScreenPadding * 2.0),
    );
    final double maxH = math.max(
      0.0,
      constraints.maxHeight - padding.vertical - (_kMenuScreenPadding * 2.0),
    );
    return BoxConstraints.loose(Size(maxW, maxH));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double minX = padding.left + _kMenuScreenPadding;
    final double maxX = math.max(
      minX,
      size.width - padding.right - childSize.width - _kMenuScreenPadding,
    );
    final double minY = padding.top + _kMenuScreenPadding;
    final double maxY = math.max(
      minY,
      size.height - padding.bottom - childSize.height - _kMenuScreenPadding,
    );

    double x;
    if (textDirection == TextDirection.rtl) {
      if (position.right > position.left) {
        x = position.left;
      } else {
        x = size.width - position.right - childSize.width;
      }
    } else {
      if (position.left > position.right) {
        x = size.width - position.right - childSize.width;
      } else {
        x = position.left;
      }
    }
    x = x.clamp(minX, maxX);

    double y;
    if (popupMenuPosition == PopupMenuPosition.under) {
      y = size.height - position.bottom;
      if (y > maxY && position.top - childSize.height >= minY) {
        y = position.top - childSize.height;
      }
    } else {
      y = position.top;
      if (y > maxY) {
        final double fromBottom =
            size.height - position.bottom - childSize.height;
        if (fromBottom >= minY) {
          y = fromBottom;
        }
      }
    }
    y = y.clamp(minY, maxY);

    // Compute the anchor origin relative to the menu card bounds so the opening
    // and closing animation emerges naturally from and collapses back toward the button.
    final double buttonCenterX =
        (position.left + (size.width - position.right)) / 2.0;
    final double buttonCenterY =
        (position.top + (size.height - position.bottom)) / 2.0;

    final double anchorX = childSize.width > 0
        ? (((buttonCenterX - x) / childSize.width).clamp(0.0, 1.0) * 2.0) - 1.0
        : (textDirection == TextDirection.rtl ? -1.0 : 1.0);
    final double anchorY = childSize.height > 0
        ? (((buttonCenterY - y) / childSize.height).clamp(0.0, 1.0) * 2.0) - 1.0
        : -1.0;

    route?.updateAlignment(Alignment(anchorX, anchorY));

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_KeyNestPopupMenuLayout oldDelegate) {
    return position != oldDelegate.position ||
        padding != oldDelegate.padding ||
        textDirection != oldDelegate.textDirection ||
        popupMenuPosition != oldDelegate.popupMenuPosition ||
        route != oldDelegate.route;
  }
}

class _KeyNestPopupMenuCard<T> extends StatelessWidget {
  const _KeyNestPopupMenuCard({
    required this.route,
    required this.items,
    this.color,
    this.shape,
    this.elevation,
    this.constraints,
    this.clipBehavior = Clip.none,
  });

  final _KeyNestPopupMenuRoute<T> route;
  final List<PopupMenuEntry<T>> items;
  final Color? color;
  final ShapeBorder? shape;
  final double? elevation;
  final BoxConstraints? constraints;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseBg = isDark ? KeyNestPalette.surfaceDark : Colors.white;
    final cardColor = (color ?? theme.popupMenuTheme.color ?? baseBg)
        .withValues(alpha: isDark ? 0.84 : 0.90);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);
    final cardShape =
        shape ??
        theme.popupMenuTheme.shape ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: borderColor,
            width: 1,
          ),
        );

    final Widget menuContent = ConstrainedBox(
      constraints:
          constraints ??
          const BoxConstraints(minWidth: 2.0 * 56.0, maxWidth: 5.0 * 56.0),
      child: IntrinsicWidth(
        stepWidth: 56.0,
        child: Semantics(
          role: SemanticsRole.menu,
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: MaterialLocalizations.of(context).popupMenuLabel,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: ListBody(children: items),
          ),
        ),
      ),
    );

    final Widget card = RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            type: MaterialType.card,
            color: cardColor,
            elevation: elevation ?? 8.0,
            shape: cardShape,
            clipBehavior: clipBehavior,
            child: menuContent,
          ),
        ),
      ),
    );

    return FadeTransition(
      opacity: route.opacityAnimation,
      child: ScaleTransition(
        alignment: route.alignment,
        scale: route.scaleAnimation,
        child: card,
      ),
    );
  }
}
