// ignore_for_file: use_build_context_synchronously, always_put_control_body_on_new_line, unawaited_futures, deprecated_member_use
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/keynest_vault_merge_engine.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/keynest_vault_manager_screen.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:provider/provider.dart';

/// Dedicated Vault Merge screen accessible from Settings.
class KeyNestMergeVaultsScreen extends StatefulWidget {
  const KeyNestMergeVaultsScreen({super.key});

  static Route<void> route() {
    if (KeyNestPlatform.isDesktopOrWeb) {
      return KeyNestDesktopDialogRoute<void>(
        settings: const RouteSettings(name: '/merge_vaults'),
        maxWidth: 540,
        maxHeight: 620,
        builder: (_) => const KeyNestMergeVaultsScreen(),
      );
    }
    return MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/merge_vaults'),
      builder: (_) => const KeyNestMergeVaultsScreen(),
    );
  }

  @override
  State<KeyNestMergeVaultsScreen> createState() =>
      _KeyNestMergeVaultsScreenState();
}

class _KeyNestMergeVaultsScreenState extends State<KeyNestMergeVaultsScreen> {
  KdbxFile? _selectedDestinationVault;
  final Set<KdbxFile> _selectedSourceVaults = {};
  VaultMergeDuplicateStrategy _strategy =
      VaultMergeDuplicateStrategy.smartMerge;
  bool _closeSourceVaultsAfterMerge = false;
  bool _isMerging = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final kdbxBloc = context.watch<KdbxBloc>();
    final vaults = kdbxBloc.openedFilesKdbx;

    // Initialize destination if not yet set
    if (_selectedDestinationVault == null && vaults.isNotEmpty) {
      _selectedDestinationVault = vaults.first;
    }

    // Default select all other vaults as sources if none selected yet
    if (_selectedSourceVaults.isEmpty && vaults.length > 1) {
      _selectedSourceVaults.addAll(
        vaults.where((v) => v != _selectedDestinationVault),
      );
    }
  }

  String _getVaultName(KdbxFile file, KdbxBloc kdbxBloc) {
    return KeyNestVaultScope.cleanVaultName(kdbxBloc, file);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedVaults = kdbxBloc.openedFilesKdbx;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Merge KDBX Vaults'),
        actions: [
          if (KeyNestPlatform.isDesktopOrWeb)
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
        ],
      ),
      body: _isMerging
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Merging vaults...',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Preserving folders, attachments, and entry fields',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            )
          : openedVaults.length < 2
          ? _buildInsufficientVaultsView(context, isDark, openedVaults.length)
          : ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              children: [
                // Overview banner
                _buildOverviewCard(isDark),
                const SizedBox(height: 20),

                // SECTION 1: Destination Vault
                _buildSectionHeader(
                  '1. DESTINATION VAULT (TARGET)',
                  'The vault that will receive all merged folders and entries.',
                  Icons.file_download_rounded,
                  isDark,
                ),
                const SizedBox(height: 8),
                _buildDestinationSelector(
                  context,
                  isDark,
                  openedVaults,
                  kdbxBloc,
                ),
                const SizedBox(height: 24),

                // SECTION 2: Source Vaults
                _buildSectionHeader(
                  '2. SOURCE VAULTS (TO MERGE FROM)',
                  'Select the vaults whose folders and items will be merged into destination.',
                  Icons.file_upload_rounded,
                  isDark,
                ),
                const SizedBox(height: 8),
                _buildSourceVaultsSelector(
                  context,
                  isDark,
                  openedVaults,
                  kdbxBloc,
                ),
                const SizedBox(height: 24),

                // SECTION 3: Duplicate & Conflict Strategy
                _buildSectionHeader(
                  '3. CONFLICT & DUPLICATE STRATEGY',
                  'How to handle entries with identical titles, credentials, or folders.',
                  Icons.alt_route_rounded,
                  isDark,
                ),
                const SizedBox(height: 8),
                _buildStrategySelector(isDark),
                const SizedBox(height: 24),

                // SECTION 4: Source Vault Preservation
                _buildSectionHeader(
                  '4. SOURCE VAULT PRESERVATION',
                  'Source vaults are never modified or deleted.',
                  Icons.security_rounded,
                  isDark,
                ),
                const SizedBox(height: 8),
                _buildOptionsCard(isDark),
                const SizedBox(height: 24),

                // SECTION 5: Summary & Merge Button
                _buildSummaryCard(isDark, kdbxBloc),
                const SizedBox(height: 16),
                KeyNestGlassButton(
                  text: 'Start Vault Merge',
                  icon: Icons.merge_type_rounded,
                  tone: KeyNestSemanticTone.primary,
                  fullWidth: true,
                  onClick:
                      _selectedSourceVaults.isEmpty ||
                          _selectedDestinationVault == null
                      ? null
                      : () => _executeMerge(context, kdbxBloc),
                ),
                const SizedBox(height: 36),
              ],
            ),
    );
  }

  Widget _buildInsufficientVaultsView(
    BuildContext context,
    bool isDark,
    int openedCount,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestTokens.primary)
                        .withValues(alpha: isDark ? 0.20 : 0.1),
              ),
              child: Icon(
                Icons.merge_type_rounded,
                size: 56,
                color: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestTokens.primary,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'At Least 2 Opened Vaults Needed',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Currently you have $openedCount vault(s) open. '
              'To merge KDBX files, please open or create another vault first.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            KeyNestGlassButton(
              text: 'Open Vault Manager',
              icon: Icons.folder_shared_rounded,
              tone: KeyNestSemanticTone.primary,
              onClick: () {
                Navigator.of(context).push(KeyNestVaultManagerScreen.route());
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewCard(bool isDark) {
    return KeyNestSurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Standard KDBX Interoperability',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  'Vault merge replicates native folder trees, entries, attachments, and protected fields into the target vault. '
                  'Source vaults remain untouched.',
                  style: TextStyle(
                    fontSize: 12,
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
    );
  }

  Widget _buildSectionHeader(
    String title,
    String subtitle,
    IconData icon,
    bool isDark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(left: 22),
          child: Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDestinationSelector(
    BuildContext context,
    bool isDark,
    List<KdbxFile> vaults,
    KdbxBloc kdbxBloc,
  ) {
    return KeyNestSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: vaults.map((vault) {
          final isSelected = _selectedDestinationVault == vault;
          final name = _getVaultName(vault, kdbxBloc);
          final entriesCount = vault.body.rootGroup
              .getAllEntries()
              .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
              .length;
          final foldersCount = vault.body.rootGroup
              .getAllGroups()
              .where(
                (g) =>
                    g != vault.body.rootGroup &&
                    !KeyNestItemTypeHelper.isTrashOrRecycleBin(g),
              )
              .length;

          return RadioListTile<KdbxFile>(
            value: vault,
            groupValue: _selectedDestinationVault,
            activeColor: isDark
                ? KeyNestPalette.primaryDark
                : KeyNestPalette.primary,
            title: Text(
              name,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            subtitle: Text(
              '$entriesCount items • $foldersCount folders',
              style: const TextStyle(fontSize: 12),
            ),
            secondary: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected
                    ? (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary)
                          .withValues(alpha: isDark ? 0.20 : 0.15)
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.archive_rounded,
                color: isSelected
                    ? (isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary)
                    : Colors.grey,
                size: 20,
              ),
            ),
            onChanged: (newDest) {
              if (newDest != null) {
                setState(() {
                  _selectedDestinationVault = newDest;
                  _selectedSourceVaults.remove(newDest);
                });
              }
            },
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSourceVaultsSelector(
    BuildContext context,
    bool isDark,
    List<KdbxFile> vaults,
    KdbxBloc kdbxBloc,
  ) {
    final candidateSources = vaults
        .where((v) => v != _selectedDestinationVault)
        .toList();

    return KeyNestSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Text(
                  '${_selectedSourceVaults.length} of ${candidateSources.length} selected',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    setState(() {
                      if (_selectedSourceVaults.length ==
                          candidateSources.length) {
                        _selectedSourceVaults.clear();
                      } else {
                        _selectedSourceVaults.clear();
                        _selectedSourceVaults.addAll(candidateSources);
                      }
                    });
                  },
                  child: Text(
                    _selectedSourceVaults.length == candidateSources.length
                        ? 'Deselect All'
                        : 'Select All',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...candidateSources.map((sourceVault) {
            final isChecked = _selectedSourceVaults.contains(sourceVault);
            final name = _getVaultName(sourceVault, kdbxBloc);
            final entriesCount = sourceVault.body.rootGroup
                .getAllEntries()
                .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
                .length;
            final foldersCount = sourceVault.body.rootGroup
                .getAllGroups()
                .where(
                  (g) =>
                      g != sourceVault.body.rootGroup &&
                      !KeyNestItemTypeHelper.isTrashOrRecycleBin(g),
                )
                .length;

            return CheckboxListTile(
              value: isChecked,
              activeColor: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              title: Text(
                name,
                style: TextStyle(
                  fontWeight: isChecked ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              subtitle: Text(
                '$entriesCount items • $foldersCount folders',
                style: const TextStyle(fontSize: 12),
              ),
              secondary: const Icon(
                Icons.folder_shared_rounded,
                color: KeyNestPalette.accent,
                size: 20,
              ),
              onChanged: (checked) {
                setState(() {
                  if (checked == true) {
                    _selectedSourceVaults.add(sourceVault);
                  } else {
                    _selectedSourceVaults.remove(sourceVault);
                  }
                });
              },
            );
          }),
        ],
      ),
    );
  }

  Widget _buildStrategySelector(bool isDark) {
    return KeyNestSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          RadioListTile<VaultMergeDuplicateStrategy>(
            value: VaultMergeDuplicateStrategy.smartMerge,
            groupValue: _strategy,
            activeColor: isDark
                ? KeyNestPalette.primaryDark
                : KeyNestPalette.primary,
            title: const Text(
              'Smart Merge (Recommended)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: const Text(
              'Skips exact duplicates. For modified entries, keeps newer revision and archives older to history.',
              style: TextStyle(fontSize: 12),
            ),
            onChanged: (val) => setState(() => _strategy = val!),
          ),
          const Divider(height: 1),
          RadioListTile<VaultMergeDuplicateStrategy>(
            value: VaultMergeDuplicateStrategy.keepAllDuplicate,
            groupValue: _strategy,
            activeColor: isDark
                ? KeyNestPalette.primaryDark
                : KeyNestPalette.primary,
            title: const Text(
              'Keep Everything (Duplicate-Safe)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: const Text(
              'Never overwrites. Conflicting entries are cloned with "(Merged)" suffix so all versions exist.',
              style: TextStyle(fontSize: 12),
            ),
            onChanged: (val) => setState(() => _strategy = val!),
          ),
          const Divider(height: 1),
          RadioListTile<VaultMergeDuplicateStrategy>(
            value: VaultMergeDuplicateStrategy.skipDuplicates,
            groupValue: _strategy,
            activeColor: isDark
                ? KeyNestPalette.primaryDark
                : KeyNestPalette.primary,
            title: const Text('Skip Conflicting Entries'),
            subtitle: const Text(
              'Only imports entries that do not already exist in destination vault.',
              style: TextStyle(fontSize: 12),
            ),
            onChanged: (val) => setState(() => _strategy = val!),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionsCard(bool isDark) {
    return KeyNestSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          const ListTile(
            leading: Icon(
              Icons.check_circle_rounded,
              color: KeyNestPalette.success,
            ),
            title: Text(
              'Source vaults preserved intact',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Source KDBX files on disk remain completely unmodified.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const Divider(height: 1),
          SwitchListTile(
            value: _closeSourceVaultsAfterMerge,
            activeColor: isDark
                ? KeyNestPalette.primaryDark
                : KeyNestPalette.primary,
            title: const Text(
              'Close source vaults after merge',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: const Text(
              'Removes source vaults from the active session after merging into target.',
              style: TextStyle(fontSize: 12),
            ),
            onChanged: (val) =>
                setState(() => _closeSourceVaultsAfterMerge = val),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(bool isDark, KdbxBloc kdbxBloc) {
    final destName = _selectedDestinationVault != null
        ? _getVaultName(_selectedDestinationVault!, kdbxBloc)
        : 'None';
    final sourceNames = _selectedSourceVaults
        .map((s) => _getVaultName(s, kdbxBloc))
        .join(', ');
    final totalSourceItems = _selectedSourceVaults.fold<int>(
      0,
      (sum, v) =>
          sum +
          v.body.rootGroup
              .getAllEntries()
              .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
              .length,
    );

    return KeyNestSurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.preview_rounded,
                size: 18,
                color: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
              ),
              const SizedBox(width: 8),
              const Text(
                'Merge Preview Summary',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _summaryRow('Destination:', destName, isDark, isHighlight: true),
          const SizedBox(height: 6),
          _summaryRow(
            'Source Vaults (${_selectedSourceVaults.length}):',
            sourceNames.isNotEmpty ? sourceNames : 'None selected',
            isDark,
          ),
          const SizedBox(height: 6),
          _summaryRow(
            'Total Items to Merge:',
            '$totalSourceItems items across ${_selectedSourceVaults.length} vaults',
            isDark,
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value,
    bool isDark, {
    bool isHighlight = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isHighlight ? FontWeight.bold : FontWeight.w500,
              color: isHighlight
                  ? (isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary)
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _executeMerge(BuildContext context, KdbxBloc kdbxBloc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final isDarkDialog = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          title: const Text('Confirm Vault Merge'),
          content: Text(
            'Merge ${_selectedSourceVaults.length} vault(s) into '
            '"${_getVaultName(_selectedDestinationVault!, kdbxBloc)}"?\n\n'
            'All folder hierarchies and entries will be safely combined according to the selected strategy.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isDarkDialog
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                foregroundColor: isDarkDialog
                    ? const Color(0xFF00315D)
                    : Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                'Merge Now',
                style: TextStyle(
                  color: isDarkDialog ? const Color(0xFF00315D) : Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isMerging = true);

    final result = await KeyNestVaultMergeEngine.mergeVaults(
      sourceVaults: _selectedSourceVaults.toList(),
      destinationVault: _selectedDestinationVault!,
      kdbxBloc: kdbxBloc,
      duplicateStrategy: _strategy,
      closeSourceVaultsAfterMerge: _closeSourceVaultsAfterMerge,
    );

    if (!mounted) return;
    setState(() => _isMerging = false);

    if (result.success) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: KeyNestPalette.success),
              SizedBox(width: 8),
              Text('Merge Successful'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Successfully merged into "${_getVaultName(_selectedDestinationVault!, kdbxBloc)}":',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              _statRow('New Entries Added', '${result.newEntriesAdded}'),
              _statRow('Existing Entries Updated', '${result.entriesUpdated}'),
              _statRow(
                'Duplicates Handled / Skipped',
                '${result.duplicatesSkipped}',
              ),
              _statRow('Folders Created', '${result.foldersCreated}'),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).pop();
              },
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } else {
      DialogUtils.showErrorDialog(
        context,
        'Merge Failed',
        result.errorMessage ?? 'An error occurred during merge.',
      );
    }
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
