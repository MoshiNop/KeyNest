import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

/// Single, unified bottom navigation bar component for KeyNest.
/// All navigation buttons are contained within one cohesive, translucent,
/// blurred pill at the bottom of the screen with smooth tactile animations,
/// an exclusive light-mode surface tint for visual separation, and a buttery-smooth
/// continuous sliding selection pill.
class KeyNestBottomNav extends StatefulWidget {
  const KeyNestBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.counts = const {},
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final Map<int, int> counts;

  @override
  State<KeyNestBottomNav> createState() => _KeyNestBottomNavState();
}

class _KeyNestBottomNavState extends State<KeyNestBottomNav>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slideController;
  late final Animation<double> _slideCurvedAnimation;

  late double _startPillPos;
  late double _targetPillPos;
  late List<double> _startWeights;
  late List<double> _targetWeights;
  bool _isSliding = false;

  static const _navItems = [
    _NavItemData(icon: Icons.vpn_key_rounded, label: 'Secrets'),
    _NavItemData(icon: Icons.grid_view_rounded, label: 'Records'),
    _NavItemData(icon: Icons.credit_card_rounded, label: 'Cards'),
    _NavItemData(icon: Icons.sticky_note_2_rounded, label: 'Notes'),
    _NavItemData(icon: Icons.verified_user_rounded, label: '2FA'),
  ];

  @override
  void initState() {
    super.initState();
    _startPillPos = widget.currentIndex.toDouble();
    _targetPillPos = widget.currentIndex.toDouble();
    _startWeights = List.generate(
      5,
      (i) => i == widget.currentIndex ? 2.0 : 1.0,
    );
    _targetWeights = List.generate(
      5,
      (i) => i == widget.currentIndex ? 2.0 : 1.0,
    );
    _isSliding = false;

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 1.0,
    );
    _slideCurvedAnimation = CurvedAnimation(
      parent: _slideController,
      curve: KeyNestTokens.fastOutSlowIn,
    );

    _slideController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (mounted && _isSliding) {
          setState(() {
            _isSliding = false;
          });
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant KeyNestBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex != oldWidget.currentIndex) {
      _animateToTab(widget.currentIndex);
    }
  }

  void _animateToTab(int newIndex) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _startPillPos = newIndex.toDouble();
      _targetPillPos = newIndex.toDouble();
      _startWeights = List.generate(5, (i) => i == newIndex ? 2.0 : 1.0);
      _targetWeights = List.generate(5, (i) => i == newIndex ? 2.0 : 1.0);
      _isSliding = false;
      _slideController.value = 1.0;
      setState(() {});
      return;
    }

    final currentProgress = _slideCurvedAnimation.value;
    final currentPillPos =
        lerpDouble(_startPillPos, _targetPillPos, currentProgress) ??
        newIndex.toDouble();
    final currentWeights = List.generate(5, (i) {
      return lerpDouble(_startWeights[i], _targetWeights[i], currentProgress) ??
          (i == newIndex ? 2.0 : 1.0);
    });

    setState(() {
      _startPillPos = currentPillPos;
      _targetPillPos = newIndex.toDouble();
      _startWeights = currentWeights;
      _targetWeights = List.generate(5, (i) => i == newIndex ? 2.0 : 1.0);
      _isSliding = true;
    });

    _slideController.forward(from: 0.0);
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Translucent glass pill surface styling with refined neutral surface container in light mode
    // contrasting distinctly with the #DFE1F6 active selection pill
    final pillBgColor = isDark
        ? const Color(0xFF1E1F24).withValues(alpha: 0.88)
        : const Color(0xFFF0EEF4).withValues(alpha: 0.96);

    // Deep, prominent layered drop shadow lifting the navbar dock off the page
    final navBoxShadow = isDark
        ? [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.20),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ]
        : [
            BoxShadow(
              color: const Color(0xFF1B222E).withValues(alpha: 0.26),
              blurRadius: 16,
              spreadRadius: 1,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: const Color(0xFF1B222E).withValues(alpha: 0.16),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
            BoxShadow(
              color: const Color(0xFF1B222E).withValues(alpha: 0.08),
              blurRadius: 24,
              spreadRadius: 2,
              offset: const Offset(0, 8),
            ),
          ];

    final navContent = Center(
      heightFactor: 1.0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              boxShadow: navBoxShadow,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  decoration: BoxDecoration(
                    color: pillBgColor,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 5,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final availableWidth = constraints.maxWidth;
                      final unitWidth = availableWidth / 6.0;
                      final pillWidth = (unitWidth * 2.0) - 4.0;

                      return AnimatedBuilder(
                        animation: _slideCurvedAnimation,
                        builder: (context, child) {
                          final progress = _slideCurvedAnimation.value;
                          final animatedPillPos =
                              lerpDouble(
                                _startPillPos,
                                _targetPillPos,
                                progress,
                              ) ??
                              _targetPillPos;

                          final pillLeft = (animatedPillPos * unitWidth) + 2.0;

                          // Compute dynamic weights for each tab item
                          final currentWeights = List.generate(5, (i) {
                            return lerpDouble(
                                  _startWeights[i],
                                  _targetWeights[i],
                                  progress,
                                ) ??
                                1.0;
                          });

                          final totalWeight = currentWeights.fold(
                            0.0,
                            (sum, w) => sum + w,
                          );

                          final widths = List<double>.filled(5, 0.0);
                          double accumulatedWidth = 0.0;
                          for (int i = 0; i < 4; i++) {
                            widths[i] =
                                availableWidth *
                                (currentWeights[i] / totalWeight);
                            accumulatedWidth += widths[i];
                          }
                          widths[4] = (availableWidth - accumulatedWidth).clamp(
                            0.0,
                            availableWidth,
                          );

                          return SizedBox(
                            height: 42,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // Single, continuous sliding active selection pill
                                Positioned(
                                  left: pillLeft,
                                  top: 0,
                                  width: pillWidth,
                                  height: 42,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF434657)
                                          : KeyNestTokens.lightPrimaryContainer,
                                      borderRadius: BorderRadius.circular(21),
                                    ),
                                  ),
                                ),
                                // Coordinated navigation buttons row
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: List.generate(_navItems.length, (
                                    index,
                                  ) {
                                    final item = _navItems[index];
                                    final isSelected =
                                        widget.currentIndex == index;
                                    final count = widget.counts[index] ?? 0;
                                    final itemProgress =
                                        (currentWeights[index] - 1.0).clamp(
                                          0.0,
                                          1.0,
                                        );

                                    return SizedBox(
                                      width: widths[index],
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        child: _NavItemWidget(
                                          key: ValueKey(item.label),
                                          data: item,
                                          isSelected: isSelected,
                                          isSliding: _isSliding,
                                          selectionProgress: itemProgress,
                                          count: count,
                                          onTap: () => widget.onTap(index),
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return RepaintBoundary(
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 6),
        child: navContent,
      ),
    );
  }
}

class _NavItemData {
  const _NavItemData({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

class _NavItemWidget extends StatefulWidget {
  const _NavItemWidget({
    super.key,
    required this.data,
    required this.isSelected,
    required this.isSliding,
    required this.selectionProgress,
    required this.count,
    required this.onTap,
  });

  final _NavItemData data;
  final bool isSelected;
  final bool isSliding;
  final double selectionProgress;
  final int count;
  final VoidCallback onTap;

  @override
  State<_NavItemWidget> createState() => _NavItemWidgetState();
}

class _NavItemWidgetState extends State<_NavItemWidget>
    with TickerProviderStateMixin {
  late final AnimationController _pressController;
  late final Animation<double> _pressScaleAnimation;

  late final AnimationController _iconPulseController;
  late final Animation<double> _iconScaleAnimation;

  @override
  void initState() {
    super.initState();

    // Tactile press-scale animation (sinks down to 0.96, springs back with easeOutBack)
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _pressScaleAnimation = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(
        parent: _pressController,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeOutBack,
      ),
    );

    // Icon micro-animation (spring pulse upon selection)
    _iconPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _iconScaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.16,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.16,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 60,
      ),
    ]).animate(_iconPulseController);
  }

  @override
  void didUpdateWidget(covariant _NavItemWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSelected && !oldWidget.isSelected) {
      _iconPulseController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _pressController.dispose();
    _iconPulseController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    _pressController.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    _pressController.reverse();
  }

  void _handleTapCancel() {
    _pressController.reverse();
  }

  void _handleTap() {
    HapticFeedback.selectionClick();
    if (!_pressController.isAnimating && _pressController.value == 0.0) {
      _pressController.forward().then((_) {
        if (mounted) {
          _pressController.reverse();
        }
      });
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    // Accent and text colors
    final activeColor = isDark
        ? KeyNestTokens.primaryAccent
        : KeyNestTokens.lightOnPrimaryContainer;
    final inactiveColor = isDark
        ? const Color(0xFFC6C6CE)
        : const Color(0xFF46464E);

    // Selected highlight pill colors inside the unified bar
    final unselectedContainer = Colors.transparent;
    final selectedContainer = isDark
        ? const Color(0xFF434657)
        : KeyNestTokens.lightPrimaryContainer;

    // At rest, the selected button container matches the sliding pill underneath
    // for exact test-suite compatibility; during slide, it is transparent so only
    // the single sliding pill is visible with zero competing selection backgrounds.
    final containerColor = (widget.isSelected && !widget.isSliding)
        ? selectedContainer
        : unselectedContainer;

    final contentColor = Color.lerp(
      inactiveColor,
      activeColor,
      widget.selectionProgress,
    )!;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _pressController,
        _iconPulseController,
      ]),
      builder: (context, child) {
        final pressValue = _pressScaleAnimation.value;
        final scale = reduceMotion ? 1.0 : pressValue;
        final iconScale = reduceMotion ? 1.0 : _iconScaleAnimation.value;

        return Transform.scale(
          scale: scale,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _handleTapDown,
            onTapUp: _handleTapUp,
            onTapCancel: _handleTapCancel,
            onTap: _handleTap,
            child: Container(
              height: 42,
              decoration: BoxDecoration(
                color: containerColor,
                borderRadius: BorderRadius.circular(21),
              ),
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.scale(
                      scale: iconScale,
                      child: Icon(
                        widget.data.icon,
                        size: 20,
                        color: contentColor,
                      ),
                    ),
                    Flexible(
                      child: ClipRect(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          widthFactor: widget.selectionProgress,
                          child: Opacity(
                            opacity: widget.selectionProgress.clamp(0.0, 1.0),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4.0),
                              child: Text(
                                widget.data.label,
                                style:
                                    (theme.textTheme.labelMedium ??
                                            const TextStyle())
                                        .copyWith(
                                          fontSize: 11.5,
                                          fontWeight: widget.isSelected
                                              ? FontWeight.w600
                                              : FontWeight.w500,
                                          color: contentColor,
                                        ),
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
