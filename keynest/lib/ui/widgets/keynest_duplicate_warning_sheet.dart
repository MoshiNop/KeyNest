import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/utils/duplicate_detector.dart';

enum DuplicateResolutionAction {
  saveAnyway,
  openExisting,
  cancel,
}

class KeyNestDuplicateWarningSheet extends StatelessWidget {
  const KeyNestDuplicateWarningSheet({
    super.key,
    required this.match,
  });

  final DuplicateMatch match;

  static Future<DuplicateResolutionAction?> show(
    BuildContext context, {
    required DuplicateMatch match,
  }) {
    return showModalBottomSheet<DuplicateResolutionAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => KeyNestDuplicateWarningSheet(match: match),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? KeyNestPalette.surfaceDark : Colors.white;
    final textPrimary = isDark
        ? KeyNestPalette.textPrimaryDark
        : KeyNestPalette.textPrimaryLight;
    final textSecondary = isDark
        ? KeyNestPalette.textSecondaryDark
        : KeyNestPalette.textSecondaryLight;
    final existingTitle = match.existingEntry.label?.isNotEmpty == true
        ? match.existingEntry.label!
        : 'Untitled Item';
    final existingUser =
        match.existingEntry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(
          color: isDark
              ? KeyNestPalette.entryBorderDark
              : KeyNestPalette.entryBorderLight,
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Header Icon & Title
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: KeyNestPalette.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.copy_all_rounded,
                  color: KeyNestPalette.warning,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Potential Duplicate',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'An entry with matching details already exists',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Existing Item Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark
                  ? KeyNestPalette.surfaceContainerDark
                  : KeyNestPalette.bgLight,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isDark
                    ? KeyNestPalette.entryBorderDark
                    : KeyNestPalette.entryBorderLight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.key_rounded,
                      size: 18,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.lightIcon,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        existingTitle,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: textPrimary,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
                if (existingUser.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Username: $existingUser',
                    style: TextStyle(
                      fontSize: 13,
                      color: textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: KeyNestPalette.warning.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    match.description,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: KeyNestPalette.warning,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Actions
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              foregroundColor: isDark ? const Color(0xFF00315D) : Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.of(
              context,
            ).pop(DuplicateResolutionAction.openExisting),
            child: const Text(
              'Open Existing Entry',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: textPrimary,
              side: BorderSide(
                color: isDark
                    ? KeyNestPalette.entryBorderDark
                    : KeyNestPalette.entryBorderLight,
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () =>
                Navigator.of(context).pop(DuplicateResolutionAction.saveAnyway),
            child: const Text(
              'Save as New Item Anyway',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: textSecondary,
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
            onPressed: () =>
                Navigator.of(context).pop(DuplicateResolutionAction.cancel),
            child: const Text('Keep Editing'),
          ),
        ],
      ),
    );
  }
}
