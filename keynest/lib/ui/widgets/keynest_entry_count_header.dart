import 'package:flutter/material.dart';
import 'package:keynest/theme.dart';

class KeyNestEntryCountHeader extends StatelessWidget {
  const KeyNestEntryCountHeader({
    super.key,
    required this.count,
    this.singularLabel = 'entry',
    this.pluralLabel = 'entries',
    this.customText,
    this.padding = const EdgeInsets.fromLTRB(20, 6, 20, 8),
    this.trailing,
  });

  final int count;
  final String singularLabel;
  final String pluralLabel;
  final String? customText;
  final EdgeInsetsGeometry padding;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final text =
        customText ?? '$count ${count == 1 ? singularLabel : pluralLabel}';

    return Padding(
      padding: padding,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
