// ignore_for_file: always_put_control_body_on_new_line
import 'package:flutter/material.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/create_file.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:provider/provider.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  static MaterialPageRoute<void> route() => MaterialPageRoute(
    settings: const RouteSettings(name: '/onboarding'),
    builder: (context) => const OnboardingScreen(),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Hero Icon / Badge
                  Center(
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary,
                            (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary)
                                .withValues(alpha: 0.75),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary)
                                    .withValues(alpha: 0.35),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Icon(
                          Icons.shield_rounded,
                          size: 52,
                          color: isDark
                              ? const Color(0xFF00315D)
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Brand Headline & Subtitle
                  Text(
                    'Welcome to KeyNest',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                      color: isDark
                          ? KeyNestPalette.textPrimaryDark
                          : KeyNestPalette.textPrimaryLight,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your local, secure, encrypted KeePass password manager. Your secrets stay completely under your control.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Key Highlights Badges
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: const [
                      _FeatureBadge(
                        icon: Icons.lock_outline_rounded,
                        label: 'AES-256 Encrypted',
                      ),
                      _FeatureBadge(
                        icon: Icons.wifi_off_rounded,
                        label: '100% Offline',
                      ),
                      _FeatureBadge(
                        icon: Icons.verified_user_outlined,
                        label: 'KDBX 4.0 Standard',
                      ),
                    ],
                  ),
                  const SizedBox(height: 36),

                  // Section Title
                  Text(
                    'Get started with your vault:',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Action Card 1: Create New File
                  _OnboardingActionCard(
                    isPrimary: true,
                    icon: Icons.add_circle_outline_rounded,
                    title: 'Create New File',
                    subtitle:
                        'Create a new encrypted KeePass database on your phone storage.',
                    onTap: () {
                      Navigator.of(context).push(CreateFile.route());
                      context.read<Analytics>().events.trackOnboardingNew();
                    },
                  ),
                  const SizedBox(height: 14),

                  // Action Card 2: Open Existing Vault
                  _OnboardingActionCard(
                    isPrimary: false,
                    icon: Icons.folder_open_rounded,
                    title: 'Open Existing Vault',
                    subtitle:
                        'Open an existing .kdbx file from your phone or cloud storage.',
                    onTap: () {
                      SelectFileScreen.navigate(
                        context,
                        skipQuickUnlock: true,
                      );
                      context
                          .read<Analytics>()
                          .events
                          .trackOnboardingExisting();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureBadge extends StatelessWidget {
  const _FeatureBadge({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingActionCard extends StatelessWidget {
  const _OnboardingActionCard({
    required this.isPrimary,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool isPrimary;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: isPrimary
                ? (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                      .withValues(alpha: isDark ? 0.16 : 0.08)
                : (isDark ? KeyNestPalette.cardDark : KeyNestPalette.cardLight),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isPrimary
                  ? (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary)
                        .withValues(alpha: 0.45)
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.08)),
              width: isPrimary ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isPrimary
                      ? (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary)
                      : (isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.06)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: 22,
                  color: isPrimary
                      ? (isDark ? const Color(0xFF00315D) : Colors.white)
                      : (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: isPrimary
                    ? (isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary)
                    : (isDark ? Colors.white38 : Colors.black38),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
