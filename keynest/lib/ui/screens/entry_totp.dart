import 'package:flutter/material.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/theme.dart';

class OtpFieldEntryEditor extends StatelessWidget {
  const OtpFieldEntryEditor({
    super.key,
    required this.otpCode,
    required this.elapsed,
    required this.period,
  });

  final String otpCode;
  final int elapsed;
  final int period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final loc = AppLocalizations.of(context);
    final remaining = period - (elapsed % period);

    return InputDecorator(
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        labelText: loc.otpEntryLabel,
        labelStyle: TextStyle(
          color: isDark
              ? KeyNestPalette.textSecondaryDark
              : KeyNestPalette.textSecondaryLight,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 24,
        ),
        suffixIcon: Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color:
                (remaining <= 5 ? KeyNestPalette.error : KeyNestPalette.primary)
                    .withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${remaining}s',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: remaining <= 5
                  ? KeyNestPalette.error
                  : KeyNestPalette.primary,
            ),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          otpCode.isNotEmpty ? otpCode : '------',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            fontFamily: KeyNestTheme.monoFontFamily,
            letterSpacing: 2.0,
            color: isDark
                ? KeyNestPalette.textPrimaryDark
                : KeyNestPalette.textPrimaryLight,
          ),
        ),
      ),
    );
  }
}
