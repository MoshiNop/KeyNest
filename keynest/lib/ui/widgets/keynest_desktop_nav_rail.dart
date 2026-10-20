import 'package:flutter/material.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/keynest_vault_manager_screen.dart';
import 'package:keynest/ui/screens/preferences.dart';
import 'package:keynest/utils/constants.dart';
import 'package:provider/provider.dart';

/// Modern desktop navigation rail / sidebar for KeyNest (Windows, macOS, Linux, Web).
/// Provides clear vertical navigation with count badges, brand identity,
/// and quick-action utility controls at the bottom.
class KeyNestDesktopNavRail extends StatelessWidget {
  const KeyNestDesktopNavRail({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.counts = const {},
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final Map<int, int> counts;

  static const _navItems = [
    _RailItemData(
      icon: Icons.vpn_key_rounded,
      label: 'Secrets',
      tooltip: 'Secrets / Passwords (Ctrl+1)',
    ),
    _RailItemData(
      icon: Icons.grid_view_rounded,
      label: 'Records',
      tooltip: 'Personal Records & IDs (Ctrl+2)',
    ),
    _RailItemData(
      icon: Icons.credit_card_rounded,
      label: 'Cards',
      tooltip: 'Payment Cards (Ctrl+3)',
    ),
    _RailItemData(
      icon: Icons.sticky_note_2_rounded,
      label: 'Notes',
      tooltip: 'Encrypted Notes (Ctrl+4)',
    ),
    _RailItemData(
      icon: Icons.verified_user_rounded,
      label: '2FA',
      tooltip: 'Authenticator Codes (Ctrl+5)',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isDark
        ? KeyNestPalette.surfaceDark
        : KeyNestPalette.surfaceLight;
    final borderColor = isDark
        ? KeyNestPalette.cardBorderDark
        : KeyNestPalette.cardBorderLight;

    return Container(
      width: 76,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          right: BorderSide(
            color: borderColor,
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // App Logo
          Tooltip(
            message: 'KeyNest - Vault Manager',
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary)
                    .withValues(alpha: isDark ? 0.20 : 0.12),
              ),
              padding: const EdgeInsets.all(7),
              child: Image.asset(
                AssetConstants.logoIcon,
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Navigation Items
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _navItems.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = _navItems[index];
                final isSelected = currentIndex == index;
                final count = counts[index] ?? 0;

                return _RailItemTile(
                  data: item,
                  isSelected: isSelected,
                  count: count,
                  isDark: isDark,
                  onTap: () {
                    onTap(index);
                    KeyNestVaultScope.instance.setActiveTab(index);
                  },
                );
              },
            ),
          ),
          // Bottom utility actions
          Divider(
            height: 1,
            color: borderColor,
            indent: 12,
            endIndent: 12,
          ),
          const SizedBox(height: 6),
          // Lock Vault Button
          _RailActionButton(
            icon: Icons.lock_outline_rounded,
            tooltip: 'Lock Vault',
            color: KeyNestPalette.error,
            onPressed: () {
              context.read<Analytics>().events.trackActionPressed(
                action: 'lockFiles',
              );
              context.read<KdbxBloc>().closeAllFiles(clearQuickUnlock: false);
            },
          ),
          // Manage Vaults Folder Button
          _RailActionButton(
            icon: Icons.folder_open_rounded,
            tooltip: 'Manage Vaults',
            onPressed: () {
              Navigator.of(context).push(KeyNestVaultManagerScreen.route());
            },
          ),
          // Settings / Preferences Button
          _RailActionButton(
            icon: Icons.settings_outlined,
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(PreferencesScreen.route());
            },
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _RailItemData {
  const _RailItemData({
    required this.icon,
    required this.label,
    required this.tooltip,
  });

  final IconData icon;
  final String label;
  final String tooltip;
}

class _RailItemTile extends StatelessWidget {
  const _RailItemTile({
    required this.data,
    required this.isSelected,
    required this.count,
    required this.isDark,
    required this.onTap,
  });

  final _RailItemData data;
  final bool isSelected;
  final int count;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final activeBg = isDark
        ? KeyNestPalette.primaryDark.withValues(alpha: 0.22)
        : KeyNestPalette.primary.withValues(alpha: 0.12);
    final activeColor = isDark
        ? KeyNestPalette.primaryDark
        : KeyNestPalette.primary;
    final inactiveColor = isDark
        ? KeyNestPalette.textSecondaryDark
        : KeyNestPalette.textSecondaryLight;

    return Tooltip(
      message: data.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: isSelected ? activeBg : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: isSelected
                  ? Border.all(
                      color: activeColor.withValues(alpha: 0.35),
                      width: 1,
                    )
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      data.icon,
                      size: 22,
                      color: isSelected ? activeColor : inactiveColor,
                    ),
                    if (count > 0)
                      Positioned(
                        top: -4,
                        right: -10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? activeColor
                                : (isDark
                                    ? KeyNestPalette.surfaceLight.withValues(alpha: 0.2)
                                    : Colors.black12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          constraints: const BoxConstraints(minWidth: 14),
                          child: Text(
                            count > 99 ? '99+' : count.toString(),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: isSelected
                                  ? (isDark ? Colors.black : Colors.white)
                                  : inactiveColor,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  data.label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    color: isSelected ? activeColor : inactiveColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailActionButton extends StatelessWidget {
  const _RailActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final defaultColor = isDark
        ? KeyNestPalette.textSecondaryDark
        : KeyNestPalette.textSecondaryLight;

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: IconButton(
        icon: Icon(icon, size: 20),
        color: color ?? defaultColor,
        splashRadius: 18,
        onPressed: onPressed,
      ),
    );
  }
}
