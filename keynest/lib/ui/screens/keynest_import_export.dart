import 'dart:typed_data';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_import_export_service.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/keynest_csv_import_screen.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:keynest/ui/widgets/keynest_export_options_sheet.dart';
import 'package:keynest/ui/widgets/password_input_field.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/key_file_handler.dart';
import 'package:keynest/utils/platform.dart';
import 'package:provider/provider.dart';

class KeyNestImportExportScreen extends StatefulWidget {
  const KeyNestImportExportScreen({super.key});

  static Route<void> route() => MaterialPageRoute(
    settings: const RouteSettings(name: '/keynest/import_export'),
    builder: (context) => const KeyNestImportExportScreen(),
  );

  @override
  State<KeyNestImportExportScreen> createState() =>
      _KeyNestImportExportScreenState();
}

class _KeyNestImportExportScreenState extends State<KeyNestImportExportScreen> {
  bool _isLoading = false;
  String? _statusMessage;

  Future<KeyNestDestination?> _selectImportDestination() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    if (openedFiles.isEmpty) {
      _showSnack(
        'Please unlock or open a vault before importing.',
        isError: true,
      );
      return null;
    }

    final destination = await KeyNestDestinationPickerSheet.show(context);
    if (destination == null) {
      return null;
    }

    if (!kdbxBloc.openedFilesKdbx.contains(destination.file)) {
      _showSnack('The selected vault is no longer available.', isError: true);
      return null;
    }

    if (KeyNestItemTypeHelper.isTrashOrRecycleBin(destination.group)) {
      _showSnack(
        'Cannot import into Trash. Please select an active folder.',
        isError: true,
      );
      return null;
    }

    return destination;
  }

  Future<void> _exportKdbx() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    if (openedFiles.isEmpty) {
      _showSnack('No active vault open to export.', isError: true);
      return;
    }

    final config = await KeyNestExportOptionsSheet.show(
      context,
      kdbxBloc: kdbxBloc,
      format: KeyNestExportFormat.kdbx,
    );
    if (config == null || !mounted) {
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Encrypting and exporting KDBX vault...';
    });

    try {
      final result = await KeyNestImportExportService.exportKdbx(
        kdbxBloc: kdbxBloc,
        file: config.file,
        newMasterPassword: config.newMasterPassword,
        newKeyFileBytes: config.newKeyFileBytes,
        selection: config.selection,
      );
      if (!mounted) {
        return;
      }
      if (result.isCancelled) {
        return;
      }
      if (result.success) {
        _showSnack(
          'Encrypted KDBX backup exported successfully (${result.count} items)!',
        );
      } else {
        _showSnack(result.message ?? 'Export failed', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _exportCsv() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    if (openedFiles.isEmpty) {
      _showSnack('No active vault open to export.', isError: true);
      return;
    }

    final config = await KeyNestExportOptionsSheet.show(
      context,
      kdbxBloc: kdbxBloc,
      format: KeyNestExportFormat.csv,
    );
    if (config == null || !mounted) {
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Exporting passwords to CSV...';
    });

    try {
      final result = await KeyNestImportExportService.exportCsv(
        file: config.file,
        kdbxBloc: kdbxBloc,
        selection: config.selection,
      );
      if (!mounted) {
        return;
      }
      if (result.isCancelled) {
        return;
      }
      if (result.success) {
        _showSnack('Exported ${result.count} credentials to CSV.');
      } else {
        _showSnack(result.message ?? 'Export failed', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _exportJson() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    if (openedFiles.isEmpty) {
      _showSnack('No active vault open to export.', isError: true);
      return;
    }

    final config = await KeyNestExportOptionsSheet.show(
      context,
      kdbxBloc: kdbxBloc,
      format: KeyNestExportFormat.json,
    );
    if (config == null || !mounted) {
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Exporting passwords to JSON...';
    });

    try {
      final result = await KeyNestImportExportService.exportJson(
        file: config.file,
        kdbxBloc: kdbxBloc,
        selection: config.selection,
      );
      if (!mounted) {
        return;
      }
      if (result.isCancelled) {
        return;
      }
      if (result.success) {
        _showSnack('Exported ${result.count} credentials to JSON.');
      } else {
        _showSnack(result.message ?? 'Export failed', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _importKdbx() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final destination = await _selectImportDestination();
    if (destination == null) {
      return;
    }

    try {
      final xFile = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'KeePass Database', extensions: ['kdbx']),
        ],
      );
      if (xFile == null) {
        return;
      }

      final creds = await _promptImportCredentialsDialog(
        title: 'Enter Credentials for ${xFile.name}',
      );
      if (creds == null) {
        return;
      }

      setState(() {
        _isLoading = true;
        _statusMessage = 'Decrypting and importing KDBX...';
      });

      final bytes = await xFile.readAsBytes();
      final result = await KeyNestImportExportService.importKdbxBytes(
        kdbxBloc: kdbxBloc,
        targetFile: destination.file,
        targetGroup: destination.group,
        bytes: bytes,
        password: creds.password,
        keyFileBytes: creds.keyFileBytes,
      );

      if (!mounted) {
        return;
      }
      if (result.success) {
        KeyNestVaultScope.instance.setSelectedVault(
          kdbxBloc,
          destination.file,
        );
        KeyNestVaultScope.instance.notifyScopeChanged();
        _showSnack('Successfully merged ${result.count} entries from KDBX!');
      } else {
        _showSnack(result.message ?? 'Import failed', isError: true);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Import error: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _startUnifiedCsvImport() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    if (openedFiles.isEmpty) {
      _showSnack(
        'Please unlock or open a vault before importing.',
        isError: true,
      );
      return;
    }

    try {
      final xFile = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'CSV or Text File',
            extensions: ['csv', 'txt'],
          ),
        ],
      );
      if (xFile == null) {
        return;
      }

      setState(() {
        _isLoading = true;
        _statusMessage = 'Reading CSV file...';
      });

      final csvText = await xFile.readAsString();
      final rows = await KeyNestImportExportService.parseCsvAsync(csvText);
      if (rows.length < 2) {
        _showSnack(
          'CSV file is empty or does not have headers.',
          isError: true,
        );
        return;
      }

      final activeFile =
          KeyNestVaultScope.instance.getSelectedVault(kdbxBloc) ??
          openedFiles.first;
      final initialDestination = KeyNestDestination(
        file: activeFile,
        group: activeFile.body.rootGroup,
      );

      if (!mounted) {
        return;
      }
      setState(() => _isLoading = false);

      final result = await Navigator.of(context)
          .push<KeyNestImportExportResult>(
            MaterialPageRoute(
              builder: (ctx) => KeyNestCsvImportScreen(
                fileName: xFile.name,
                csvText: csvText,
                parsedRows: rows,
                initialDestination: initialDestination,
              ),
            ),
          );

      if (!mounted) {
        return;
      }
      if (result != null) {
        if (result.success) {
          KeyNestVaultScope.instance.notifyScopeChanged();
          _showSnack(
            result.message ??
                'Imported ${result.count} credentials successfully!',
          );
        } else if (result.message != null && !result.isCancelled) {
          _showSnack(result.message!, isError: true);
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Import error: $e', isError: true);
      }
    } finally {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _importJson() async {
    final kdbxBloc = context.read<KdbxBloc>();
    final destination = await _selectImportDestination();
    if (destination == null) {
      return;
    }

    try {
      final xFile = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'JSON Document',
            extensions: ['json'],
          ),
        ],
      );
      if (xFile == null) {
        return;
      }

      setState(() {
        _isLoading = true;
        _statusMessage = 'Importing credentials from JSON...';
      });

      final jsonText = await xFile.readAsString();
      final result = await KeyNestImportExportService.importJsonText(
        kdbxBloc: kdbxBloc,
        targetFile: destination.file,
        targetGroup: destination.group,
        jsonText: jsonText,
      );

      if (!mounted) {
        return;
      }
      if (result.success) {
        _showSnack(
          result.message ?? 'Imported ${result.count} credentials from JSON!',
        );
      } else {
        _showSnack(result.message ?? 'Import failed', isError: true);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Import error: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<({String password, Uint8List? keyFileBytes})?>
  _promptImportCredentialsDialog({
    required String title,
  }) async {
    final controller = TextEditingController();
    Uint8List? selectedKeyBytes;
    String? selectedKeyName;

    return await showDialog<({String password, Uint8List? keyFileBytes})>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final isDark = Theme.of(dialogCtx).brightness == Brightness.dark;
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Enter master password and/or select key file:',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  PasswordInputField(
                    controller: controller,
                    autofocus: true,
                    labelText: 'Master Password',
                  ),
                  const SizedBox(height: 12),
                  // Key file row
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? KeyNestPalette.surfaceDark
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark ? Colors.white12 : Colors.grey.shade300,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.vpn_key_rounded, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            selectedKeyBytes == null
                                ? 'No Key File Selected'
                                : (selectedKeyName ?? 'Key File Selected'),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (selectedKeyBytes != null)
                          IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => setDialogState(() {
                              selectedKeyBytes = null;
                              selectedKeyName = null;
                            }),
                          )
                        else
                          TextButton(
                            onPressed: () async {
                              try {
                                if (KeyNestPlatform.isIOS ||
                                    KeyNestPlatform.isAndroid) {
                                  await FilePickerWritable().openFile((
                                    fileInfo,
                                    file,
                                  ) async {
                                    final bytes = await file.readAsBytes();
                                    try {
                                      KeyNestKeyFile.parse(
                                        bytes,
                                        fileName: fileInfo.fileName,
                                      );
                                      setDialogState(() {
                                        selectedKeyBytes = bytes;
                                        selectedKeyName = fileInfo.fileName;
                                      });
                                    } on KeyFileValidationException catch (e) {
                                      if (dialogCtx.mounted) {
                                        await DialogUtils.showSimpleAlertDialog(
                                          dialogCtx,
                                          'Invalid Key File',
                                          e.message,
                                          routeAppend: 'invalidKeyFile',
                                        );
                                      }
                                    }
                                    return fileInfo;
                                  });
                                } else {
                                  const typeGroup = XTypeGroup(
                                    label: 'Key Files (*.key, *.keyx, *.xml)',
                                    extensions: [
                                      'key',
                                      'keyx',
                                      'xml',
                                      'bin',
                                      'txt',
                                    ],
                                  );
                                  final file = await openFile(
                                    acceptedTypeGroups: [typeGroup],
                                  );
                                  if (file != null) {
                                    final bytes = await file.readAsBytes();
                                    try {
                                      KeyNestKeyFile.parse(
                                        bytes,
                                        fileName: file.name,
                                      );
                                      setDialogState(() {
                                        selectedKeyBytes = bytes;
                                        selectedKeyName = file.name;
                                      });
                                    } on KeyFileValidationException catch (e) {
                                      if (dialogCtx.mounted) {
                                        await DialogUtils.showSimpleAlertDialog(
                                          dialogCtx,
                                          'Invalid Key File',
                                          e.message,
                                          routeAppend: 'invalidKeyFile',
                                        );
                                      }
                                    }
                                  }
                                }
                              } catch (_) {}
                            },
                            child: const Text(
                              'Browse',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                    foregroundColor: isDark
                        ? const Color(0xFF00315D)
                        : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    if (controller.text.isEmpty && selectedKeyBytes == null) {
                      return;
                    }
                    Navigator.of(context).pop((
                      password: controller.text,
                      keyFileBytes: selectedKeyBytes,
                    ));
                  },
                  child: Text(
                    'Unlock & Merge',
                    style: TextStyle(
                      color: isDark ? const Color(0xFF00315D) : Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showSnack(String text, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(milliseconds: 1800),
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

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: const Text('Import & Export'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            children: [
              // SECTION: EXPORT
              _buildSectionHeader('EXPORT VAULT'),
              const SizedBox(height: 8),

              _buildTile(
                icon: Icons.shield_rounded,
                iconColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                title: 'Export KeePass (.kdbx)',
                badge: 'ENCRYPTED • RECOMMENDED',
                badgeColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                subtitle:
                    'KDBX 4.0 database protected with your master password. Safe for cloud and offsite backup.',
                actionLabel: 'Export KDBX',
                onAction: _exportKdbx,
              ),
              const SizedBox(height: 12),

              _buildTile(
                icon: Icons.table_chart_rounded,
                iconColor: KeyNestPalette.warning,
                title: 'Export CSV Spreadsheet',
                badge: 'UNENCRYPTED',
                badgeColor: KeyNestPalette.warning,
                subtitle:
                    'Plain text CSV table containing titles, logins, passwords, URLs, and TOTP secrets.',
                actionLabel: 'Export CSV',
                onAction: _exportCsv,
              ),
              const SizedBox(height: 12),

              _buildTile(
                icon: Icons.code_rounded,
                iconColor: KeyNestPalette.info,
                title: 'Export JSON Document',
                badge: 'UNENCRYPTED',
                badgeColor: KeyNestPalette.info,
                subtitle:
                    'Structured JSON format with all entry fields, custom attributes, and metadata.',
                actionLabel: 'Export JSON',
                onAction: _exportJson,
              ),

              const SizedBox(height: 28),

              // SECTION: IMPORT
              _buildSectionHeader('IMPORT & MIGRATE'),
              const SizedBox(height: 8),

              _buildTile(
                icon: Icons.folder_zip_rounded,
                iconColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                title: 'KeePass Database (.kdbx)',
                subtitle:
                    'Merge entries from another KeePass 3.x / 4.x vault into your current database.',
                actionLabel: 'Select .kdbx',
                onAction: _importKdbx,
              ),
              const SizedBox(height: 12),

              _buildTile(
                icon: Icons.table_chart_rounded,
                iconColor: isDark
                    ? KeyNestPalette.successDark
                    : KeyNestPalette.success,
                title: 'CSV Spreadsheet (.csv)',
                badge: 'UNIFIED IMPORT',
                badgeColor: isDark
                    ? KeyNestPalette.successDark
                    : KeyNestPalette.success,
                subtitle:
                    'Import credentials from Bitwarden, 1Password, LastPass, or any CSV with Quick Import or Custom Field Mapping.',
                actionLabel: 'Import CSV',
                onAction: _startUnifiedCsvImport,
              ),
              const SizedBox(height: 12),

              _buildTile(
                icon: Icons.code_rounded,
                iconColor: KeyNestPalette.info,
                title: 'JSON Document',
                subtitle:
                    'Import credentials from KeyNest or Bitwarden JSON export files.',
                actionLabel: 'Import JSON',
                onAction: _importJson,
              ),

              const SizedBox(height: 40),
            ],
          ),

          if (_isLoading)
            Container(
              color: Colors.black45,
              alignment: Alignment.center,
              child: KeyNestCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
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
                    Text(
                      _statusMessage ?? 'Processing...',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
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

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
          color: Theme.of(context).brightness == Brightness.dark
              ? KeyNestPalette.textSecondaryDark
              : KeyNestPalette.textSecondaryLight,
        ),
      ),
    );
  }

  Widget _buildTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String actionLabel,
    required VoidCallback onAction,
    String? badge,
    Color? badgeColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return KeyNestCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? KeyNestPalette.textPrimaryDark
                                  : KeyNestPalette.textPrimaryLight,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  (badgeColor ??
                                          (isDark
                                              ? KeyNestPalette.primaryDark
                                              : KeyNestPalette.primary))
                                      .withValues(alpha: isDark ? 0.20 : 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              badge,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color:
                                    badgeColor ??
                                    (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark
                    ? KeyNestPalette.surfaceDark
                    : KeyNestPalette.surfaceLight,
                foregroundColor: iconColor,
                elevation: 0,
                side: BorderSide(color: iconColor.withValues(alpha: 0.3)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _isLoading ? null : onAction,
              icon: Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: iconColor,
              ),
              label: Text(
                actionLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: iconColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
