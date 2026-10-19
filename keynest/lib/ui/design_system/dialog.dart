import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

/// Unified dialog component with modern glassmorphic styling and smooth entrance animations.
class KeyNestDialog extends StatelessWidget {
  const KeyNestDialog({
    super.key,
    required this.child,
    this.title,
    this.description,
    this.titleTrailing,
    this.footer,
    this.bottomBar,
    this.accentColor,
    this.scrollable = true,
    this.maxWidth = 480.0,
    this.padding = const EdgeInsets.all(KeyNestTokens.contentPadding),
  });

  final Widget child;
  final String? title;
  final String? description;
  final Widget? titleTrailing;
  final Widget? footer;
  final Widget? bottomBar;
  final Color? accentColor;
  final bool scrollable;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  /// Shows the dialog with smooth dialog enter transition (scale 0.90 -> 1.0 + fade).
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: isDark ? 0.65 : 0.45),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, anim1, anim2) => builder(context),
      transitionBuilder: (context, anim, secondaryAnim, child) {
        final curvedAnim = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );

        return FadeTransition(
          opacity: curvedAnim,
          child: ScaleTransition(
            scale: Tween<double>(
              begin: 0.90,
              end: 1.0,
            ).animate(curvedAnim),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = (isDark ? KeyNestTokens.darkSurface : KeyNestTokens.lightSurface)
        .withValues(alpha: isDark ? 0.85 : 0.90);
    final textColor = isDark
        ? KeyNestTokens.darkOnSurface
        : KeyNestTokens.lightOnSurface;
    final secondaryTextColor = textColor.withValues(alpha: 0.7);

    final borderColor = accentColor != null
        ? accentColor!.withValues(alpha: KeyNestTokens.tintedBorderAlpha)
        : (isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.08));

    Widget dialogContent = child;
    if (scrollable) {
      dialogContent = Flexible(
        child: SingleChildScrollView(
          padding: EdgeInsets.zero,
          child: dialogContent,
        ),
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 16.0,
        vertical: 24.0,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(KeyNestTokens.radiusDialog),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                decoration: ShapeDecoration(
                  color: bg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      KeyNestTokens.radiusDialog,
                    ),
                    side: BorderSide(
                      color: borderColor,
                      width: KeyNestTokens.borderWidth,
                    ),
                  ),
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.45 : 0.12,
                      ),
                      blurRadius: 32.0,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header section
                    if (title != null ||
                        description != null ||
                        titleTrailing != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          KeyNestTokens.contentPaddingExpanded,
                          KeyNestTokens.contentPadding,
                          KeyNestTokens.contentPaddingExpanded,
                          KeyNestTokens.contentPaddingSmall,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                if (title != null)
                                  Expanded(
                                    child: Text(
                                      title!,
                                      style: theme.textTheme.headlineSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: textColor,
                                          ),
                                    ),
                                  ),
                                ?titleTrailing,
                              ],
                            ),
                            if (description != null) ...[
                              const SizedBox(height: 4.0),
                              Text(
                                description!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: secondaryTextColor,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                    // Content section
                    Padding(
                      padding: padding,
                      child: dialogContent,
                    ),

                    // Footer section
                    if (footer != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          KeyNestTokens.contentPaddingExpanded,
                          0,
                          KeyNestTokens.contentPaddingExpanded,
                          KeyNestTokens.contentPadding,
                        ),
                        child: footer!,
                      ),

                    // Docked bottom bar
                    ?bottomBar,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
