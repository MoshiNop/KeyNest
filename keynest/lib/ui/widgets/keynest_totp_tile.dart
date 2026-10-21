import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/utils/entry_totp_helper.dart';

/// Interactive, live-updating TOTP authenticator tile for entry view mode across
/// Logins, Cards, and Notes. Displays generated time-based codes, a countdown badge,
/// and provides tap-to-copy and visibility toggle.
class KeyNestTotpTile extends StatefulWidget {
  const KeyNestTotpTile({
    super.key,
    required this.entry,
    this.secret,
    this.label,
    this.isMasked = false,
    this.onToggleMask,
    this.onDelete,
    this.compact = false,
  });

  final KdbxEntry entry;
  final String? secret;
  final String? label;
  final bool isMasked;
  final VoidCallback? onToggleMask;
  final VoidCallback? onDelete;
  final bool compact;

  @override
  State<KeyNestTotpTile> createState() => _KeyNestTotpTileState();
}

class _KeyNestTotpTileState extends State<KeyNestTotpTile>
    with WidgetsBindingObserver {
  Timer? _timer;
  int? _currentStep;
  String? _totpCode;
  int _remaining = 30;
  int _period = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _recompute();
    _startTimer();
  }

  @override
  void didUpdateWidget(KeyNestTotpTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry != widget.entry ||
        oldWidget.secret != widget.secret ||
        oldWidget.isMasked != widget.isMasked) {
      _currentStep = null;
      _recompute();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTimer();
    } else {
      _stopTimer();
    }
  }

  void _startTimer() {
    if (_timer != null && _timer!.isActive) {
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recompute();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
    super.dispose();
  }

  void _recompute() {
    final nowMs = clock.now().millisecondsSinceEpoch;
    final nowSec = nowMs ~/ 1000;
    final activePeriod = _period > 0 ? _period : 30;
    final step = nowSec ~/ activePeriod;

    if (_currentStep != step || _totpCode == null) {
      _currentStep = step;
      final EntryTotpInfo? info;
      final customSecret = widget.secret?.trim();
      if (customSecret != null && customSecret.isNotEmpty) {
        info = EntryTotpHelper.getTotpInfoForSecret(
          customSecret,
          entry: widget.entry,
          timestampMs: nowMs,
        );
      } else {
        info = EntryTotpHelper.getTotpInfo(
          widget.entry,
          timestampMs: nowMs,
        );
      }

      _totpCode = info?.code;
      if (info != null && info.period > 0) {
        _period = info.period;
      }
    }

    final period = _period > 0 ? _period : 30;
    final remaining = period - (nowSec % period);
    if (mounted) {
      setState(() {
        _remaining = remaining;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final displayLabel = widget.label ?? 'One-Time Password (2FA)';

    final VoidCallback? copyCallback = _totpCode != null
        ? () {
            HapticFeedback.lightImpact();
            SecurityService.copySensitive(
              context,
              _totpCode!,
              label: displayLabel,
            );
          }
        : null;

    final isUrgent = _remaining <= 5;
    final badgeColor = isUrgent
        ? KeyNestPalette.error
        : (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary);

    return Padding(
      padding: EdgeInsets.only(bottom: widget.compact ? 8 : 12),
      child: KeyNestPressScale(
        onTap: copyCallback,
        child: Material(
          color: isDark ? KeyNestPalette.cardDark : KeyNestPalette.surfaceLight,
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
          child: InkWell(
            borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
            child: Container(
              padding: widget.compact
                  ? const EdgeInsets.symmetric(horizontal: 10, vertical: 10)
                  : const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
                border: Border.all(
                  color: isDark
                      ? KeyNestPalette.entryBorderDark
                      : KeyNestPalette.entryBorderLight,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Center(
                      child: Icon(
                        Icons.timer_outlined,
                        size: widget.compact ? 20 : 22,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.lightIcon,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight,
                            fontSize: widget.compact ? 11 : 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.isMasked ? '••••••' : (_totpCode ?? '------'),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFamily: KeyNestTheme.monoFontFamily,
                            letterSpacing: widget.isMasked ? 2.0 : 1.2,
                            fontSize: widget.compact ? 14 : 16,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_totpCode != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(
                          alpha: isDark ? 0.20 : 0.15,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${_remaining}s',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: badgeColor,
                        ),
                      ),
                    ),
                  ],
                  if (widget.onToggleMask != null) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        widget.isMasked
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        size: 20,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                      tooltip: widget.isMasked ? 'Reveal TOTP' : 'Hide TOTP',
                      onPressed: widget.onToggleMask,
                    ),
                  ],
                  if (widget.onDelete != null) ...[
                    const SizedBox(width: 2),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 20,
                        color: KeyNestPalette.error,
                      ),
                      tooltip: 'Delete field',
                      onPressed: widget.onDelete,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
