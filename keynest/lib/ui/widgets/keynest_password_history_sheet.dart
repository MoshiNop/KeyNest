// ignore_for_file: implementation_imports
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_entry.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:provider/provider.dart';

class KeyNestPasswordHistorySheet extends StatefulWidget {
  const KeyNestPasswordHistorySheet({
    super.key,
    required this.entry,
    this.onRestore,
    this.kdbxBloc,
  });

  final KdbxEntry entry;
  final void Function(String restoredPassword)? onRestore;
  final KdbxBloc? kdbxBloc;

  static Future<void> show(
    BuildContext context,
    KdbxEntry entry, {
    void Function(String restoredPassword)? onRestore,
    KdbxBloc? kdbxBloc,
  }) {
    final bloc =
        kdbxBloc ?? (context.mounted ? context.read<KdbxBloc>() : null);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => KeyNestPasswordHistorySheet(
        entry: entry,
        onRestore: onRestore,
        kdbxBloc: bloc,
      ),
    );
  }

  @override
  State<KeyNestPasswordHistorySheet> createState() =>
      _KeyNestPasswordHistorySheetState();
}

class _KeyNestPasswordHistorySheetState
    extends State<KeyNestPasswordHistorySheet> {
  final Set<int> _revealedIndices = {};
  bool _isRestoring = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final historyList = widget.entry.history.reversed.toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color:
                                (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary)
                                    .withValues(alpha: isDark ? 0.20 : 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.history_rounded,
                            color: isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Password History',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 20),
              Expanded(
                child: historyList.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.history_toggle_off_rounded,
                                size: 56,
                                color: Colors.grey.withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No Previous Passwords',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Previous versions are automatically archived whenever this entry\'s password is changed.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.grey,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        itemCount: historyList.length,
                        itemBuilder: (context, index) {
                          final hEntry = historyList[index];
                          final pass =
                              hEntry
                                  .getString(KdbxKeyCommon.PASSWORD)
                                  ?.getText() ??
                              '';
                          final modTime = hEntry.times.lastModificationTime
                              .get();
                          final dateStr = modTime != null
                              ? DateFormat(
                                  'MMM d, yyyy • HH:mm',
                                ).format(modTime.toLocal())
                              : 'Unknown date';

                          final isRevealed = _revealedIndices.contains(index);

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: KeyNestCard(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.access_time_rounded,
                                            size: 14,
                                            color: Colors.grey,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            dateStr,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? Colors.white10
                                              : Colors.black.withValues(
                                                  alpha: 0.05,
                                                ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: Text(
                                          'v${historyList.length - index}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          isRevealed
                                              ? (pass.isEmpty
                                                    ? '(empty)'
                                                    : pass)
                                              : '•' *
                                                    (pass.isEmpty
                                                        ? 6
                                                        : pass.length.clamp(
                                                            6,
                                                            16,
                                                          )),
                                          style: TextStyle(
                                            fontSize: 15,
                                            letterSpacing: isRevealed ? 0 : 2,
                                            fontFamily: isRevealed
                                                ? 'monospace'
                                                : null,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          isRevealed
                                              ? Icons.visibility_off_rounded
                                              : Icons.visibility_rounded,
                                          size: 18,
                                        ),
                                        tooltip: isRevealed ? 'Hide' : 'Reveal',
                                        onPressed: () {
                                          setState(() {
                                            if (isRevealed) {
                                              _revealedIndices.remove(index);
                                            } else {
                                              _revealedIndices.add(index);
                                            }
                                          });
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.copy_rounded,
                                          size: 18,
                                        ),
                                        tooltip: 'Copy',
                                        onPressed: () {
                                          HapticFeedback.lightImpact();
                                          SecurityService.copySensitive(
                                            context,
                                            pass,
                                            label: 'Historical Password',
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 6,
                                        ),
                                        minimumSize: Size.zero,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.restore_rounded,
                                        size: 16,
                                      ),
                                      label: const Text(
                                        'Restore This Password',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      onPressed: _isRestoring
                                          ? null
                                          : () => _confirmRestore(pass),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmRestore(String historicalPassword) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore Password?'),
        content: const Text(
          'Your current password will be archived to history, and this version will be restored as the active password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              foregroundColor: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF00315D)
                  : Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isRestoring = true);
      final entry = widget.entry;
      final kdbxBloc = widget.kdbxBloc ?? context.read<KdbxBloc>();

      KdbxEntry? historyClone;
      if (entry.parent != null) {
        historyClone = entry.cloneInto(entry.parent!, toHistoryEntry: true);
        entry.history.add(historyClone);
      }
      final previousPassword = entry.getString(KdbxKeyCommon.PASSWORD);
      final previousModTime = entry.times.lastModificationTime.get();

      entry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString(historicalPassword),
      );
      entry.times.lastModificationTime.set(DateTime.now().toUtc());

      try {
        await kdbxBloc.saveFile(entry.file);
        if (mounted) {
          widget.onRestore?.call(historicalPassword);
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              const SnackBar(
                content: Text('Password restored successfully!'),
                backgroundColor: KeyNestPalette.success,
              ),
            );
        }
      } catch (e) {
        // Revert in-memory changes so entry state remains intact on disk error
        if (historyClone != null) {
          entry.history.remove(historyClone);
        }
        if (previousPassword != null) {
          entry.setString(KdbxKeyCommon.PASSWORD, previousPassword);
        } else {
          entry.removeString(KdbxKeyCommon.PASSWORD);
        }
        if (previousModTime != null) {
          entry.times.lastModificationTime.set(previousModTime);
        }
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text('Failed to restore password: $e'),
                backgroundColor: Colors.redAccent,
              ),
            );
        }
      } finally {
        if (mounted) {
          setState(() => _isRestoring = false);
        }
      }
    }
  }
}
