import 'package:flutter/material.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/utils/platform.dart';

enum EmptyStateType {
  secrets,
  records,
  cards,
  notes,
  twoFactor,
}

class KeyNestEmptyState extends StatelessWidget {
  const KeyNestEmptyState({
    super.key,
    required this.type,
    this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  static Widget secrets({VoidCallback? onAdd}) => KeyNestEmptyState(
    type: EmptyStateType.secrets,
    actionLabel: 'Add Password',
    onAction: onAdd,
  );

  static Widget records({VoidCallback? onAdd}) => KeyNestEmptyState(
    type: EmptyStateType.records,
    actionLabel: 'Add record',
    onAction: onAdd,
  );

  static Widget cards({VoidCallback? onAdd}) => KeyNestEmptyState(
    type: EmptyStateType.cards,
    actionLabel: 'Add card',
    onAction: onAdd,
  );

  static Widget notes({VoidCallback? onAdd}) => KeyNestEmptyState(
    type: EmptyStateType.notes,
    actionLabel: 'Add note',
    onAction: onAdd,
  );

  static Widget twoFactor({VoidCallback? onAdd}) => KeyNestEmptyState(
    type: EmptyStateType.twoFactor,
    actionLabel: 'Add 2FA account',
    onAction: onAdd,
  );

  final EmptyStateType type;
  final String? title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (KeyNestPlatform.isDesktopOrWeb) {
      final String emptyText;
      final IconData emptyIcon;
      switch (type) {
        case EmptyStateType.secrets:
          emptyText = 'No items';
          emptyIcon = Icons.lock_outline_rounded;
          break;
        case EmptyStateType.records:
          emptyText = 'No records';
          emptyIcon = Icons.source_outlined;
          break;
        case EmptyStateType.cards:
          emptyText = 'No cards';
          emptyIcon = Icons.credit_card_outlined;
          break;
        case EmptyStateType.notes:
          emptyText = 'No notes';
          emptyIcon = Icons.description_outlined;
          break;
        case EmptyStateType.twoFactor:
          emptyText = 'No 2FA accounts';
          emptyIcon = Icons.shield_outlined;
          break;
      }

      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF222736)
                      : const Color(0xFFF1F3F5),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF333848)
                        : const Color(0xFFE2E4E8),
                    width: 1.0,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  emptyIcon,
                  size: 22,
                  color: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                title ?? emptyText,
                style: TextStyle(
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                subtitle ?? 'Items will appear here once added',
                style: TextStyle(
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final defaultTitle = _getDefaultTitle();
    final defaultSubtitle = _getDefaultSubtitle();

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildIllustration(isDark),
            const SizedBox(height: 28),
            Text(
              title ?? defaultTitle,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: isDark
                    ? KeyNestPalette.textPrimaryDark
                    : KeyNestPalette.textPrimaryLight,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              subtitle ?? defaultSubtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
                height: 1.45,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onAction,
                icon: Icon(
                  Icons.add_rounded,
                  size: 20,
                  color: isDark ? const Color(0xFF00315D) : Colors.white,
                ),
                label: Text(
                  actionLabel!,
                  style: TextStyle(
                    color: isDark ? const Color(0xFF00315D) : Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                  foregroundColor: isDark
                      ? const Color(0xFF00315D)
                      : Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      KeyNestShapes.radiusButton,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getDefaultTitle() {
    switch (type) {
      case EmptyStateType.secrets:
        return 'Your vault is empty';
      case EmptyStateType.records:
        return 'No records yet';
      case EmptyStateType.cards:
        return 'Your wallet, secured';
      case EmptyStateType.notes:
        return 'A safe place for your notes';
      case EmptyStateType.twoFactor:
        return 'No 2FA accounts yet';
    }
  }

  String _getDefaultSubtitle() {
    switch (type) {
      case EmptyStateType.secrets:
        return 'Keep all your account passwords encrypted and securely organized in one place.';
      case EmptyStateType.records:
        return 'Wi-Fi, IDs, keys, bank details, memberships and more — tap the + button to store your first record.';
      case EmptyStateType.cards:
        return 'Save your credit & debit cards behind AES-256 encryption — ready in a tap at checkout, never written down in plain sight.\n\nTap the + below to add your first card.';
      case EmptyStateType.notes:
        return 'Wi-Fi passwords, passport details, license keys, recovery codes — keep them encrypted and only a tap away.\n\nTap the + below to add your first note.';
      case EmptyStateType.twoFactor:
        return 'Generate secure two-factor codes right here — scan a QR code or enter a key, and your logins get an extra layer of protection.\n\nTap the + below to add your first account.';
    }
  }

  Widget _buildIllustration(bool isDark) {
    switch (type) {
      case EmptyStateType.records:
        return const _DocumentIllustration();
      case EmptyStateType.cards:
        return const _CardsIllustration();
      case EmptyStateType.notes:
        return const _NotesIllustration();
      case EmptyStateType.twoFactor:
        return const _TwoFactorIllustration();
      case EmptyStateType.secrets:
        return const _SecretsIllustration();
    }
  }
}

class _DocumentIllustration extends StatelessWidget {
  const _DocumentIllustration();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 150,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Main Document
          Positioned(
            left: 14,
            top: 10,
            child: Container(
              width: 100,
              height: 125,
              decoration: BoxDecoration(
                color: const Color(0xFF3B82F6),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF3B82F6).withValues(alpha: 0.25),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 6,
                    width: 55,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    height: 5,
                    width: 70,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 5,
                    width: 65,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 5,
                    width: 48,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 5,
                    width: 58,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Checkmark Badge
          Positioned(
            right: 12,
            bottom: 22,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFFBBF24),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFBBF24).withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.check_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardsIllustration extends StatelessWidget {
  const _CardsIllustration();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      height: 130,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Background Lavender Blue Card
          Positioned(
            left: 20,
            top: 6,
            child: Transform.rotate(
              angle: -0.12,
              child: Container(
                width: 130,
                height: 85,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4D65D9), Color(0xFF3B52C7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF4D65D9).withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Foreground Dark Card
          Positioned(
            left: 12,
            top: 24,
            child: Transform.rotate(
              angle: 0.05,
              child: Container(
                width: 145,
                height: 92,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 14,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Chip
                        Container(
                          width: 22,
                          height: 16,
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFFE2E8F0,
                            ).withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        // Contactless Waves
                        const Icon(
                          Icons.contactless_rounded,
                          color: Colors.white70,
                          size: 16,
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 4,
                          width: 80,
                          decoration: BoxDecoration(
                            color: Colors.white70,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              height: 4,
                              width: 44,
                              decoration: BoxDecoration(
                                color: Colors.white38,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Container(
                              width: 14,
                              height: 10,
                              decoration: BoxDecoration(
                                color: Colors.white60,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotesIllustration extends StatelessWidget {
  const _NotesIllustration();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 140,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Notepad
          Container(
            width: 95,
            height: 115,
            decoration: BoxDecoration(
              color: const Color(0xFF0EA5E9),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0EA5E9).withValues(alpha: 0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 6,
                  width: 50,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 4,
                  width: 65,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 4,
                  width: 55,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
          // Red Pencil
          Positioned(
            right: 18,
            bottom: 12,
            child: Transform.rotate(
              angle: 0.65,
              child: Container(
                width: 22,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFF1E293B),
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TwoFactorIllustration extends StatelessWidget {
  const _TwoFactorIllustration();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.primaryContainerDark
            : KeyNestPalette.primaryContainerLight,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color:
                (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                    .withValues(alpha: 0.2),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.verified_user_rounded,
        size: 52,
        color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
      ),
    );
  }
}

class _SecretsIllustration extends StatelessWidget {
  const _SecretsIllustration();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.primaryContainerDark
            : KeyNestPalette.primaryContainerLight,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color:
                (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                    .withValues(alpha: 0.2),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.vpn_key_rounded,
        size: 48,
        color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
      ),
    );
  }
}
