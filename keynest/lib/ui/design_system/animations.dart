import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

/// Reusable interactive widget providing tactile spring-scaled press physics
/// and light haptic feedback on touch events.
class KeyNestPressScale extends StatefulWidget {
  const KeyNestPressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.pressedScale = KeyNestTokens.pressedScale,
    this.haptic = true,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final double pressedScale;
  final bool haptic;
  final HitTestBehavior behavior;

  @override
  State<KeyNestPressScale> createState() => _KeyNestPressScaleState();
}

class _KeyNestPressScaleState extends State<KeyNestPressScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 150),
    );
    _scaleAnimation =
        Tween<double>(
          begin: 1.0,
          end: widget.pressedScale,
        ).animate(
          CurvedAnimation(
            parent: _controller,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeOutBack,
          ),
        );
  }

  @override
  void didUpdateWidget(covariant KeyNestPressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pressedScale != widget.pressedScale) {
      _scaleAnimation =
          Tween<double>(
            begin: 1.0,
            end: widget.pressedScale,
          ).animate(
            CurvedAnimation(
              parent: _controller,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeOutBack,
            ),
          );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    if (!widget.enabled) {
      return;
    }
    _controller.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    if (!widget.enabled) {
      return;
    }
    _controller.reverse();
  }

  void _handleTapCancel() {
    if (!widget.enabled) {
      return;
    }
    _controller.reverse();
  }

  void _handleTap() {
    if (!widget.enabled || widget.onTap == null) {
      return;
    }
    if (widget.haptic) {
      HapticFeedback.lightImpact();
    }
    widget.onTap!();
  }

  void _handleLongPress() {
    if (!widget.enabled || widget.onLongPress == null) {
      return;
    }
    if (widget.haptic) {
      HapticFeedback.mediumImpact();
    }
    widget.onLongPress!();
  }

  @override
  Widget build(BuildContext context) {
    Widget content = AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) => Transform.scale(
        scale: _scaleAnimation.value,
        alignment: Alignment.center,
        child: child,
      ),
      child: widget.child,
    );

    if (widget.onTap != null || widget.onLongPress != null) {
      content = GestureDetector(
        behavior: widget.behavior,
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        onTap: _handleTap,
        onLongPress: _handleLongPress,
        child: content,
      );
    }

    return content;
  }
}

/// Custom page route with smooth slide and fade transitions.
class KeyNestPageRoute<T> extends PageRouteBuilder<T> {
  KeyNestPageRoute({
    required WidgetBuilder builder,
    super.settings,
    super.fullscreenDialog = false,
  }) : super(
         pageBuilder: (context, animation, secondaryAnimation) =>
             builder(context),
         transitionDuration: KeyNestTokens.durationScreenEnter,
         reverseTransitionDuration: KeyNestTokens.durationNormal,
         transitionsBuilder: (context, animation, secondaryAnimation, child) {
           final curvedAnimation = CurvedAnimation(
             parent: animation,
             curve: KeyNestTokens.fastOutSlowIn,
             reverseCurve: Curves.easeInCubic,
           );

           final scaleAnimation = Tween<double>(
             begin: KeyNestTokens.dialogInitialScale,
             end: 1.0,
           ).animate(curvedAnimation);

           final fadeAnimation = Tween<double>(
             begin: 0.0,
             end: 1.0,
           ).animate(curvedAnimation);

           return FadeTransition(
             opacity: fadeAnimation,
             child: ScaleTransition(
               scale: scaleAnimation,
               child: child,
             ),
           );
         },
       );
}

/// Push page route for modal screens and sub-flows that slide vertically up
/// on enter (320ms, fastOutSlowIn) and slide down on exit (220ms), with alpha fade.
class KeyNestPushPageRoute<T> extends PageRouteBuilder<T> {
  KeyNestPushPageRoute({
    required WidgetBuilder builder,
    super.settings,
    super.fullscreenDialog = false,
  }) : super(
         pageBuilder: (context, animation, secondaryAnimation) =>
             builder(context),
         transitionDuration: KeyNestTokens.durationScreenEnter,
         reverseTransitionDuration: KeyNestTokens.durationNormal,
         transitionsBuilder: (context, animation, secondaryAnimation, child) {
           final curvedAnimation = CurvedAnimation(
             parent: animation,
             curve: KeyNestTokens.fastOutSlowIn,
             reverseCurve: Curves.easeInCubic,
           );

           final slideAnimation = Tween<Offset>(
             begin: const Offset(0.0, 0.10),
             end: Offset.zero,
           ).animate(curvedAnimation);

           final fadeAnimation = Tween<double>(
             begin: 0.0,
             end: 1.0,
           ).animate(curvedAnimation);

           return SlideTransition(
             position: slideAnimation,
             child: FadeTransition(
               opacity: fadeAnimation,
               child: child,
             ),
           );
         },
       );
}

/// Transition widget for AnimatedSwitcher that implements reference screenEnter / screenExit physics:
/// Enter: 320ms, scale 0.95 -> 1.0 + fade in, fastOutSlowIn curve.
/// Exit: 220ms, scale 1.0 -> 0.95 + fade out.
class KeyNestScreenTransition extends StatelessWidget {
  const KeyNestScreenTransition({
    super.key,
    required this.animation,
    required this.child,
    this.initialScale = KeyNestTokens.dialogInitialScale,
    this.verticalOffset = 0.04,
  });

  final Animation<double> animation;
  final Widget child;
  final double initialScale;
  final double verticalOffset;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: KeyNestTokens.fastOutSlowIn,
      reverseCurve: Curves.easeInCubic,
    );

    final scale = Tween<double>(
      begin: initialScale,
      end: 1.0,
    ).animate(curved);

    final slide = Tween<Offset>(
      begin: Offset(0, verticalOffset),
      end: Offset.zero,
    ).animate(curved);

    return SlideTransition(
      position: slide,
      child: FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: scale,
          child: child,
        ),
      ),
    );
  }
}

/// Directional slide + fade transition for tabs or segmented options,
/// matching reference slideTransitionSpec.
class KeyNestSlideFadeSwitcher extends StatelessWidget {
  const KeyNestSlideFadeSwitcher({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 220),
    this.reverseDuration = const Duration(milliseconds: 180),
    this.slideOffset = const Offset(0.0, 0.06),
  });

  final Widget child;
  final Duration duration;
  final Duration reverseDuration;
  final Offset slideOffset;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: reverseDuration,
      switchInCurve: KeyNestTokens.fastOutSlowIn,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final slide =
            Tween<Offset>(
              begin: slideOffset,
              end: Offset.zero,
            ).animate(
              CurvedAnimation(
                parent: animation,
                curve: KeyNestTokens.fastOutSlowIn,
              ),
            );
        return SlideTransition(
          position: slide,
          child: FadeTransition(
            opacity: animation,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
