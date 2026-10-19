import 'package:flutter/material.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/ui/screens/keynest_vault_manager_screen.dart';
import 'package:keynest/ui/screens/locked_screen.dart';
import 'package:keynest/ui/screens/preferences.dart';
import 'package:provider/provider.dart';

class KeyNestHeader extends StatelessWidget {
  const KeyNestHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.avatarEmoji,
    this.icon,
    this.iconColor,
    this.iconBgColor,
  });

  final String title;
  final String subtitle;
  final String? avatarEmoji;
  final IconData? icon;
  final Color? iconColor;
  final Color? iconBgColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final effectiveBgColor =
        iconBgColor ??
        (isDark
            ? const Color(0xFF434657)
            : KeyNestTokens.lightPrimaryContainer);
    final effectiveIconColor =
        iconColor ??
        (isDark ? KeyNestTokens.primaryAccent : KeyNestTokens.lightIcon);
    final effectiveIcon = icon ?? Icons.shield_rounded;

    return SizedBox(
      height: 74,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Tab Icon / Avatar with animated background and smooth content switcher
            KeyNestPressScale(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                curve: KeyNestTokens.fastOutSlowIn,
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: effectiveBgColor,
                  boxShadow: isDark
                      ? null
                      : [
                          BoxShadow(
                            color: effectiveBgColor.withValues(alpha: 0.35),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                ),
                alignment: Alignment.center,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: KeyNestTokens.fastOutSlowIn,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.85,
                        end: 1.0,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: avatarEmoji != null
                      ? Text(
                          avatarEmoji!,
                          key: ValueKey(avatarEmoji),
                          style: const TextStyle(fontSize: 20),
                        )
                      : Icon(
                          effectiveIcon,
                          key: ValueKey(effectiveIcon),
                          color: effectiveIconColor,
                          size: 22,
                        ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Title & Subtitle with fixed consistent height & smooth crossfade
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 30,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      reverseDuration: const Duration(milliseconds: 150),
                      switchInCurve: KeyNestTokens.fastOutSlowIn,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        alignment: Alignment.centerLeft,
                        children: <Widget>[
                          ...previousChildren,
                          ?currentChild,
                        ],
                      ),
                      transitionBuilder: (child, animation) {
                        return SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.0, 0.25),
                            end: Offset.zero,
                          ).animate(animation),
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        );
                      },
                      child: FittedBox(
                        key: ValueKey(title),
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          title,
                          maxLines: 1,
                          softWrap: false,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 24,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 1),
                  SizedBox(
                    height: 18,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      reverseDuration: const Duration(milliseconds: 150),
                      switchInCurve: KeyNestTokens.fastOutSlowIn,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        alignment: Alignment.centerLeft,
                        children: <Widget>[
                          ...previousChildren,
                          ?currentChild,
                        ],
                      ),
                      transitionBuilder: (child, animation) {
                        return SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.0, 0.25),
                            end: Offset.zero,
                          ).animate(animation),
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        );
                      },
                      child: FittedBox(
                        key: ValueKey(subtitle),
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          softWrap: false,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 13,
                            color: isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Action Buttons: Lock & Settings
            _HeaderIconButton(
              icon: Icons.lock_outline_rounded,
              tooltip: 'Lock Vault',
              backgroundColor: isDark
                  ? KeyNestTokens.primaryAccent.withValues(alpha: 0.14)
                  : KeyNestTokens.lightPrimary.withValues(alpha: 0.12),
              iconColor: isDark
                  ? KeyNestTokens.primaryAccent
                  : KeyNestTokens.lightPrimary,
              borderColor: isDark
                  ? KeyNestTokens.primaryAccent.withValues(alpha: 0.32)
                  : KeyNestTokens.lightPrimary.withValues(alpha: 0.28),
              onPressed: () {
                context.read<Analytics>().events.trackActionPressed(
                  action: 'lockFiles',
                );
                context.read<KdbxBloc>().closeAllFiles(clearQuickUnlock: false);
                Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
                  LockedScreen.route(),
                  (_) => false,
                );
              },
            ),
            const SizedBox(width: 8),
            _HeaderIconButton(
              icon: Icons.folder_outlined,
              tooltip: 'Folders & Groups',
              backgroundColor: isDark
                  ? KeyNestPalette.surfaceContainerDark
                  : KeyNestPalette.surfaceContainerLight,
              iconColor: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.lightIcon,
              onPressed: () {
                Navigator.of(context).push(
                  KeyNestVaultManagerScreen.route(),
                );
              },
            ),
            const SizedBox(width: 8),
            _HeaderIconButton(
              icon: Icons.settings_outlined,
              tooltip: 'Settings',
              backgroundColor: isDark
                  ? KeyNestPalette.surfaceContainerDark
                  : KeyNestPalette.surfaceContainerLight,
              iconColor: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.lightIcon,
              onPressed: () {
                Navigator.of(context).push(PreferencesScreen.route());
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.backgroundColor,
    required this.iconColor,
    required this.onPressed,
    this.borderColor,
  });

  final IconData icon;
  final String tooltip;
  final Color backgroundColor;
  final Color iconColor;
  final VoidCallback onPressed;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: KeyNestPressScale(
        onTap: onPressed,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(KeyNestTokens.radiusSettings),
            border: borderColor != null
                ? Border.all(
                    color: borderColor!,
                    width: KeyNestTokens.borderWidth,
                  )
                : null,
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 20,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}
