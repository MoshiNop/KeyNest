import 'dart:io' as io;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/widgets/keynest_key_file_creation_section.dart';
import 'package:keynest/utils/key_file_handler.dart';
import 'package:keynest/utils/platform.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';

/// Result returned from the desktop key file selection popover.
class DesktopKeyFileSelectionResult {
  const DesktopKeyFileSelectionResult({
    required this.cleared,
    this.name,
    this.path,
    this.bytes,
    this.parsed,
    this.macOsBookmark,
  });

  final bool cleared;
  final String? name;
  final String? path;
  final Uint8List? bytes;
  final KeyNestKeyFileResult? parsed;
  final String? macOsBookmark;
}

/// Centered floating dialog helper for desktop key file dialogs.
Future<T?> _showCenteredDesktopKeyFileDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double width = 460,
  double? maxHeight,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: isDark ? 0.45 : 0.25),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return Center(
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: width,
              maxHeight: maxHeight ??
                  (MediaQuery.of(context).size.height * 0.85).clamp(200.0, 680.0),
            ),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              decoration: BoxDecoration(
                color: isDark
                    ? KeyNestPalette.surfaceDark
                    : KeyNestPalette.surfaceLight,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? KeyNestPalette.cardBorderDark
                      : KeyNestPalette.cardBorderLight,
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: isDark ? 0.45 : 0.16,
                    ),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: ScaffoldMessenger(
                child: builder(dialogContext),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
          alignment: Alignment.center,
          child: child,
        ),
      );
    },
  );
}

/// Centered floating dialog for selecting a key file when opening an existing vault.
Future<DesktopKeyFileSelectionResult?> showDesktopKeyFileSelectionPopover({
  required BuildContext anchorContext,
  String? currentFileName,
  String? currentFormatName,
}) async {
  return _showCenteredDesktopKeyFileDialog<DesktopKeyFileSelectionResult>(
    context: anchorContext,
    width: 440,
    builder: (dialogContext) => _DesktopKeyFileSelectionContent(
      currentFileName: currentFileName,
      currentFormatName: currentFormatName,
    ),
  );
}

class _DesktopKeyFileSelectionContent extends StatefulWidget {
  const _DesktopKeyFileSelectionContent({
    this.currentFileName,
    this.currentFormatName,
  });

  final String? currentFileName;
  final String? currentFormatName;

  @override
  State<_DesktopKeyFileSelectionContent> createState() =>
      _DesktopKeyFileSelectionContentState();
}

class _DesktopKeyFileSelectionContentState
    extends State<_DesktopKeyFileSelectionContent> {
  String? _selectedName;
  String? _selectedPath;
  Uint8List? _selectedBytes;
  KeyNestKeyFileResult? _selectedParsed;
  String? _macOsBookmark;
  String? _errorMessage;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _selectedName = widget.currentFileName;
  }

  Future<void> _browseKeyFile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      const typeGroup = XTypeGroup(
        label: 'Key Files (*.key, *.keyx, *.xml)',
        extensions: ['key', 'keyx', 'xml', 'bin', 'txt'],
      );
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) {
        setState(() => _isLoading = false);
        return;
      }

      final bytes = await file.readAsBytes();
      final parsed = KeyNestKeyFile.parse(bytes, fileName: file.name);

      String? macOsBookmark;
      if (KeyNestPlatform.isMacOS) {
        try {
          macOsBookmark = await SecureBookmarks().bookmark(io.File(file.path));
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _selectedName = file.name;
          _selectedPath = file.path;
          _selectedBytes = bytes;
          _selectedParsed = parsed;
          _macOsBookmark = macOsBookmark;
          _isLoading = false;
        });
      }
    } on KeyFileValidationException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to read key file: $e';
          _isLoading = false;
        });
      }
    }
  }

  void _removeKeyFile() {
    setState(() {
      _selectedName = null;
      _selectedPath = null;
      _selectedBytes = null;
      _selectedParsed = null;
      _macOsBookmark = null;
      _errorMessage = null;
    });
  }

  void _apply() {
    if (_selectedBytes != null && _selectedName != null && _selectedParsed != null) {
      Navigator.of(context).pop(
        DesktopKeyFileSelectionResult(
          cleared: false,
          name: _selectedName,
          path: _selectedPath,
          bytes: _selectedBytes,
          parsed: _selectedParsed,
          macOsBookmark: _macOsBookmark,
        ),
      );
    } else if (_selectedName == null) {
      Navigator.of(context).pop(
        const DesktopKeyFileSelectionResult(cleared: true),
      );
    } else {
      Navigator.of(context).pop(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final hasFile = _selectedName != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.vpn_key_rounded,
                        color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Vault Key File',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? KeyNestPalette.textPrimaryDark
                              : KeyNestPalette.textPrimaryLight,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                splashRadius: 16,
                onPressed: () => Navigator.of(context).pop(null),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Select the key file required to decrypt this vault.',
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
          ),
          const SizedBox(height: 14),

          // Error message banner
          if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, size: 16, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(fontSize: 12, color: Colors.redAccent),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Selected file status card
          if (hasFile) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                    .withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                      .withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedName!,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_selectedParsed?.displayName != null ||
                            widget.currentFormatName != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            _selectedParsed?.displayName ?? widget.currentFormatName!,
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    tooltip: 'Remove key file',
                    onPressed: _removeKeyFile,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                ),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.folder_open_rounded,
                    size: 28,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'No key file selected',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Browse file button
          OutlinedButton.icon(
            onPressed: _isLoading ? null : _browseKeyFile,
            icon: _isLoading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_upload_outlined, size: 16),
            label: Text(hasFile ? 'Change Key File...' : 'Browse Key File...'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 14),

          // Actions Row
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _apply,
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                ),
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Centered floating dialog for configuring a key file during vault creation.
Future<void> showDesktopKeyFileCreationPopover({
  required BuildContext anchorContext,
  required KeyNestKeyFileCreationController controller,
  required String Function() getVaultName,
}) async {
  return _showCenteredDesktopKeyFileDialog<void>(
    context: anchorContext,
    width: 460,
    builder: (dialogContext) => _DesktopKeyFileCreationContent(
      controller: controller,
      getVaultName: getVaultName,
    ),
  );
}

class _DesktopKeyFileCreationContent extends StatelessWidget {
  const _DesktopKeyFileCreationContent({
    required this.controller,
    required this.getVaultName,
  });

  final KeyNestKeyFileCreationController controller;
  final String Function() getVaultName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary)
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.vpn_key_rounded,
                            color: isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Key File Protection',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? KeyNestPalette.textPrimaryDark
                                  : KeyNestPalette.textPrimaryLight,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 16,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Protect your new vault with an encrypted key file in addition to your master password.',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 14),

              // Option Selector
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () =>
                          controller.option = KeyNestKeyFileOption.generate,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: controller.option ==
                                  KeyNestKeyFileOption.generate
                              ? (isDark
                                  ? KeyNestPalette.primaryDark
                                      .withValues(alpha: 0.15)
                                  : KeyNestPalette.primary
                                      .withValues(alpha: 0.10))
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: controller.option ==
                                    KeyNestKeyFileOption.generate
                                ? (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary)
                                : (isDark ? Colors.white12 : Colors.grey.shade300),
                            width: controller.option ==
                                    KeyNestKeyFileOption.generate
                                ? 1.5
                                : 1.0,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              controller.option ==
                                      KeyNestKeyFileOption.generate
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_off_rounded,
                              size: 16,
                              color: controller.option ==
                                      KeyNestKeyFileOption.generate
                                  ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text(
                                'Generate New (*.keyx)',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () =>
                          controller.option = KeyNestKeyFileOption.existing,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: controller.option ==
                                  KeyNestKeyFileOption.existing
                              ? (isDark
                                  ? KeyNestPalette.primaryDark
                                      .withValues(alpha: 0.15)
                                  : KeyNestPalette.primary
                                      .withValues(alpha: 0.10))
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: controller.option ==
                                    KeyNestKeyFileOption.existing
                                ? (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary)
                                : (isDark ? Colors.white12 : Colors.grey.shade300),
                            width: controller.option ==
                                    KeyNestKeyFileOption.existing
                                ? 1.5
                                : 1.0,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              controller.option ==
                                      KeyNestKeyFileOption.existing
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_off_rounded,
                              size: 16,
                              color: controller.option ==
                                      KeyNestKeyFileOption.existing
                                  ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text(
                                'Use Existing Key File',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Option Content
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
                        vertical: 11,
                        horizontal: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ] else ...[
                  _buildAttachedCard(
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
                    label: const Text('Browse Existing Key File...'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: 11,
                        horizontal: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ] else ...[
                  _buildAttachedCard(
                    context,
                    isDark,
                    canRegenerate: false,
                  ),
                ],
              ],
              const SizedBox(height: 12),

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
                            'Important Security Requirement',
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
                            'Both your master password and this key file are required to unlock your vault. If lost, your vault cannot be recovered.',
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
              const SizedBox(height: 16),

              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAttachedCard(
    BuildContext context,
    bool isDark, {
    required bool canRegenerate,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
              .withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_rounded,
            color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.keyFileName ?? 'Key File Attached',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  controller.keyFileResult?.displayName ?? 'XML v2.0 Key File',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
              ],
            ),
          ),
          if (canRegenerate)
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              tooltip: 'Regenerate',
              onPressed: () => controller.generateAndSaveKeyFile(
                context: context,
                defaultBaseName: getVaultName(),
                forceRegenerate: true,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: 'Remove key file',
            onPressed: () => controller.clear(),
          ),
        ],
      ),
    );
  }
}
