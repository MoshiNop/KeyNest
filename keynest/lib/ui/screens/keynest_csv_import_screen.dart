// ignore_for_file: always_put_control_body_on_new_line, deprecated_member_use, use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/models/keynest_csv_mapping.dart';
import 'package:keynest/services/keynest_import_export_service.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:provider/provider.dart';

enum KeyNestCsvImportMode {
  quick,
  custom,
}

class KeyNestCsvImportScreen extends StatefulWidget {
  const KeyNestCsvImportScreen({
    super.key,
    required this.fileName,
    required this.csvText,
    required this.parsedRows,
    required this.initialDestination,
  });

  final String fileName;
  final String csvText;
  final List<List<String>> parsedRows;
  final KeyNestDestination initialDestination;

  @override
  State<KeyNestCsvImportScreen> createState() => _KeyNestCsvImportScreenState();
}

class _KeyNestCsvImportScreenState extends State<KeyNestCsvImportScreen> {
  late KeyNestDestination _destination;
  KeyNestCsvImportMode _mode = KeyNestCsvImportMode.quick;
  KeyNestImportDuplicateStrategy _duplicateStrategy =
      KeyNestImportDuplicateStrategy.skip;

  late List<String> _headers;
  late List<List<String>> _dataRows;
  late List<KeyNestColumnMapping> _quickMappings;
  late List<KeyNestColumnMapping> _customMappings;

  bool _isImporting = false;
  bool _showSensitive = false;

  @override
  void initState() {
    super.initState();
    _destination = widget.initialDestination;
    _headers = widget.parsedRows.isNotEmpty
        ? widget.parsedRows.first.map((e) => e.trim()).toList()
        : [];
    _dataRows = widget.parsedRows.length > 1
        ? widget.parsedRows.sublist(1)
        : [];

    _quickMappings = KeyNestCsvMappingHelper.autoDetectMappings(_headers);
    // Deep copy for custom mappings so user edits don't mutate quick defaults
    _customMappings = _quickMappings
        .map(
          (m) => KeyNestColumnMapping(
            sourceColumnIndex: m.sourceColumnIndex,
            sourceColumnName: m.sourceColumnName,
            destinationType: m.destinationType,
            standardField: m.standardField,
            customFieldName: m.customFieldName,
          ),
        )
        .toList();
  }

  List<KeyNestColumnMapping> get _activeMappings =>
      _mode == KeyNestCsvImportMode.quick ? _quickMappings : _customMappings;

  String _sampleValueForColumn(int colIdx) {
    for (final row in _dataRows) {
      if (colIdx < row.length && row[colIdx].trim().isNotEmpty) {
        return row[colIdx].trim();
      }
    }
    return '';
  }

  Future<void> _changeDestination() async {
    final newDest = await KeyNestDestinationPickerSheet.show(
      context,
      initialFile: _destination.file,
      initialGroup: _destination.group,
    );
    if (newDest != null && mounted) {
      setState(() {
        _destination = newDest;
      });
    }
  }

  Future<void> _executeImport() async {
    if (_isImporting) return;

    final validation = KeyNestCsvMappingHelper.validateMappings(
      _activeMappings,
    );
    if (!validation.isValid) {
      _showSnack(validation.errors.first, isError: true);
      return;
    }

    final kdbxBloc = context.read<KdbxBloc>();
    if (!kdbxBloc.openedFilesKdbx.contains(_destination.file)) {
      _showSnack('Selected vault is no longer available.', isError: true);
      return;
    }

    setState(() => _isImporting = true);

    try {
      final result = await KeyNestImportExportService.importMappedCsv(
        kdbxBloc: kdbxBloc,
        targetFile: _destination.file,
        targetGroup: _destination.group,
        rows: widget.parsedRows,
        mappings: _activeMappings,
        duplicateStrategy: _duplicateStrategy,
      );

      if (!mounted) return;

      if (result.success) {
        KeyNestVaultScope.instance.setSelectedVault(
          kdbxBloc,
          _destination.file,
        );
        KeyNestVaultScope.instance.notifyScopeChanged();
        Navigator.of(context).pop(result);
      } else {
        _showSnack(result.message ?? 'Import failed.', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnack('Import error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();

    final vaultName = KeyNestVaultScope.cleanVaultName(
      kdbxBloc,
      _destination.file,
    );
    final folderName = _destination.group.name.get() ?? 'Root';

    final validation = KeyNestCsvMappingHelper.validateMappings(
      _activeMappings,
    );
    final previews = KeyNestCsvMappingHelper.previewRows(
      dataRows: _dataRows,
      mappings: _activeMappings,
      maxPreviewCount: 8,
    );

    final readyCount = previews.where((p) => p.isValid).length;
    final issueCount = previews.where((p) => !p.isValid).length;

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Import CSV Spreadsheet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              '${widget.fileName} • ${_dataRows.length} entries',
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
          ],
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              _buildDestinationCard(isDark, vaultName, folderName),
              const SizedBox(height: 16),

              _buildModeSelector(isDark),
              const SizedBox(height: 16),

              if (_mode == KeyNestCsvImportMode.quick)
                _buildQuickImportView(isDark)
              else
                _buildCustomImportView(isDark, validation),

              const SizedBox(height: 20),

              _buildDuplicateStrategySelector(isDark),
              const SizedBox(height: 20),

              _buildPreviewSection(isDark, previews, readyCount, issueCount),
              const SizedBox(height: 90),
            ],
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomBar(isDark, validation),
          ),

          if (_isImporting)
            Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: KeyNestCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Importing and encrypting entries...',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDestinationCard(
    bool isDark,
    String vaultName,
    String folderName,
  ) {
    return KeyNestCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color:
                  (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                      .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.folder_shared_rounded,
              color: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Destination Vault',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$vaultName  •  $folderName',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              side: BorderSide(
                color:
                    (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary)
                        .withValues(alpha: 0.4),
              ),
            ),
            onPressed: _isImporting ? null : _changeDestination,
            child: const Text('Change', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector(bool isDark) {
    final activeColor = isDark
        ? KeyNestPalette.primaryDark
        : KeyNestPalette.primary;
    final activeTextColor = isDark ? const Color(0xFF00315D) : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.surfaceDark
            : KeyNestPalette.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.08),
        ),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: _isImporting
                  ? null
                  : () => setState(() => _mode = KeyNestCsvImportMode.quick),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _mode == KeyNestCsvImportMode.quick
                      ? activeColor
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 16,
                      color: _mode == KeyNestCsvImportMode.quick
                          ? activeTextColor
                          : (isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Quick Import',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: _mode == KeyNestCsvImportMode.quick
                            ? activeTextColor
                            : (isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: _isImporting
                  ? null
                  : () => setState(() => _mode = KeyNestCsvImportMode.custom),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _mode == KeyNestCsvImportMode.custom
                      ? activeColor
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.tune_rounded,
                      size: 16,
                      color: _mode == KeyNestCsvImportMode.custom
                          ? activeTextColor
                          : (isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Custom Mapping',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: _mode == KeyNestCsvImportMode.custom
                            ? activeTextColor
                            : (isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight),
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

  Widget _buildQuickImportView(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: KeyNestPalette.info.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: KeyNestPalette.info.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                color: KeyNestPalette.info,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Quick Import automatically detects headers from Bitwarden, LastPass, KeePass, and generic CSV tables.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'AUTOMATICALLY DETECTED COLUMNS (${_quickMappings.length})',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.6,
            color: isDark
                ? KeyNestPalette.textSecondaryDark
                : KeyNestPalette.textSecondaryLight,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _quickMappings.map((m) {
            final isSkip = m.isSkipped;
            final isCustom = m.isCustomField;
            final Color badgeBg;
            final Color badgeText;

            if (isSkip) {
              badgeBg = Colors.grey.withValues(alpha: 0.2);
              badgeText = Colors.grey;
            } else if (isCustom) {
              badgeBg = KeyNestPalette.warning.withValues(alpha: 0.18);
              badgeText = KeyNestPalette.warning;
            } else {
              badgeBg =
                  (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                      .withValues(alpha: 0.18);
              badgeText = isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary;
            }

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isDark
                    ? KeyNestPalette.surfaceDark
                    : KeyNestPalette.surfaceLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (isDark ? Colors.white : Colors.black).withValues(
                    alpha: 0.08,
                  ),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    m.sourceColumnName,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    size: 11,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      m.effectiveDestinationLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: badgeText,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () =>
                setState(() => _mode = KeyNestCsvImportMode.custom),
            icon: const Icon(Icons.edit_note_rounded, size: 16),
            label: const Text(
              'Customize column assignments →',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCustomImportView(
    bool isDark,
    KeyNestCsvMappingValidation validation,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: KeyNestPalette.info.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: KeyNestPalette.info.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.touch_app_rounded,
                color: KeyNestPalette.info,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Manually map each column to any KeyNest field or create a custom field. Your manual selections override original column names.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        if (!validation.isValid)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: KeyNestPalette.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: KeyNestPalette.error.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: KeyNestPalette.error,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Mapping Conflict / Incomplete Mapping',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: KeyNestPalette.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                for (final err in validation.errors)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '• $err',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? KeyNestPalette.textPrimaryDark
                            : KeyNestPalette.textPrimaryLight,
                      ),
                    ),
                  ),
              ],
            ),
          ),

        if (validation.isValid && validation.warnings.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: KeyNestPalette.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: KeyNestPalette.warning.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final warn in validation.warnings)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        color: KeyNestPalette.warning,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          warn,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),

        Text(
          'COLUMN ASSIGNMENTS (${_customMappings.length})',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.6,
            color: isDark
                ? KeyNestPalette.textSecondaryDark
                : KeyNestPalette.textSecondaryLight,
          ),
        ),
        const SizedBox(height: 8),

        for (int i = 0; i < _customMappings.length; i++)
          _buildColumnMappingCard(i, isDark),
      ],
    );
  }

  Widget _buildColumnMappingCard(int index, bool isDark) {
    final mapping = _customMappings[index];
    final sampleVal = _sampleValueForColumn(mapping.sourceColumnIndex);

    return KeyNestCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: (isDark ? Colors.white : Colors.black).withValues(
                    alpha: 0.08,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Col ${index + 1}',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  mapping.sourceColumnName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (sampleVal.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    'Sample: "$sampleVal"',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          Row(
            children: [
              Text(
                'Map to:',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? KeyNestPalette.surfaceDark
                        : KeyNestPalette.surfaceLight,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (isDark ? Colors.white : Colors.black).withValues(
                        alpha: 0.12,
                      ),
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _getDropdownKey(mapping),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? KeyNestPalette.textPrimaryDark
                            : KeyNestPalette.textPrimaryLight,
                      ),
                      dropdownColor: isDark
                          ? KeyNestPalette.surfaceDark
                          : KeyNestPalette.surfaceLight,
                      items: _buildDestinationDropdownItems(),
                      onChanged: (val) {
                        if (val == null) return;
                        _applyDropdownSelection(mapping, val);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),

          if (mapping.isCustomField) ...[
            const SizedBox(height: 10),
            TextFormField(
              initialValue: mapping.customFieldName ?? mapping.sourceColumnName,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Custom Field Name',
                labelStyle: const TextStyle(fontSize: 12),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                suffixIcon: const Icon(Icons.edit, size: 14),
              ),
              onChanged: (val) {
                setState(() {
                  mapping.customFieldName = val;
                });
              },
            ),
          ],
        ],
      ),
    );
  }

  String _getDropdownKey(KeyNestColumnMapping m) {
    if (m.isSkipped) return '__skip__';
    if (m.isCustomField) return '__custom__';
    if (m.standardField != null) return 'std_${m.standardField!.name}';
    return '__skip__';
  }

  void _applyDropdownSelection(KeyNestColumnMapping mapping, String key) {
    setState(() {
      if (key == '__skip__') {
        mapping.destinationType = KeyNestMappingDestinationType.skip;
        mapping.standardField = null;
      } else if (key == '__custom__') {
        mapping.destinationType = KeyNestMappingDestinationType.customField;
        mapping.standardField = null;
        mapping.customFieldName ??= mapping.sourceColumnName;
      } else if (key.startsWith('std_')) {
        final fieldName = key.substring(4);
        final field = KeyNestStandardField.values.firstWhere(
          (f) => f.name == fieldName,
          orElse: () => KeyNestStandardField.title,
        );
        mapping.destinationType = KeyNestMappingDestinationType.standard;
        mapping.standardField = field;
      }
    });
  }

  List<DropdownMenuItem<String>> _buildDestinationDropdownItems() {
    final items = <DropdownMenuItem<String>>[];

    for (final field in KeyNestStandardField.values) {
      items.add(
        DropdownMenuItem(
          value: 'std_${field.name}',
          child: Text(field.label),
        ),
      );
    }

    items.add(
      const DropdownMenuItem(
        value: '__custom__',
        child: Row(
          children: [
            Icon(
              Icons.add_circle_outline_rounded,
              size: 15,
              color: KeyNestPalette.warning,
            ),
            SizedBox(width: 6),
            Text(
              'Custom Field (User Defined)',
              style: TextStyle(color: KeyNestPalette.warning),
            ),
          ],
        ),
      ),
    );

    items.add(
      const DropdownMenuItem(
        value: '__skip__',
        child: Row(
          children: [
            Icon(Icons.block_rounded, size: 15, color: Colors.grey),
            SizedBox(width: 6),
            Text('Skip (Do not import)', style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );

    return items;
  }

  Widget _buildDuplicateStrategySelector(bool isDark) {
    return KeyNestCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.copy_rounded, size: 16),
              const SizedBox(width: 8),
              Text(
                'DUPLICATE HANDLING',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6,
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<KeyNestImportDuplicateStrategy>(
            value: _duplicateStrategy,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            dropdownColor: isDark
                ? KeyNestPalette.surfaceDark
                : KeyNestPalette.surfaceLight,
            items: const [
              DropdownMenuItem(
                value: KeyNestImportDuplicateStrategy.skip,
                child: Text('Skip duplicate entries (Recommended)'),
              ),
              DropdownMenuItem(
                value: KeyNestImportDuplicateStrategy.update,
                child: Text('Update existing entries with new values'),
              ),
              DropdownMenuItem(
                value: KeyNestImportDuplicateStrategy.keepBoth,
                child: Text('Keep both (Create duplicate records)'),
              ),
            ],
            onChanged: (val) {
              if (val != null) setState(() => _duplicateStrategy = val);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewSection(
    bool isDark,
    List<KeyNestCsvRowPreview> previews,
    int readyCount,
    int issueCount,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'LIVE RECORD PREVIEW',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: _showSensitive ? 'Hide Secrets' : 'Reveal Secrets',
                  icon: Icon(
                    _showSensitive
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    size: 18,
                  ),
                  onPressed: () =>
                      setState(() => _showSensitive = !_showSensitive),
                ),
                Text(
                  _showSensitive ? 'Hide' : 'Reveal',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),

        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (isDark
                        ? KeyNestPalette.successDark
                        : KeyNestPalette.success)
                    .withValues(alpha: isDark ? 0.20 : 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$readyCount Valid Records (Sample)',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? KeyNestPalette.successDark
                      : KeyNestPalette.success,
                ),
              ),
            ),
            if (issueCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: KeyNestPalette.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$issueCount Issues Found',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: KeyNestPalette.warning,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),

        if (previews.isEmpty)
          const Text('No records found in CSV file.')
        else
          for (final p in previews) _buildRowPreviewCard(p, isDark),
      ],
    );
  }

  Widget _buildRowPreviewCard(KeyNestCsvRowPreview preview, bool isDark) {
    return KeyNestCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.white : Colors.black).withValues(
                        alpha: 0.08,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Row #${preview.rowIndex}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    preview.title,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: preview.isValid
                      ? (isDark
                                ? KeyNestPalette.successDark
                                : KeyNestPalette.success)
                            .withValues(alpha: isDark ? 0.20 : 0.15)
                      : KeyNestPalette.error.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  preview.isValid ? 'Valid' : 'Invalid',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: preview.isValid
                        ? (isDark
                              ? KeyNestPalette.successDark
                              : KeyNestPalette.success)
                        : KeyNestPalette.error,
                  ),
                ),
              ),
            ],
          ),
          if (preview.issueReason != null) ...[
            const SizedBox(height: 4),
            Text(
              '⚠️ ${preview.issueReason}',
              style: const TextStyle(
                fontSize: 11,
                color: KeyNestPalette.warning,
              ),
            ),
          ],
          const Divider(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: preview.mappedValues.entries.map((e) {
              final isSensitive =
                  (e.key == 'Password' ||
                  e.key == 'TOTP / 2FA Secret' ||
                  e.key == 'CVC / CVV' ||
                  e.key == 'PIN');
              final displayVal = (isSensitive && !_showSensitive)
                  ? '••••••••'
                  : e.value;

              return RichText(
                text: TextSpan(
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                  ),
                  children: [
                    TextSpan(
                      text: '${e.key}: ',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                    ),
                    TextSpan(
                      text: displayVal.isNotEmpty ? displayVal : '(empty)',
                      style: TextStyle(
                        fontStyle: displayVal.isEmpty
                            ? FontStyle.italic
                            : FontStyle.normal,
                        color: displayVal.isEmpty ? Colors.grey : null,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(
    bool isDark,
    KeyNestCsvMappingValidation validation,
  ) {
    final canImport = validation.isValid && !_isImporting;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.surfaceDark
            : KeyNestPalette.surfaceLight,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            offset: const Offset(0, -2),
            blurRadius: 8,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _isImporting
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                  foregroundColor: isDark
                      ? const Color(0xFF00315D)
                      : Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: canImport ? _executeImport : null,
                icon: _isImporting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_download_done_rounded, size: 18),
                label: Text(
                  _isImporting
                      ? 'Importing...'
                      : 'Import ${_dataRows.length} Entries',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
