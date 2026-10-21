// ignore_for_file: always_put_control_body_on_new_line, implementation_imports
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_entry.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/duplicate_detector.dart';
import 'package:keynest/utils/platform.dart';
import 'package:provider/provider.dart';

class KeyNestDuplicatesScreen extends StatefulWidget {
  const KeyNestDuplicatesScreen({super.key});

  static Route<void> route() {
    if (KeyNestPlatform.isDesktopOrWeb) {
      return KeyNestDesktopDialogRoute<void>(
        settings: const RouteSettings(name: '/duplicates'),
        maxWidth: 540,
        maxHeight: 620,
        builder: (context) => const KeyNestDuplicatesScreen(),
      );
    }
    return MaterialPageRoute(
      settings: const RouteSettings(name: '/duplicates'),
      builder: (context) => const KeyNestDuplicatesScreen(),
    );
  }

  @override
  State<KeyNestDuplicatesScreen> createState() =>
      _KeyNestDuplicatesScreenState();
}

class _KeyNestDuplicatesScreenState extends State<KeyNestDuplicatesScreen> {
  bool _isLoading = false;
  bool _isScanning = false;
  double _scanProgress = 0.0;
  List<DuplicateCluster> _clusters = const [];
  KdbxFile? _scannedFile;
  int _scanSessionId = 0;
  final Set<KdbxUuid> _selectedDuplicateUuids = <KdbxUuid>{};
  KdbxFile? _selectedVaultFile;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    if (openedFiles.isNotEmpty) {
      final defaultVault =
          KeyNestVaultScope.instance.getSelectedVault(kdbxBloc) ??
          openedFiles.first;
      final targetFile =
          (_selectedVaultFile != null &&
              openedFiles.contains(_selectedVaultFile))
          ? _selectedVaultFile!
          : defaultVault;
      if (_scannedFile != targetFile && !_isScanning) {
        _selectedDuplicateUuids.clear();
        _startScan(targetFile);
      }
    }
  }

  Future<void> _startScan(KdbxFile file) async {
    final currentSession = ++_scanSessionId;
    setState(() {
      _isScanning = true;
      _scanProgress = 0.0;
      _scannedFile = file;
    });

    try {
      final clusters =
          await KeyNestDuplicateDetector.findDuplicatesInVaultAsync(
            file,
            onProgress: (progress) {
              if (mounted && _scanSessionId == currentSession) {
                setState(() {
                  _scanProgress = progress;
                });
              }
            },
          );
      if (mounted && _scanSessionId == currentSession) {
        setState(() {
          _clusters = clusters;
          _isScanning = false;
          _scanProgress = 1.0;
        });
      }
    } catch (e) {
      if (mounted && _scanSessionId == currentSession) {
        setState(() {
          _isScanning = false;
        });
        _showSnack('Scan failed: $e', isError: true);
      }
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 2000),
          backgroundColor: isError
              ? KeyNestPalette.error
              : KeyNestPalette.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
  }

  Future<void> _deleteDuplicate(KdbxEntry entry, KdbxFile file) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final confirmed = await DialogUtils.showConfirmDialog(
      context: context,
      params: ConfirmDialogParams(
        title: 'Delete Duplicate?',
        content: 'Move "${entry.label ?? 'Item'}" to the Recycle Bin?',
        positiveButtonText: 'Move to Trash',
      ),
    );
    if (!confirmed) return;

    setState(() => _isLoading = true);
    try {
      file.deleteEntry(entry);
      await kdbxBloc.saveFile(file);
      _selectedDuplicateUuids.remove(entry.uuid);
      if (mounted) {
        _showSnack('Moved duplicate to Trash');
        await _startScan(file);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Failed to delete duplicate: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteDuplicatesBatch(
    List<KdbxEntry> entriesToDelete,
    KdbxFile file, {
    String? title,
  }) async {
    if (entriesToDelete.isEmpty) return;

    final kdbxBloc = context.read<KdbxBloc>();
    final count = entriesToDelete.length;
    final confirmed = await DialogUtils.showConfirmDialog(
      context: context,
      params: ConfirmDialogParams(
        title: title ?? 'Delete $count Duplicate${count > 1 ? 's' : ''}?',
        content:
            'Move $count selected duplicate item${count > 1 ? 's' : ''} to the Recycle Bin?\n\n'
            'Primary credentials will remain completely safe and untouched.',
        positiveButtonText: 'Delete Duplicates',
      ),
    );
    if (!confirmed) return;

    setState(() => _isLoading = true);
    try {
      for (final entry in entriesToDelete) {
        file.deleteEntry(entry);
        _selectedDuplicateUuids.remove(entry.uuid);
      }
      await kdbxBloc.saveFile(file);
      if (mounted) {
        _showSnack('Moved $count duplicate${count > 1 ? 's' : ''} to Trash');
        await _startScan(file);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Failed to delete duplicates: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _mergeDuplicate(
    KdbxEntry primary,
    KdbxEntry duplicate,
    KdbxFile file,
  ) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final confirmed = await DialogUtils.showConfirmDialog(
      context: context,
      params: ConfirmDialogParams(
        title: 'Merge Items?',
        content:
            'Merge "${duplicate.label ?? 'Duplicate'}" into "${primary.label ?? 'Primary'}". '
            'Unique notes and custom fields will be copied to the primary item, and the duplicate will be moved to Trash.',
        positiveButtonText: 'Merge Items',
      ),
    );
    if (!confirmed) return;

    setState(() => _isLoading = true);
    try {
      // Archive primary's state before merging
      primary.history.add(
        primary.cloneInto(
          primary.parent ?? file.body.rootGroup,
          toHistoryEntry: true,
        ),
      );

      // Copy any non-empty fields from duplicate that are empty in primary;
      // capture any conflicting alternate values so they are not lost.
      final conflictingFields = <String>[];
      for (final s in duplicate.stringEntries) {
        final existingVal = primary.getString(s.key)?.getText()?.trim() ?? '';
        final dupVal = s.value?.getText()?.trim() ?? '';
        if (existingVal.isEmpty && dupVal.isNotEmpty) {
          primary.setString(s.key, s.value);
        } else if (existingVal.isNotEmpty &&
            dupVal.isNotEmpty &&
            existingVal != dupVal &&
            s.key.key != 'Notes' &&
            s.key.key != KdbxKeyCommon.PASSWORD.key) {
          conflictingFields.add('${s.key.key}: $dupVal');
        }
      }

      // Merge notes
      final primaryNotes =
          primary.getString(KdbxKey('Notes'))?.getText()?.trim() ?? '';
      final dupNotes =
          duplicate.getString(KdbxKey('Notes'))?.getText()?.trim() ?? '';
      String combinedNotes = primaryNotes;
      if (dupNotes.isNotEmpty && !primaryNotes.contains(dupNotes)) {
        combinedNotes = combinedNotes.isEmpty
            ? dupNotes
            : '$combinedNotes\n\n[Merged Notes]:\n$dupNotes';
      }
      if (conflictingFields.isNotEmpty) {
        final conflictBlock =
            '[Merged Alternative Values from Duplicate]:\n${conflictingFields.join('\n')}';
        combinedNotes = combinedNotes.isEmpty
            ? conflictBlock
            : '$combinedNotes\n\n$conflictBlock';
      }
      if (combinedNotes != primaryNotes) {
        primary.setString(KdbxKey('Notes'), PlainValue(combinedNotes));
      }

      // Preserve binary attachments from duplicate
      for (final binEntry in duplicate.binaryEntries) {
        if (primary.getBinary(binEntry.key) == null) {
          primary.file.ctx.addBinary(binEntry.value);
          primary.createBinary(
            isProtected: binEntry.value.isProtected,
            name: binEntry.key.key,
            bytes: binEntry.value.value,
          );
        }
      }

      // Move duplicate to Trash
      file.deleteEntry(duplicate);
      _selectedDuplicateUuids.remove(duplicate.uuid);

      await kdbxBloc.saveFile(file);
      if (mounted) {
        _showSnack('Merged successfully!');
        await _startScan(file);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Failed to merge: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;

    if (openedFiles.isEmpty) {
      return Scaffold(
        backgroundColor: isDark
            ? KeyNestPalette.bgDark
            : KeyNestPalette.bgLight,
        appBar: AppBar(title: const Text('Find Duplicates')),
        body: const Center(
          child: Text('No active vault open.'),
        ),
      );
    }

    final defaultVault =
        KeyNestVaultScope.instance.getSelectedVault(kdbxBloc) ??
        openedFiles.first;
    final activeFile =
        (_selectedVaultFile != null && openedFiles.contains(_selectedVaultFile))
        ? _selectedVaultFile!
        : defaultVault;

    // Trigger initial scan if vault changed externally
    if (_scannedFile != activeFile && !_isScanning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scannedFile != activeFile && !_isScanning) {
          _selectedDuplicateUuids.clear();
          _startScan(activeFile);
        }
      });
    }

    final clusters = _clusters;

    // Collect all duplicates across all clusters
    final allDuplicates = <KdbxEntry>[];
    for (final c in clusters) {
      allDuplicates.addAll(c.duplicates);
    }

    final allDuplicateUuids = allDuplicates.map((e) => e.uuid).toSet();
    final isAllSelected =
        allDuplicates.isNotEmpty &&
        allDuplicateUuids.every(_selectedDuplicateUuids.contains);

    // Filter selected entries that currently exist
    final selectedEntries = allDuplicates
        .where((e) => _selectedDuplicateUuids.contains(e.uuid))
        .toList();

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: openedFiles.length <= 1
            ? const Text('Find Duplicates')
            : DropdownButtonHideUnderline(
                child: DropdownButton<KdbxFile>(
                  value: activeFile,
                  dropdownColor: isDark
                      ? KeyNestPalette.cardDark
                      : Colors.white,
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                  items: openedFiles.map((file) {
                    final name = file.body.meta.databaseName.get()?.trim();
                    final displayName = (name != null && name.isNotEmpty)
                        ? name
                        : 'Vault ${openedFiles.indexOf(file) + 1}';
                    return DropdownMenuItem<KdbxFile>(
                      value: file,
                      child: Text(
                        displayName,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    );
                  }).toList(),
                  onChanged: (file) {
                    if (file != null && file != _selectedVaultFile) {
                      setState(() {
                        _selectedVaultFile = file;
                        _selectedDuplicateUuids.clear();
                      });
                      _startScan(file);
                    }
                  },
                ),
              ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          if (allDuplicates.isNotEmpty) ...[
            TextButton.icon(
              icon: Icon(
                isAllSelected
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
                size: 18,
              ),
              label: Text(isAllSelected ? 'Deselect All' : 'Select All'),
              onPressed: () {
                setState(() {
                  if (isAllSelected) {
                    _selectedDuplicateUuids.clear();
                  } else {
                    _selectedDuplicateUuids.addAll(allDuplicateUuids);
                  }
                });
              },
            ),
            IconButton(
              icon: const Icon(
                Icons.delete_sweep_rounded,
                color: KeyNestPalette.error,
              ),
              tooltip: 'Delete All Duplicates',
              onPressed: () => _deleteDuplicatesBatch(
                allDuplicates,
                activeFile,
                title: 'Delete All ${allDuplicates.length} Duplicates?',
              ),
            ),
          ],
          if (KeyNestPlatform.isDesktopOrWeb)
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
        ],
      ),
      bottomNavigationBar: selectedEntries.isNotEmpty
          ? Container(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                MediaQuery.of(context).padding.bottom + 12,
              ),
              decoration: BoxDecoration(
                color: isDark ? KeyNestPalette.cardDark : Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                              .withValues(alpha: isDark ? 0.20 : 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${selectedEntries.length} selected',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => setState(_selectedDuplicateUuids.clear),
                    child: const Text('Clear'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: KeyNestPalette.error,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: Text('Delete Selected (${selectedEntries.length})'),
                    onPressed: () => _deleteDuplicatesBatch(
                      selectedEntries,
                      activeFile,
                      title:
                          'Delete ${selectedEntries.length} Selected Duplicates?',
                    ),
                  ),
                ],
              ),
            )
          : null,
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                color: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
              ),
            )
          : _isScanning && _clusters.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _scanProgress > 0
                        ? 'Scanning vault for duplicates (${(_scanProgress * 100).toInt()}%)...'
                        : 'Scanning vault for duplicates...',
                    style: TextStyle(
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                ],
              ),
            )
          : _clusters.isEmpty
          ? _buildEmptyState(context, isDark)
          : Column(
              children: [
                if (_isScanning)
                  LinearProgressIndicator(
                    value: _scanProgress > 0 ? _scanProgress : null,
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation(
                      isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    children: [
                      // Summary Banner with quick actions
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: KeyNestPalette.warning.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: KeyNestPalette.warning.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.copy_all_rounded,
                                  color: KeyNestPalette.warning,
                                  size: 28,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${clusters.length} Duplicate Group${clusters.length > 1 ? 's' : ''} (${allDuplicates.length} Total Duplicates)',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Select duplicates to remove them in batch or delete all duplicates at once while preserving primary entries.',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: isDark
                                              ? KeyNestPalette.textSecondaryDark
                                              : KeyNestPalette
                                                    .textSecondaryLight,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: KeyNestPalette.error,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.delete_sweep_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    'Delete All Duplicates (${allDuplicates.length})',
                                  ),
                                  onPressed: () => _deleteDuplicatesBatch(
                                    allDuplicates,
                                    activeFile,
                                    title:
                                        'Delete All ${allDuplicates.length} Duplicates?',
                                  ),
                                ),
                                if (selectedEntries.isNotEmpty)
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: KeyNestPalette.error,
                                      side: const BorderSide(
                                        color: KeyNestPalette.error,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 10,
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 18,
                                    ),
                                    label: Text(
                                      'Delete Selected (${selectedEntries.length})',
                                    ),
                                    onPressed: () => _deleteDuplicatesBatch(
                                      selectedEntries,
                                      activeFile,
                                      title:
                                          'Delete ${selectedEntries.length} Selected Duplicates?',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Clusters list
                      ...clusters.map((cluster) {
                        return _buildClusterCard(
                          context: context,
                          cluster: cluster,
                          file: activeFile,
                          isDark: isDark,
                        );
                      }),
                      const SizedBox(height: 48),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: KeyNestSurfaceCard(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isDark
                          ? KeyNestTokens.darkSuccess
                          : KeyNestTokens.lightSuccess)
                      .withValues(alpha: isDark ? 0.20 : 0.12),
                  border: Border.all(
                    color: (isDark
                            ? KeyNestTokens.darkSuccess
                            : KeyNestTokens.lightSuccess)
                        .withValues(alpha: isDark ? 0.40 : 0.25),
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.check_circle_rounded,
                    color: isDark
                        ? KeyNestTokens.darkSuccess
                        : KeyNestTokens.lightSuccess,
                    size: 44,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'No Duplicates Found',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? KeyNestTokens.textPrimaryDark
                      : KeyNestTokens.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'All entries in your vault have distinct credentials and website destinations.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark
                      ? KeyNestTokens.textSecondaryDark
                      : KeyNestTokens.textSecondaryLight,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClusterCard({
    required BuildContext context,
    required DuplicateCluster cluster,
    required KdbxFile file,
    required bool isDark,
  }) {
    final textPrimary = isDark
        ? KeyNestTokens.textPrimaryDark
        : KeyNestTokens.textPrimaryLight;
    final textSecondary = isDark
        ? KeyNestTokens.textSecondaryDark
        : KeyNestTokens.textSecondaryLight;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: KeyNestSurfaceCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Reason Tag and Group Actions
            LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 330;
                if (isNarrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: KeyNestPalette.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          cluster.reason,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: KeyNestPalette.warning,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${cluster.duplicates.length + 1} items',
                            style: TextStyle(
                              fontSize: 12,
                              color: textSecondary,
                            ),
                          ),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: KeyNestPalette.error,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(
                              Icons.delete_sweep_outlined,
                              size: 16,
                            ),
                            label: const Text(
                              'Delete Group',
                              style: TextStyle(fontSize: 11),
                            ),
                            onPressed: () => _deleteDuplicatesBatch(
                              cluster.duplicates,
                              file,
                              title:
                                  'Delete ${cluster.duplicates.length} Duplicates in Group?',
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: KeyNestPalette.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          cluster.reason,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: KeyNestPalette.warning,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${cluster.duplicates.length + 1} items',
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: KeyNestPalette.error,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                      label: const Text(
                        'Delete Group',
                        style: TextStyle(fontSize: 11),
                      ),
                      onPressed: () => _deleteDuplicatesBatch(
                        cluster.duplicates,
                        file,
                        title:
                            'Delete ${cluster.duplicates.length} Duplicates in Group?',
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),

            // Primary Entry (Protected from deletion)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? KeyNestPalette.surfaceContainerDark
                    : KeyNestPalette.bgLight,
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
                    Icons.star_rounded,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.lightIcon,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                cluster.primaryEntry.label ?? 'Untitled',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: textPrimary,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary)
                                        .withValues(
                                          alpha: isDark ? 0.20 : 0.12,
                                        ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Primary (Kept)',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (cluster.primaryEntry
                                .getString(KdbxKeyCommon.USER_NAME)
                                ?.getText()
                                ?.isNotEmpty ==
                            true)
                          Text(
                            cluster.primaryEntry
                                    .getString(KdbxKeyCommon.USER_NAME)
                                    ?.getText() ??
                                '',
                            style: TextStyle(
                              fontSize: 12,
                              color: textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                    tooltip: 'View Primary Item',
                    onPressed: () {
                      Navigator.of(context).push(
                        EntryDetailsScreen.route(entry: cluster.primaryEntry),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Duplicates with individual checkboxes and action buttons
            ...cluster.duplicates.map((dup) {
              final isSelected = _selectedDuplicateUuids.contains(dup.uuid);
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? (isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary)
                            .withValues(alpha: isDark ? 0.20 : 0.08)
                      : (isDark ? KeyNestPalette.surfaceDark : Colors.white),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary)
                        : (isDark
                              ? KeyNestPalette.entryBorderDark
                              : KeyNestPalette.entryBorderLight),
                  ),
                ),
                child: Row(
                  children: [
                    Checkbox(
                      value: isSelected,
                      activeColor: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      onChanged: (checked) {
                        setState(() {
                          if (checked == true) {
                            _selectedDuplicateUuids.add(dup.uuid);
                          } else {
                            _selectedDuplicateUuids.remove(dup.uuid);
                          }
                        });
                      },
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            if (isSelected) {
                              _selectedDuplicateUuids.remove(dup.uuid);
                            } else {
                              _selectedDuplicateUuids.add(dup.uuid);
                            }
                          });
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              dup.label ?? 'Untitled',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: textPrimary,
                                fontSize: 14,
                              ),
                            ),
                            if (dup
                                    .getString(KdbxKeyCommon.USER_NAME)
                                    ?.getText()
                                    ?.isNotEmpty ==
                                true)
                              Text(
                                dup
                                        .getString(KdbxKeyCommon.USER_NAME)
                                        ?.getText() ??
                                    '',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: textSecondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.merge_type_rounded, size: 18),
                      color: KeyNestPalette.info,
                      tooltip: 'Merge into Primary',
                      onPressed: () =>
                          _mergeDuplicate(cluster.primaryEntry, dup, file),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      color: KeyNestPalette.error,
                      tooltip: 'Delete Duplicate',
                      onPressed: () => _deleteDuplicate(dup, file),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
