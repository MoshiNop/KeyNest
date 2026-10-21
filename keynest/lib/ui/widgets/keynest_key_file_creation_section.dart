import 'dart:io' as io;

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:keynest/services/key_file_store.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/ui/widgets/keynest_desktop_key_file_dialog.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/key_file_handler.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('KeyNestKeyFileCreationSection');

enum KeyNestKeyFileOption {
  generate,
  existing,
}

/// Controller holding key file configuration for any vault creation flow.
class KeyNestKeyFileCreationController extends ChangeNotifier {
  bool _useKeyFile = false;
  KeyNestKeyFileOption _option = KeyNestKeyFileOption.generate;

  Uint8List? _keyFileBytes;
  String? _keyFileName;
  KeyNestKeyFileResult? _keyFileResult;
  String? _keyFilePath;
  String? _keyFilePickerIdentifier;
  String? _keyFileMacOsBookmark;
  Uint8List? _cachedGeneratedXmlBytes;

  bool get useKeyFile => _useKeyFile;
  KeyNestKeyFileOption get option => _option;
  Uint8List? get keyFileBytes => _keyFileBytes;
  String? get keyFileName => _keyFileName;
  KeyNestKeyFileResult? get keyFileResult => _keyFileResult;
  String? get keyFilePath => _keyFilePath;
  String? get keyFilePickerIdentifier => _keyFilePickerIdentifier;
  String? get keyFileMacOsBookmark => _keyFileMacOsBookmark;

  Uint8List? get effectiveKeyFileBytes => _useKeyFile ? _keyFileBytes : null;

  set useKeyFile(bool value) {
    if (_useKeyFile == value) {
      return;
    }
    _useKeyFile = value;
    if (!value) {
      clear(notify: false);
    }
    notifyListeners();
  }

  set option(KeyNestKeyFileOption value) {
    if (_option == value) {
      return;
    }
    _option = value;
    notifyListeners();
  }

  void clear({bool notify = true}) {
    _keyFileBytes = null;
    _keyFileName = null;
    _keyFileResult = null;
    _keyFilePath = null;
    _keyFilePickerIdentifier = null;
    _keyFileMacOsBookmark = null;
    _cachedGeneratedXmlBytes = null;
    if (notify) {
      notifyListeners();
    }
  }

  /// Prompts the user to save a newly generated XML v2.0 key file using the platform native picker.
  Future<bool> generateAndSaveKeyFile({
    required BuildContext context,
    required String defaultBaseName,
    bool forceRegenerate = false,
  }) async {
    try {
      if (forceRegenerate || _cachedGeneratedXmlBytes == null) {
        _cachedGeneratedXmlBytes = KeyNestKeyFile.generateXmlV2();
      }
      final xmlBytes = _cachedGeneratedXmlBytes!;
      final trimmed = defaultBaseName.trim();
      final defaultName = '${trimmed.isNotEmpty ? trimmed : "vault"}.keyx';

      if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
        final fileInfo = await FilePickerWritable().openFileForCreate(
          fileName: defaultName,
          writer: (file) async {
            await file.writeAsBytes(xmlBytes, flush: true);
          },
        );
        if (fileInfo != null) {
          final result = KeyNestKeyFile.parse(
            xmlBytes,
            fileName: fileInfo.fileName,
          );
          _keyFileResult = result;
          _keyFileName = fileInfo.fileName ?? defaultName;
          _keyFileBytes = xmlBytes;
          _keyFilePickerIdentifier = fileInfo.toJsonString();
          _keyFilePath = null;
          _keyFileMacOsBookmark = null;
          notifyListeners();
          return true;
        }
        return false;
      } else {
        final saveLocation = await getSaveLocation(
          suggestedName: defaultName,
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'KeePass Key File (*.keyx)',
              extensions: ['keyx'],
            ),
          ],
        );
        if (saveLocation != null) {
          final targetFile = io.File(saveLocation.path);
          await targetFile.writeAsBytes(xmlBytes, flush: true);
          String? macOsBookmark;
          if (KeyNestPlatform.isMacOS) {
            macOsBookmark = await SecureBookmarks().bookmark(targetFile);
          }
          final result = KeyNestKeyFile.parse(
            xmlBytes,
            fileName: p.basename(saveLocation.path),
          );
          _keyFileResult = result;
          _keyFileName = p.basename(saveLocation.path);
          _keyFileBytes = xmlBytes;
          _keyFilePath = saveLocation.path;
          _keyFilePickerIdentifier = null;
          _keyFileMacOsBookmark = macOsBookmark;
          notifyListeners();
          return true;
        }
        return false;
      }
    } catch (e) {
      _logger.warning('Failed to generate key file: $e');
      if (context.mounted) {
        await DialogUtils.showSimpleAlertDialog(
          context,
          'Key File Error',
          'Failed to generate or save key file: $e',
          routeAppend: 'generateKeyFileError',
        );
      }
      return false;
    }
  }

  /// Prompts the user to pick an existing key file and validates it.
  Future<bool> pickExistingKeyFile({required BuildContext context}) async {
    try {
      if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
        final fileInfo = await FilePickerWritable().openFile((
          info,
          file,
        ) async {
          final bytes = await file.readAsBytes();
          try {
            final result = KeyNestKeyFile.parse(bytes, fileName: info.fileName);
            _keyFileResult = result;
            _keyFileName = info.fileName;
            _keyFileBytes = bytes;
            _keyFilePickerIdentifier = info.toJsonString();
            _keyFilePath = null;
            _keyFileMacOsBookmark = null;
            notifyListeners();
          } on KeyFileValidationException catch (e) {
            if (context.mounted) {
              await DialogUtils.showSimpleAlertDialog(
                context,
                'Invalid Key File',
                e.message,
                routeAppend: 'invalidKeyFile',
              );
            }
          }
          return info;
        });
        return fileInfo != null && _keyFileBytes != null;
      } else {
        const typeGroup = XTypeGroup(
          label: 'Key Files (*.key, *.keyx, *.xml)',
          extensions: ['key', 'keyx', 'xml', 'bin', 'txt'],
        );
        final file = await openFile(acceptedTypeGroups: [typeGroup]);
        if (file != null) {
          final bytes = await file.readAsBytes();
          try {
            final result = KeyNestKeyFile.parse(bytes, fileName: file.name);
            String? macOsBookmark;
            if (KeyNestPlatform.isMacOS) {
              macOsBookmark = await SecureBookmarks().bookmark(
                io.File(file.path),
              );
            }
            _keyFileResult = result;
            _keyFileName = file.name;
            _keyFileBytes = bytes;
            _keyFilePath = file.path;
            _keyFilePickerIdentifier = null;
            _keyFileMacOsBookmark = macOsBookmark;
            notifyListeners();
            return true;
          } on KeyFileValidationException catch (e) {
            if (context.mounted) {
              await DialogUtils.showSimpleAlertDialog(
                context,
                'Invalid Key File',
                e.message,
                routeAppend: 'invalidKeyFile',
              );
            }
            return false;
          }
        }
        return false;
      }
    } catch (e) {
      _logger.warning('Failed to pick key file: $e');
      return false;
    }
  }

  /// Validates key file selection before finalizing vault creation.
  /// If key file generation was selected but not yet saved, launches the save dialog.
  /// Returns `true` if ready to proceed with vault creation, `false` otherwise.
  Future<bool> validateAndEnsureSaved({
    required BuildContext context,
    required String defaultBaseName,
  }) async {
    if (!_useKeyFile) {
      return true;
    }

    if (_keyFileBytes == null) {
      if (_option == KeyNestKeyFileOption.generate) {
        final saved = await generateAndSaveKeyFile(
          context: context,
          defaultBaseName: defaultBaseName,
        );
        if (!saved || _keyFileBytes == null) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Please save your generated key file to create the protected vault.',
                ),
              ),
            );
          }
          return false;
        }
        return true;
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Please select an existing key file or switch to generate a new key file.',
              ),
            ),
          );
        }
        return false;
      }
    }

    return true;
  }

  /// Persists the key file reference for a newly created vault.
  Future<void> saveReferenceForVault(String vaultUuid) async {
    if (_useKeyFile && _keyFileBytes != null && _keyFileName != null) {
      await KeyNestKeyFileStore.instance.saveReference(
        vaultUuid: vaultUuid,
        displayName: _keyFileName!,
        filePath: _keyFilePath,
        filePickerIdentifier: _keyFilePickerIdentifier,
        macOsBookmark: _keyFileMacOsBookmark,
        formatName: _keyFileResult?.displayName,
      );
    }
  }
}

/// Shared UI component providing consistent key file protection options across all vault creation flows.
class KeyNestKeyFileCreationSection extends StatelessWidget {
  const KeyNestKeyFileCreationSection({
    super.key,
    required this.controller,
    required this.getVaultName,
  });

  final KeyNestKeyFileCreationController controller;
  final String Function() getVaultName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (KeyNestPlatform.isDesktopOrWeb) {
      return _buildDesktopLayout(context, isDark);
    }
    return _buildMobileLayout(context, isDark);
  }

  Widget _buildDesktopLayout(BuildContext context, bool isDark) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.vpn_key_rounded,
                  size: 20,
                  color: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestTokens.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Use key file',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: isDark
                              ? KeyNestTokens.textPrimaryDark
                              : KeyNestTokens.textPrimaryLight,
                        ),
                      ),
                      Text(
                        'Protect this vault with a key file in addition to the master password.',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? KeyNestTokens.textSecondaryDark
                              : KeyNestTokens.textSecondaryLight,
                        ),
                      ),
                    ],
                  ),
                ),
                Builder(
                  builder: (switchContext) => Switch.adaptive(
                    value: controller.useKeyFile,
                    onChanged: (val) {
                      controller.useKeyFile = val;
                      if (val && controller.keyFileBytes == null) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (switchContext.mounted) {
                            showDesktopKeyFileCreationPopover(
                              anchorContext: switchContext,
                              controller: controller,
                              getVaultName: getVaultName,
                            );
                          }
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
            if (controller.useKeyFile) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              if (controller.keyFileBytes == null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.black.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark ? Colors.white12 : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 20,
                        color: Colors.amber.shade700,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Key file not yet configured',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: isDark
                                    ? KeyNestTokens.textPrimaryDark
                                    : KeyNestTokens.textPrimaryLight,
                              ),
                            ),
                            Text(
                              'Generate a new .keyx file or select an existing one.',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? KeyNestTokens.textSecondaryDark
                                    : KeyNestTokens.textSecondaryLight,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Builder(
                        builder: (btnContext) => ElevatedButton.icon(
                          onPressed: () => showDesktopKeyFileCreationPopover(
                            anchorContext: btnContext,
                            controller: controller,
                            getVaultName: getVaultName,
                          ),
                          icon: const Icon(Icons.tune_rounded, size: 16),
                          label: const Text('Configure...'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                _buildDesktopAttachedTile(context, isDark),
              ],
              const SizedBox(height: 10),
              _buildSecurityNoticeWidget(isDark),
            ],
          ],
        );
      },
    );
  }

  Widget _buildDesktopAttachedTile(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.primaryDark.withValues(alpha: 0.12)
            : KeyNestTokens.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (isDark ? KeyNestPalette.primaryDark : KeyNestTokens.primary)
              .withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_rounded,
            color: isDark ? KeyNestPalette.primaryDark : KeyNestTokens.primary,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.keyFileName ?? 'keyfile',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  controller.keyFileResult?.displayName ?? 'Key File Attached',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark
                        ? KeyNestTokens.textSecondaryDark
                        : KeyNestTokens.textSecondaryLight,
                  ),
                ),
                if (controller.keyFilePath != null &&
                    controller.keyFilePath!.isNotEmpty) ...[
                  Text(
                    controller.keyFilePath!,
                    style: TextStyle(
                      fontSize: 9,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (btnContext) => OutlinedButton.icon(
              onPressed: () => showDesktopKeyFileCreationPopover(
                anchorContext: btnContext,
                controller: controller,
                getVaultName: getVaultName,
              ),
              icon: const Icon(Icons.edit_outlined, size: 14),
              label: const Text('Change', style: TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: controller.clear,
            tooltip: 'Remove key file',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityNoticeWidget(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.amber.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.amber,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Important Security Notice',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? Colors.amber.shade200
                        : Colors.amber.shade900,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Both your master password and this key file are required to unlock your vault. Keep the key file separate from your vault. If you lose this key file, your vault cannot be recovered.',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark
                        ? Colors.amber.shade200
                        : Colors.amber.shade900,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(BuildContext context, bool isDark) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.vpn_key_rounded,
                  size: 20,
                  color: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestTokens.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Use key file',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: isDark
                              ? KeyNestTokens.textPrimaryDark
                              : KeyNestTokens.textPrimaryLight,
                        ),
                      ),
                      Text(
                        'Protect this vault with a key file in addition to the master password.',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? KeyNestTokens.textSecondaryDark
                              : KeyNestTokens.textSecondaryLight,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: controller.useKeyFile,
                  onChanged: (val) => controller.useKeyFile = val,
                ),
              ],
            ),
            if (controller.useKeyFile) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              // Option Selector: Generate (default) vs Existing
              LayoutBuilder(
                builder: (context, constraints) {
                  final isNarrow = constraints.maxWidth < 280;
                  final generateWidget = InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () =>
                        controller.option = KeyNestKeyFileOption.generate,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color:
                            controller.option == KeyNestKeyFileOption.generate
                            ? (isDark
                                  ? KeyNestPalette.primaryDark.withValues(
                                      alpha: 0.15,
                                    )
                                  : KeyNestTokens.primary.withValues(
                                      alpha: 0.08,
                                    ))
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color:
                              controller.option == KeyNestKeyFileOption.generate
                              ? (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestTokens.primary)
                              : (isDark
                                    ? Colors.white12
                                    : Colors.grey.shade300),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            controller.option == KeyNestKeyFileOption.generate
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            size: 16,
                            color:
                                controller.option ==
                                    KeyNestKeyFileOption.generate
                                ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestTokens.primary)
                                : Colors.grey,
                          ),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              'Generate new key file',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );

                  final existingWidget = InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () =>
                        controller.option = KeyNestKeyFileOption.existing,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color:
                            controller.option == KeyNestKeyFileOption.existing
                            ? (isDark
                                  ? KeyNestPalette.primaryDark.withValues(
                                      alpha: 0.15,
                                    )
                                  : KeyNestTokens.primary.withValues(
                                      alpha: 0.08,
                                    ))
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color:
                              controller.option == KeyNestKeyFileOption.existing
                              ? (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestTokens.primary)
                              : (isDark
                                    ? Colors.white12
                                    : Colors.grey.shade300),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            controller.option == KeyNestKeyFileOption.existing
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            size: 16,
                            color:
                                controller.option ==
                                    KeyNestKeyFileOption.existing
                                ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestTokens.primary)
                                : Colors.grey,
                          ),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              'Use existing key file',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );

                  if (isNarrow) {
                    return Column(
                      children: [
                        generateWidget,
                        const SizedBox(height: 6),
                        existingWidget,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: generateWidget),
                      const SizedBox(width: 8),
                      Expanded(child: existingWidget),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              // Option content
              if (controller.option == KeyNestKeyFileOption.generate) ...[
                if (controller.keyFileBytes == null) ...[
                  OutlinedButton.icon(
                    onPressed: () => controller.generateAndSaveKeyFile(
                      context: context,
                      defaultBaseName: getVaultName(),
                    ),
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: const Text('Save & Generate Key File (*.keyx)'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ] else ...[
                  _buildAttachedKeyFileTile(
                    context,
                    isDark,
                    canRegenerate: true,
                  ),
                ],
              ] else ...[
                if (controller.keyFileBytes == null) ...[
                  OutlinedButton.icon(
                    onPressed: () =>
                        controller.pickExistingKeyFile(context: context),
                    icon: const Icon(Icons.folder_open_rounded, size: 16),
                    label: const Text('Select Existing Key File'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ] else ...[
                  _buildAttachedKeyFileTile(
                    context,
                    isDark,
                    canRegenerate: false,
                  ),
                ],
              ],
              const SizedBox(height: 10),
              // Security notice
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.amber.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.amber,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Important Security Notice',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark
                                  ? Colors.amber.shade200
                                  : Colors.amber.shade900,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Both your master password and this key file are required to unlock your vault. Keep the key file separate from your vault. If you lose this key file, your vault cannot be recovered.',
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark
                                  ? Colors.amber.shade200
                                  : Colors.amber.shade900,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildAttachedKeyFileTile(
    BuildContext context,
    bool isDark, {
    required bool canRegenerate,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.primaryDark.withValues(alpha: 0.12)
            : KeyNestTokens.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (isDark ? KeyNestPalette.primaryDark : KeyNestTokens.primary)
              .withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_rounded,
            color: isDark ? KeyNestPalette.primaryDark : KeyNestTokens.primary,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.keyFileName ?? 'keyfile',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  controller.keyFileResult?.displayName ?? 'Key File Attached',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark
                        ? KeyNestTokens.textSecondaryDark
                        : KeyNestTokens.textSecondaryLight,
                  ),
                ),
                if (controller.keyFilePath != null &&
                    controller.keyFilePath!.isNotEmpty) ...[
                  Text(
                    controller.keyFilePath!,
                    style: TextStyle(
                      fontSize: 9,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (canRegenerate) ...[
            TextButton(
              onPressed: () => controller.generateAndSaveKeyFile(
                context: context,
                defaultBaseName: getVaultName(),
                forceRegenerate: true,
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Re-save', style: TextStyle(fontSize: 11)),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: controller.clear,
            tooltip: 'Remove key file',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}
