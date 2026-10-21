import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/utils/platform.dart';

/// Modal bottom sheet with status bar padding, side insets, and subtle borders.
class KeyNestBottomSheet extends StatelessWidget {
  const KeyNestBottomSheet({
    super.key,
    required this.child,
    this.showDragHandle = true,
    this.backgroundColor,
    this.borderColor,
    this.accentColor,
    this.padding,
  });

  final Widget child;
  final bool showDragHandle;
  final Color? backgroundColor;
  final Color? borderColor;
  final Color? accentColor;
  final EdgeInsetsGeometry? padding;

  /// Shows the modal bottom sheet with status bar padding and side insets.
  static Future<T?> show<T>({
    required BuildContext context,
    WidgetBuilder? builder,
    Widget? child,
    String? title,
    bool isScrollControlled = true,
    bool isDismissible = true,
    bool enableDrag = true,
  }) {
    final WidgetBuilder effectiveBuilder =
        builder ??
        (BuildContext ctx) {
          if (child != null) {
            if (title != null) {
              final isDark = Theme.of(ctx).brightness == Brightness.dark;
              return KeyNestBottomSheet(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Text(
                        title,
                        style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? KeyNestTokens.textPrimaryDark
                              : KeyNestTokens.textPrimaryLight,
                        ),
                      ),
                    ),
                    child,
                  ],
                ),
              );
            }
            return KeyNestBottomSheet(child: child);
          }
          return const SizedBox.shrink();
        };

    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (KeyNestPlatform.isDesktopOrWeb) {
      return showDialog<T>(
        context: context,
        barrierDismissible: isDismissible,
        barrierColor: Colors.black.withValues(alpha: isDark ? 0.60 : 0.40),
        builder: (dialogCtx) => Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 440,
              maxHeight: 540,
            ),
            child: effectiveBuilder(dialogCtx),
          ),
        ),
      );
    }

    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      barrierColor: Colors.black.withValues(alpha: isDark ? 0.60 : 0.40),
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (context) {
        final mediaQuery = MediaQuery.of(context);
        return Padding(
          padding: EdgeInsets.only(
            bottom: mediaQuery.viewInsets.bottom,
            left: KeyNestTokens.sheetSideInset,
            right: KeyNestTokens.sheetSideInset,
            top: mediaQuery.padding.top + 8.0,
          ),
          child: effectiveBuilder(context),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg =
        backgroundColor ??
        (isDark ? KeyNestTokens.darkSurface : KeyNestTokens.lightSurface)
            .withValues(alpha: isDark ? 0.86 : 0.92);
    final effectiveBorderColor =
        borderColor ??
        (accentColor != null
            ? accentColor!.withValues(alpha: KeyNestTokens.tintedBorderAlpha)
            : (isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.black.withValues(alpha: 0.08)));

    final isDesktop = KeyNestPlatform.isDesktopOrWeb;
    final borderRadius = isDesktop
        ? BorderRadius.circular(16)
        : const BorderRadius.vertical(
            top: Radius.circular(KeyNestTokens.radiusSheet),
          );

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: borderRadius,
            border: isDesktop
                ? Border.all(
                    color: effectiveBorderColor,
                    width: KeyNestTokens.borderWidth,
                  )
                : Border(
                    top: BorderSide(
                      color: effectiveBorderColor,
                      width: KeyNestTokens.borderWidth,
                    ),
                    left: BorderSide(
                      color: effectiveBorderColor,
                      width: KeyNestTokens.borderWidth,
                    ),
                    right: BorderSide(
                      color: effectiveBorderColor,
                      width: KeyNestTokens.borderWidth,
                    ),
                  ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
                blurRadius: 24.0,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showDragHandle)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12.0, bottom: 8.0),
                      child: Container(
                        width: 32.0,
                        height: 4.0,
                        decoration: BoxDecoration(
                          color:
                              (isDark
                                      ? KeyNestTokens.darkOnSurface
                                      : KeyNestTokens.lightOnSurface)
                                  .withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(999.0),
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding:
                      padding ??
                      const EdgeInsets.all(KeyNestTokens.contentPadding),
                  child: child,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
