// ignore_for_file: implementation_imports
import 'package:autofill_service/autofill_service.dart';
import 'package:autofill_shared/credential_matcher.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_entry.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:logging/logging.dart';

final _logger = Logger('keynest_autofill_save_dialog');

enum SaveMode {
  saveNew,
  updateExisting,
}

class SaveCandidateMatch {
  SaveCandidateMatch({
    required this.entry,
    required this.file,
    required this.title,
    required this.username,
    required this.vaultName,
    required this.folderName,
    required this.hasExactUsernameMatch,
    this.quality,
  });

  final KdbxEntry entry;
  final KdbxFile file;
  final String title;
  final String username;
  final String vaultName;
  final String folderName;
  final bool hasExactUsernameMatch;
  final CredentialMatchQuality? quality;
}

class KeyNestAutofillSaveDialog extends StatefulWidget {
  const KeyNestAutofillSaveDialog({
    super.key,
    required this.kdbxBloc,
    required this.pendingSave,
    this.onDismiss,
  });

  final KdbxBloc kdbxBloc;
  final PendingSaveRequest pendingSave;
  final VoidCallback? onDismiss;

  static bool _isShowing = false;

  static Future<void> checkAndShow(
    BuildContext context,
    KdbxBloc kdbxBloc,
  ) async {
    if (_isShowing) {
      return;
    }
    try {
      final saveRequest = await AutofillService().getPendingSaveRequest();
      if (saveRequest != null &&
          (saveRequest.password.isNotEmpty ||
              saveRequest.username.isNotEmpty)) {
        if (!context.mounted) {
          return;
        }
        _isShowing = true;
        try {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => KeyNestAutofillSaveDialog(
              kdbxBloc: kdbxBloc,
              pendingSave: saveRequest,
              onDismiss: () => Navigator.of(ctx).pop(),
            ),
          );
        } finally {
          _isShowing = false;
        }
      }
    } catch (e, stack) {
      _logger.warning('Failed to check pending save request', e, stack);
    }
  }

  @override
  State<KeyNestAutofillSaveDialog> createState() =>
      _KeyNestAutofillSaveDialogState();
}

class _KeyNestAutofillSaveDialogState extends State<KeyNestAutofillSaveDialog> {
  bool _obscurePassword = true;
  bool _isSaving = false;
  late TextEditingController _titleController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _urlController;

  List<SaveCandidateMatch> _candidates = [];
  SaveCandidateMatch? _selectedCandidate;
  SaveMode _saveMode = SaveMode.saveNew;

  KdbxFile? _destinationFile;
  KdbxGroup? _destinationGroup;

  @override
  void initState() {
    super.initState();
    final save = widget.pendingSave;
    final domain = save.webDomain.trim();
    final pkg = save.packageName.trim();

    final targetDisplay = domain.isNotEmpty
        ? domain
        : (pkg.isNotEmpty ? _formatPackage(pkg) : 'New Login');

    _titleController = TextEditingController(text: targetDisplay);
    _usernameController = TextEditingController(text: save.username);
    _passwordController = TextEditingController(text: save.password);
    _urlController = TextEditingController(
      text: domain.isNotEmpty ? 'https://$domain' : '',
    );

    _candidates = _findCandidateMatches();

    if (_candidates.isNotEmpty) {
      final exactMatch = _candidates.firstWhereOrNull(
        (c) => c.hasExactUsernameMatch,
      );
      if (exactMatch != null) {
        // Known account on this domain with identical username/email
        _saveMode = SaveMode.updateExisting;
        _selectedCandidate = exactMatch;
      } else {
        // Multiple entries or new registration with different username/email:
        // Do NOT automatically overwrite an entry based only on domain match!
        _saveMode = SaveMode.saveNew;
        _selectedCandidate = _candidates.first;
      }
    } else {
      _saveMode = SaveMode.saveNew;
      _selectedCandidate = null;
    }

    _destinationFile =
        KeyNestVaultScope.instance.getSelectedVault(widget.kdbxBloc) ??
        widget.kdbxBloc.openedFilesKdbx.firstOrNull;
    _destinationGroup =
        KeyNestVaultScope.instance.getCurrentFolder(widget.kdbxBloc) ??
        _destinationFile?.body.rootGroup;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  String _formatPackage(String pkg) {
    final parts = pkg.split('.');
    if (parts.length >= 2) {
      final name = parts.last;
      return name[0].toUpperCase() + name.substring(1);
    }
    return pkg;
  }

  List<SaveCandidateMatch> _findCandidateMatches() {
    final save = widget.pendingSave;
    final requests = <CredentialRequest>[];
    final cleanDomain = save.webDomain.trim();
    if (cleanDomain.isNotEmpty) {
      requests.add(CredentialRequest.web('https://$cleanDomain'));
      if (cleanDomain.startsWith('www.')) {
        requests.add(
          CredentialRequest.web('https://${cleanDomain.substring(4)}'),
        );
      }
    }
    if (save.packageName.trim().isNotEmpty) {
      requests.add(CredentialRequest.application(save.packageName.trim()));
    }

    if (requests.isEmpty) {
      return [];
    }

    final candidates = <SaveCandidateMatch>[];
    final cleanInputUser = save.username.trim().toLowerCase();

    for (final file in widget.kdbxBloc.openedFilesKdbx) {
      final vaultName = KeyNestVaultScope.cleanVaultName(widget.kdbxBloc, file);
      for (final entry in file.body.rootGroup.getAllEntries()) {
        if (entry.isInRecycleBin()) {
          continue;
        }

        final quality = CredentialMatcher.instance.matchBest(
          requests,
          entry.autofillUrls,
        );

        bool matchesOrigin = quality != null;
        if (!matchesOrigin && cleanDomain.isNotEmpty) {
          final entryUrl =
              entry.getString(KdbxKeyCommon.URL)?.getText()?.trim() ?? '';
          if (entryUrl.isNotEmpty) {
            final parsedHost = Uri.tryParse(entryUrl)?.host.toLowerCase() ?? '';
            final cleanHost = parsedHost.startsWith('www.')
                ? parsedHost.substring(4)
                : parsedHost;
            final targetHost = cleanDomain.startsWith('www.')
                ? cleanDomain.substring(4)
                : cleanDomain;
            if (cleanHost.isNotEmpty &&
                (cleanHost == targetHost ||
                    cleanHost.endsWith('.$targetHost') ||
                    targetHost.endsWith('.$cleanHost'))) {
              matchesOrigin = true;
            }
          }
        }

        if (matchesOrigin) {
          final entryUser =
              entry.getString(KdbxKeyCommon.USER_NAME)?.getText()?.trim() ?? '';
          final entryTitle =
              entry.getString(KdbxKeyCommon.TITLE)?.getText()?.trim() ?? '';
          final folderName =
              (entry.parent == null || entry.parent == file.body.rootGroup)
              ? 'Root Folder'
              : (entry.parent?.name.get() ?? 'Root Folder');

          final hasExactUser =
              cleanInputUser.isNotEmpty &&
              entryUser.toLowerCase() == cleanInputUser;

          candidates.add(
            SaveCandidateMatch(
              entry: entry,
              file: file,
              title: entryTitle.isNotEmpty
                  ? entryTitle
                  : (cleanDomain.isNotEmpty ? cleanDomain : 'Saved Login'),
              username: entryUser,
              vaultName: vaultName,
              folderName: folderName,
              hasExactUsernameMatch: hasExactUser,
              quality: quality,
            ),
          );
        }
      }
    }

    // Sort: exact username match first, then alphabetically by title
    candidates.sort((a, b) {
      if (a.hasExactUsernameMatch && !b.hasExactUsernameMatch) {
        return -1;
      }
      if (!a.hasExactUsernameMatch && b.hasExactUsernameMatch) {
        return 1;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    return candidates;
  }

  Future<void> _handleSave() async {
    setState(() {
      _isSaving = true;
    });

    try {
      if (_saveMode == SaveMode.updateExisting) {
        if (_selectedCandidate == null) {
          throw StateError('Please select an entry to update.');
        }

        final entry = _selectedCandidate!.entry;
        final file = _selectedCandidate!.file;

        // Archive previous state into entry history before updating password
        if (entry.parent != null) {
          entry.history.add(
            entry.cloneInto(entry.parent!, toHistoryEntry: true),
          );
        }

        entry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString(_passwordController.text),
        );
        if (_usernameController.text.trim().isNotEmpty) {
          entry.setString(
            KdbxKeyCommon.USER_NAME,
            PlainValue(_usernameController.text.trim()),
          );
        }
        entry.times.lastModificationTime.set(DateTime.now().toUtc());

        await widget.kdbxBloc.saveFile(file);
      } else {
        // CREATE new entry in the chosen destination vault and folder
        final file =
            _destinationFile ?? widget.kdbxBloc.openedFilesKdbx.firstOrNull;
        if (file == null) {
          throw StateError('No open vault available to save credential.');
        }

        final group = _destinationGroup ?? file.body.rootGroup;
        final newEntry = widget.kdbxBloc.createEntry(
          file: file,
          group: group,
        );

        if (_titleController.text.trim().isNotEmpty) {
          newEntry.setString(
            KdbxKeyCommon.TITLE,
            PlainValue(_titleController.text.trim()),
          );
        }
        if (_usernameController.text.trim().isNotEmpty) {
          newEntry.setString(
            KdbxKeyCommon.USER_NAME,
            PlainValue(_usernameController.text.trim()),
          );
        }
        if (_passwordController.text.isNotEmpty) {
          newEntry.setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString(_passwordController.text),
          );
        }
        if (_urlController.text.trim().isNotEmpty) {
          newEntry.setString(
            KdbxKeyCommon.URL,
            PlainValue(_urlController.text.trim()),
          );
        }

        newEntry.times.creationTime.set(DateTime.now().toUtc());
        newEntry.times.lastModificationTime.set(DateTime.now().toUtc());

        await widget.kdbxBloc.saveFile(file);
      }

      await AutofillService().clearPendingSaveRequest();
    } catch (e, stack) {
      _logger.warning('Failed to save autofill credential', e, stack);
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        widget.onDismiss?.call();
      }
    }
  }

  Future<void> _handleDiscard() async {
    try {
      await AutofillService().clearPendingSaveRequest();
    } catch (e) {
      _logger.warning('Failed to clear pending save request', e);
    }
    widget.onDismiss?.call();
  }

  Future<void> _pickDestination() async {
    final dest = await KeyNestDestinationPickerSheet.show(
      context,
      initialFile: _destinationFile,
      initialGroup: _destinationGroup,
    );
    if (dest != null && mounted) {
      setState(() {
        _destinationFile = dest.file;
        _destinationGroup = dest.group;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasCandidates = _candidates.isNotEmpty;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: isDark
          ? KeyNestPalette.cardDark
          : KeyNestPalette.cardLight,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color:
                          (_saveMode == SaveMode.updateExisting
                                  ? KeyNestPalette.accent
                                  : KeyNestPalette.primary)
                              .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      _saveMode == SaveMode.updateExisting
                          ? Icons.published_with_changes_rounded
                          : Icons.bookmark_add_rounded,
                      color: _saveMode == SaveMode.updateExisting
                          ? KeyNestPalette.accent
                          : KeyNestPalette.primary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _saveMode == SaveMode.updateExisting
                              ? 'Update Login'
                              : 'Save Login Offer',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        Text(
                          widget.pendingSave.webDomain.isNotEmpty
                              ? widget.pendingSave.webDomain
                              : (widget.pendingSave.packageName.isNotEmpty
                                    ? _formatPackage(
                                        widget.pendingSave.packageName,
                                      )
                                    : 'KeyNest Vault'),
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // Mode toggle (when existing candidates exist)
              if (hasCandidates) ...[
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: isDark
                        ? KeyNestPalette.surfaceContainerDark
                        : KeyNestPalette.surfaceLight,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isDark
                          ? KeyNestPalette.entryBorderDark
                          : KeyNestPalette.entryBorderLight,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildChoiceTab(
                          label: 'Save as New',
                          icon: Icons.add_circle_outline_rounded,
                          isSelected: _saveMode == SaveMode.saveNew,
                          isDark: isDark,
                          onTap: () {
                            setState(() {
                              _saveMode = SaveMode.saveNew;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _buildChoiceTab(
                          label: 'Update Existing',
                          icon: Icons.sync_rounded,
                          isSelected: _saveMode == SaveMode.updateExisting,
                          isDark: isDark,
                          countBadge: _candidates.length > 1
                              ? '${_candidates.length}'
                              : null,
                          onTap: () {
                            setState(() {
                              _saveMode = SaveMode.updateExisting;
                              _selectedCandidate ??= _candidates.first;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 18),

              // Content based on SaveMode
              if (_saveMode == SaveMode.updateExisting) ...[
                Text(
                  _candidates.length > 1
                      ? 'Select which entry to update:'
                      : 'Entry to update:',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 8),

                // Candidates list / card
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const ClampingScrollPhysics(),
                    itemCount: _candidates.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final candidate = _candidates[index];
                      final isSelected = candidate == _selectedCandidate;
                      return InkWell(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _selectedCandidate = candidate;
                            if (candidate.username.isNotEmpty) {
                              _usernameController.text = candidate.username;
                            }
                          });
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? (isDark
                                      ? KeyNestPalette.primaryDark.withValues(
                                          alpha: 0.18,
                                        )
                                      : KeyNestPalette.primaryLight.withValues(
                                          alpha: 0.12,
                                        ))
                                : (isDark
                                      ? KeyNestPalette.surfaceContainerDark
                                      : KeyNestPalette.surfaceLight),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary)
                                  : (isDark
                                        ? KeyNestPalette.entryBorderDark
                                        : KeyNestPalette.entryBorderLight),
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_off_rounded,
                                size: 20,
                                color: isSelected
                                    ? (isDark
                                          ? KeyNestPalette.primaryDark
                                          : KeyNestPalette.primary)
                                    : (isDark
                                          ? KeyNestPalette.textSecondaryDark
                                          : KeyNestPalette.textSecondaryLight),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            candidate.title,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (candidate
                                            .hasExactUsernameMatch) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: KeyNestPalette.accent
                                                  .withValues(alpha: 0.2),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              'Match',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: KeyNestPalette.accent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      candidate.username.isNotEmpty
                                          ? candidate.username
                                          : '(No username)',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? KeyNestPalette.textSecondaryDark
                                            : KeyNestPalette.textSecondaryLight,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${candidate.vaultName} • ${candidate.folderName}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: isDark
                                            ? KeyNestPalette.textSecondaryDark
                                            : KeyNestPalette.textSecondaryLight,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 14),

                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'New Password',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                  ),
                ),
              ] else ...[
                // SAVE AS NEW MODE
                TextField(
                  controller: _titleController,
                  decoration: InputDecoration(
                    labelText: 'Title / Service',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    labelText: 'Username or Email',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Destination Vault & Folder Picker
                _buildDestinationPicker(isDark),
              ],

              // Action Buttons
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSaving ? null : _handleDiscard,
                    child: const Text('Discard'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isSaving ? null : _handleSave,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark
                          ? KeyNestPalette.primaryDark
                          : (_saveMode == SaveMode.updateExisting
                                ? KeyNestPalette.accent
                                : KeyNestPalette.primary),
                      foregroundColor: isDark
                          ? const Color(0xFF00315D)
                          : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    child: _isSaving
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: isDark
                                  ? const Color(0xFF00315D)
                                  : Colors.white,
                            ),
                          )
                        : Text(
                            _saveMode == SaveMode.updateExisting
                                ? 'Update Entry'
                                : 'Save as New',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChoiceTab({
    required String label,
    required IconData icon,
    required bool isSelected,
    required bool isDark,
    required VoidCallback onTap,
    String? countBadge,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? KeyNestPalette.cardDark : Colors.white)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected
                  ? (isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary)
                  : (isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? (isDark ? Colors.white : Colors.black87)
                      : (isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (countBadge != null) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: KeyNestPalette.accent.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  countBadge,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: KeyNestPalette.accent,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDestinationPicker(bool isDark) {
    final file =
        _destinationFile ?? widget.kdbxBloc.openedFilesKdbx.firstOrNull;
    final vaultName = file != null
        ? KeyNestVaultScope.cleanVaultName(widget.kdbxBloc, file)
        : 'Vault';
    final group = _destinationGroup ?? file?.body.rootGroup;
    final folderName = (group == null || group.parent == null)
        ? 'Root Folder'
        : (group.name.get() ?? 'Folder');

    return InkWell(
      onTap: _pickDestination,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isDark
              ? KeyNestPalette.surfaceContainerDark
              : KeyNestPalette.surfaceLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark
                ? KeyNestPalette.entryBorderDark
                : KeyNestPalette.entryBorderLight,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.folder_outlined,
              size: 20,
              color: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.lightIcon,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Destination',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                  Text(
                    '$vaultName • $folderName',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Text(
              'Change',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
