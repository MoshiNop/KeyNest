import 'package:flutter/material.dart';
import 'package:keynest/theme.dart';

/// Layout delegate to center a popover directly over an anchor rect, clamped to screen bounds.
class _CenteredOnAnchorDelegate extends SingleChildLayoutDelegate {
  const _CenteredOnAnchorDelegate({
    required this.anchorRect,
  });

  final Rect anchorRect;
  static const EdgeInsets screenPadding = EdgeInsets.all(16.0);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: 0,
      maxWidth: (constraints.maxWidth - screenPadding.horizontal).clamp(0.0, double.infinity),
      minHeight: 0,
      maxHeight: (constraints.maxHeight - screenPadding.vertical).clamp(0.0, double.infinity),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = anchorRect.center.dx - (childSize.width / 2.0);
    double y = anchorRect.center.dy - (childSize.height / 2.0);

    final double minX = screenPadding.left;
    final double maxX = size.width - screenPadding.right - childSize.width;
    if (maxX >= minX) {
      x = x.clamp(minX, maxX);
    } else {
      x = minX;
    }

    final double minY = screenPadding.top;
    final double maxY = size.height - screenPadding.bottom - childSize.height;
    if (maxY >= minY) {
      y = y.clamp(minY, maxY);
    } else {
      y = minY;
    }

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_CenteredOnAnchorDelegate oldDelegate) {
    return anchorRect != oldDelegate.anchorRect;
  }
}

/// Context-aware anchored popover utility for desktop and web.
/// Opens a compact, sleek floating dropdown menu/window positioned relative to the clicked widget.
Future<T?> showAnchoredPopover<T>({
  required BuildContext anchorContext,
  required WidgetBuilder builder,
  double width = 320,
  double? maxHeight,
  Offset offset = const Offset(0, 6),
  bool centerOnAnchor = false,
}) async {
  final renderBox = anchorContext.findRenderObject() as RenderBox?;
  final screenSize = MediaQuery.of(anchorContext).size;

  final Rect anchorRect;
  if (renderBox != null && renderBox.hasSize && renderBox.attached) {
    final origin = renderBox.localToGlobal(Offset.zero);
    anchorRect = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      renderBox.size.width,
      renderBox.size.height,
    );
  } else {
    // Fallback: center in screen if anchor render box cannot be resolved
    anchorRect = Rect.fromCenter(
      center: Offset(screenSize.width / 2, screenSize.height / 2),
      width: width,
      height: 48,
    );
  }

  // Horizontal calculation: clamp to screen boundaries with 16px margin
  double left = anchorRect.left + offset.dx;
  if (left + width > screenSize.width - 16) {
    left = screenSize.width - width - 16;
  }
  if (left < 16) {
    left = 16;
  }

  // Vertical calculation: prefer placing below the anchor; if tight, place above
  final spaceBelow = screenSize.height - (anchorRect.bottom + offset.dy) - 16;
  final spaceAbove = anchorRect.top - offset.dy - 16;

  final bool placeBelow = spaceBelow >= 200 || spaceBelow >= spaceAbove;
  final double effectiveMaxHeight;
  final double? top;
  final double? bottom;

  if (centerOnAnchor) {
    top = null;
    bottom = null;
    effectiveMaxHeight = (maxHeight ?? 480.0).clamp(120.0, screenSize.height - 32.0);
  } else if (placeBelow) {
    top = (anchorRect.bottom + offset.dy).clamp(16.0, screenSize.height - 80.0);
    bottom = null;
    effectiveMaxHeight = (maxHeight ?? 480.0).clamp(120.0, spaceBelow.clamp(120.0, screenSize.height * 0.85));
  } else {
    top = null;
    bottom = (screenSize.height - anchorRect.top + offset.dy).clamp(16.0, screenSize.height - 80.0);
    effectiveMaxHeight = (maxHeight ?? 480.0).clamp(120.0, spaceAbove.clamp(120.0, screenSize.height * 0.85));
  }

  final isDark = Theme.of(anchorContext).brightness == Brightness.dark;

  return showGeneralDialog<T>(
    context: anchorContext,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: isDark ? 0.30 : 0.12),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      final popoverCard = Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: width,
            maxHeight: effectiveMaxHeight,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: isDark
                  ? KeyNestPalette.surfaceDark
                  : KeyNestPalette.surfaceLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? KeyNestPalette.cardBorderDark
                    : KeyNestPalette.cardBorderLight,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: isDark ? 0.40 : 0.12,
                  ),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: ScaffoldMessenger(
              child: builder(dialogContext),
            ),
          ),
        ),
      );

      final animatedCard = ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
        alignment: centerOnAnchor
            ? Alignment.center
            : (placeBelow ? Alignment.topCenter : Alignment.bottomCenter),
        child: popoverCard,
      );

      if (centerOnAnchor) {
        return CustomSingleChildLayout(
          delegate: _CenteredOnAnchorDelegate(
            anchorRect: anchorRect,
          ),
          child: animatedCard,
        );
      }

      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            bottom: bottom,
            child: animatedCard,
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: child,
      );
    },
  );
}
