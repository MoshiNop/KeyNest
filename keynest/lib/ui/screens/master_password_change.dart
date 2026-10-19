import 'dart:io' as io;

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/key_file_store.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/ui/widgets/password_strength_display.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/key_file_handler.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:provider/provider.dart';
import 'package:zxcvbn/zxcvbn.dart';

final _logger = Logger('master_password_change');

typedef KeyNestChangeMasterPasswordScreen = MasterPasswordChangeScreen;

class MasterPasswordChangeScreen extends StatefulWidget {
  const MasterPasswordChangeScreen({
    super.key,
    this.fileSource,
  });

  static Route<void> route({
    FileSource? fileSource,
  }) => MaterialPageRoute(
    builder: (context) => MasterPasswordChangeScreen(fileSource: fileSource),
    settings: const RouteSettings(name: 'masterPasswordChange'),
  );

  final FileSource? fileSource;

  static Future<bool> validateCurrentPassword({
    required KdbxBloc kdbxBloc,
    required KdbxFile file,
    required String currentPassword,
  }) async {
    try {
      final existingCreds = file.credentials;
      if (existingCreds is KeyFileComposite) {
        final candidate = KeyFileComposite(
          password: PasswordCredentials(
            ProtectedValue.fromString(currentPassword),
          ),
          keyFile: existingCreds.keyFile,
        );
        return listEquals(candidate.getHash(), existingCreds.getHash());
      }

      try {
        final existingHash = existingCreds.getHash();
        final candidate = Credentials(
          ProtectedValue.fromString(currentPassword),
        );
        if (listEquals(candidate.getHash(), existingHash)) {
          return true;
        }
      } on UnsupportedError {
        // getHash() not supported for post-KDF TransformedKeyCredentials
      }

      // Fallback: test read against cached bytes
      final openedFile = kdbxBloc.fileForKdbxFile(file);
      final cachedBytes = openedFile.kdbxFileContent.content;
      final candidate = existingCreds is KeyFileComposite
          ? KeyFileComposite(
              password: PasswordCredentials(
                ProtectedValue.fromString(currentPassword),
              ),
              keyFile: existingCreds.keyFile,
            )
          : Credentials(ProtectedValue.fromString(currentPassword));
      await kdbxBloc.kdbxFormat.read(cachedBytes, candidate);
      return true;
    } catch (e) {
      return false;
    }
  }

  static Future<void> updateMasterPassword({
    required KdbxBloc kdbxBloc,
    required KdbxFile file,
    required String newPassword,
    Uint8List? newKeyFileBytes,
    bool removeKeyFile = false,
  }) async {
    final Credentials newCredentials;
    if (removeKeyFile) {
      newCredentials = Credentials(ProtectedValue.fromString(newPassword));
    } else if (newKeyFileBytes != null && newKeyFileBytes.isNotEmpty) {
      final keyResult = KeyNestKeyFile.parse(newKeyFileBytes);
      newCredentials = KeyFileComposite(
        password: PasswordCredentials(ProtectedValue.fromString(newPassword)),
        keyFile: KeyFileCredentials.fromBytes(keyResult.keyBytes),
      );
    } else if (file.credentials is KeyFileComposite) {
      final existingComposite = file.credentials as KeyFileComposite;
      newCredentials = KeyFileComposite(
        password: PasswordCredentials(ProtectedValue.fromString(newPassword)),
        keyFile: existingComposite.keyFile,
      );
    } else {
      newCredentials = Credentials(ProtectedValue.fromString(newPassword));
    }
    final savedContent = await kdbxBloc.saveFile(
      file,
      updateCredentials: newCredentials,
    );

    // Cryptographically verify that the re-encrypted vault can be successfully decrypted with newCredentials
    if (savedContent.content.isNotEmpty) {
      final verifiedFile = await kdbxBloc.kdbxFormat.read(
        savedContent.content,
        newCredentials,
      );
      if (verifiedFile.body.rootGroup.uuid != file.body.rootGroup.uuid) {
        throw StateError(
          'Re-encryption verification failed: root UUID mismatch',
        );
      }
    }
  }

  @override
  State<MasterPasswordChangeScreen> createState() =>
      _MasterPasswordChangeScreenState();
}

class _MasterPasswordChangeScreenState
    extends State<MasterPasswordChangeScreen> {
  static final _zxcvbn = Zxcvbn();

  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  final _currentFocusNode = FocusNode();
  final _newFocusNode = FocusNode();
  final _confirmFocusNode = FocusNode();

  final _formKey = GlobalKey<FormState>();

  FileSource? _selectedFileSource;
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isSaving = false;

  bool _removeKeyFile = false;
  Uint8List? _newKeyFileBytes;
  String? _newKeyFileName;
  String? _newKeyFilePath;
  String? _newKeyFilePickerIdentifier;
  String? _newKeyFileMacOsBookmark;
  KeyNestKeyFileResult? _newKeyFileResult;

  Result? _newPasswordStrength;
  String? _currentPasswordError;
  String? _newPasswordError;
  String? _confirmPasswordError;

  @override
  void initState() {
    super.initState();
    _selectedFileSource = widget.fileSource;
  }

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    _currentFocusNode.dispose();
    _newFocusNode.dispose();
    _confirmFocusNode.dispose();
    super.dispose();
  }

  void _onVaultChanged(FileSource? newSource) {
    if (newSource == null || newSource == _selectedFileSource) {
      return;
    }
    setState(() {
      _selectedFileSource = newSource;
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
      _currentPasswordError = null;
      _newPasswordError = null;
      _confirmPasswordError = null;
      _newPasswordStrength = null;
      _removeKeyFile = false;
      _newKeyFileBytes = null;
      _newKeyFileName = null;
      _newKeyFilePath = null;
      _newKeyFileResult = null;
    });
  }

  Future<void> _pickNewKeyFile() async {
    try {
      if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
        await FilePickerWritable().openFile((fileInfo, file) async {
          final bytes = await file.readAsBytes();
          try {
            final parsed = KeyNestKeyFile.parse(
              bytes,
              fileName: fileInfo.fileName,
            );
            setState(() {
              _newKeyFileResult = parsed;
              _newKeyFileName = fileInfo.fileName;
              _newKeyFileBytes = bytes;
              _newKeyFilePickerIdentifier = fileInfo.toJsonString();
              _newKeyFilePath = null;
              _newKeyFileMacOsBookmark = null;
              _removeKeyFile = false;
            });
          } on KeyFileValidationException catch (e) {
            if (mounted) {
              await DialogUtils.showSimpleAlertDialog(
                context,
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
          extensions: ['key', 'keyx', 'xml', 'bin', 'txt'],
        );
        final file = await openFile(acceptedTypeGroups: [typeGroup]);
        if (file != null) {
          final bytes = await file.readAsBytes();
          try {
            final parsed = KeyNestKeyFile.parse(bytes, fileName: file.name);
            String? macOsBookmark;
            if (KeyNestPlatform.isMacOS) {
              macOsBookmark = await SecureBookmarks().bookmark(
                io.File(file.path),
              );
            }
            setState(() {
              _newKeyFileResult = parsed;
              _newKeyFileName = file.name;
              _newKeyFileBytes = bytes;
              _newKeyFilePath = file.path;
              _newKeyFilePickerIdentifier = null;
              _newKeyFileMacOsBookmark = macOsBookmark;
              _removeKeyFile = false;
            });
          } on KeyFileValidationException catch (e) {
            if (mounted) {
              await DialogUtils.showSimpleAlertDialog(
                context,
                'Invalid Key File',
                e.message,
                routeAppend: 'invalidKeyFile',
              );
            }
          }
        }
      }
    } catch (e) {
      _logger.warning('Failed to pick key file: $e');
    }
  }

  Future<void> _handleSubmit({
    required KdbxBloc kdbxBloc,
    required KdbxFile selectedFile,
  }) async {
    FocusScope.of(context).unfocus();

    setState(() {
      _currentPasswordError = null;
      _newPasswordError = null;
      _confirmPasswordError = null;
    });

    final currentPassword = _currentPasswordController.text;
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    var hasValidationErrors = false;

    if (currentPassword.isEmpty) {
      _currentPasswordError = 'Please enter your current master password';
      hasValidationErrors = true;
    }

    if (newPassword.isEmpty) {
      _newPasswordError = 'Please enter a new master password';
      hasValidationErrors = true;
    } else if (newPassword.length < 4) {
      _newPasswordError = 'Password must be at least 4 characters';
      hasValidationErrors = true;
    }

    if (confirmPassword.isEmpty) {
      _confirmPasswordError = 'Please confirm the new master password';
      hasValidationErrors = true;
    } else if (newPassword != confirmPassword) {
      _confirmPasswordError = 'New passwords do not match';
      hasValidationErrors = true;
    }

    if (!hasValidationErrors && currentPassword == newPassword) {
      _newPasswordError =
          'New password must be different from current password';
      hasValidationErrors = true;
    }

    if (hasValidationErrors) {
      setState(() {});
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      // 1. Validate current password
      final isCurrentValid =
          await MasterPasswordChangeScreen.validateCurrentPassword(
            kdbxBloc: kdbxBloc,
            file: selectedFile,
            currentPassword: currentPassword,
          );

      if (!isCurrentValid) {
        if (mounted) {
          setState(() {
            _isSaving = false;
            _currentPasswordError = 'Current master password is incorrect';
          });
          _currentFocusNode.requestFocus();
        }
        return;
      }

      // 2. Perform password update and write to vault
      await MasterPasswordChangeScreen.updateMasterPassword(
        kdbxBloc: kdbxBloc,
        file: selectedFile,
        newPassword: newPassword,
        newKeyFileBytes: _newKeyFileBytes,
        removeKeyFile: _removeKeyFile,
      );

      final opened = kdbxBloc.fileForKdbxFile(selectedFile);
      final uuid = opened.fileSource.uuid;
      if (_removeKeyFile) {
        await KeyNestKeyFileStore.instance.removeReference(uuid);
      } else if (_newKeyFileBytes != null && _newKeyFileName != null) {
        await KeyNestKeyFileStore.instance.saveReference(
          vaultUuid: uuid,
          displayName: _newKeyFileName!,
          filePath: _newKeyFilePath,
          filePickerIdentifier: _newKeyFilePickerIdentifier,
          macOsBookmark: _newKeyFileMacOsBookmark,
          formatName: _newKeyFileResult?.displayName,
        );
      }

      if (!mounted) {
        return;
      }

      _currentPasswordController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();

      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                SizedBox(width: 10),
                Text('Master password changed successfully'),
              ],
            ),
            backgroundColor: KeyNestPalette.success,
            duration: Duration(seconds: 2),
          ),
        );

      Navigator.of(context).pop();
    } catch (e, stackTrace) {
      _logger.severe('Failed to change master password', e, stackTrace);
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.error_outline_rounded, color: KeyNestPalette.error),
                SizedBox(width: 10),
                Text('Password Change Failed'),
              ],
            ),
            content: Text(
              'Could not update master password. The vault remains unchanged with your existing credentials.\n\nError: $e',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFilesList = kdbxBloc.openedFilesWithSources.toList();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (openedFilesList.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Change Master Password'),
        ),
        body: _buildNoVaultsView(context, isDark),
      );
    }

    // Determine currently selected vault
    FileSource? effectiveSource = _selectedFileSource;
    if (effectiveSource == null ||
        !openedFilesList.any((e) => e.key == effectiveSource)) {
      effectiveSource = openedFilesList.first.key;
    }

    final selectedEntry = openedFilesList.firstWhere(
      (e) => e.key == effectiveSource,
      orElse: () => openedFilesList.first,
    );
    final selectedFile = selectedEntry.value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Change Master Password'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header card explaining the purpose
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color:
                        (isDark
                                ? KeyNestPalette.cardDark
                                : KeyNestPalette.cardLight)
                            .withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark
                          ? KeyNestPalette.entryBorderDark
                          : KeyNestPalette.entryBorderLight,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color:
                              (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.lightIcon)
                                  .withValues(alpha: isDark ? 0.20 : 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.password_rounded,
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.lightIcon,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Update Vault Master Password',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isDark
                                    ? KeyNestPalette.textPrimaryDark
                                    : KeyNestPalette.textPrimaryLight,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Enter your current master password to verify ownership, then specify a new strong password.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: isDark
                                    ? KeyNestPalette.textSecondaryDark
                                    : KeyNestPalette.textSecondaryLight,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Vault Selector
                Text(
                  'TARGET VAULT',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                _buildVaultSelector(
                  openedFilesList: openedFilesList,
                  selectedSource: effectiveSource,
                  isDark: isDark,
                ),
                const SizedBox(height: 24),

                // Current Master Password
                Text(
                  'CURRENT MASTER PASSWORD',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _currentPasswordController,
                  focusNode: _currentFocusNode,
                  obscureText: _obscureCurrent,
                  enabled: !_isSaving,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => _newFocusNode.requestFocus(),
                  decoration: InputDecoration(
                    hintText: 'Enter current master password',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureCurrent
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureCurrent = !_obscureCurrent;
                        });
                      },
                    ),
                    errorText: _currentPasswordError,
                    filled: true,
                    fillColor: isDark
                        ? KeyNestPalette.surfaceDark
                        : Colors.grey.shade50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // New Master Password
                Text(
                  'NEW MASTER PASSWORD',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _newPasswordController,
                  focusNode: _newFocusNode,
                  obscureText: _obscureNew,
                  enabled: !_isSaving,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => _confirmFocusNode.requestFocus(),
                  onChanged: (val) {
                    setState(() {
                      if (val.isEmpty) {
                        _newPasswordStrength = null;
                      } else {
                        _newPasswordStrength = _zxcvbn.evaluate(val);
                      }
                      if (_newPasswordError != null) {
                        _newPasswordError = null;
                      }
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Enter new master password',
                    prefixIcon: const Icon(Icons.lock_reset_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureNew
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureNew = !_obscureNew;
                        });
                      },
                    ),
                    errorText: _newPasswordError,
                    filled: true,
                    fillColor: isDark
                        ? KeyNestPalette.surfaceDark
                        : Colors.grey.shade50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                if (_newPasswordStrength != null) ...[
                  const SizedBox(height: 8),
                  PasswordStrengthDisplay(strength: _newPasswordStrength),
                ],
                const SizedBox(height: 20),

                // Confirm New Master Password
                Text(
                  'CONFIRM NEW MASTER PASSWORD',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _confirmPasswordController,
                  focusNode: _confirmFocusNode,
                  obscureText: _obscureConfirm,
                  enabled: !_isSaving,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _handleSubmit(
                    kdbxBloc: kdbxBloc,
                    selectedFile: selectedFile,
                  ),
                  onChanged: (val) {
                    if (_confirmPasswordError != null) {
                      setState(() {
                        _confirmPasswordError = null;
                      });
                    }
                  },
                  decoration: InputDecoration(
                    hintText: 'Confirm new master password',
                    prefixIcon: const Icon(Icons.check_circle_outline_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirm
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureConfirm = !_obscureConfirm;
                        });
                      },
                    ),
                    errorText: _confirmPasswordError,
                    filled: true,
                    fillColor: isDark
                        ? KeyNestPalette.surfaceDark
                        : Colors.grey.shade50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Key File Configuration Section
                Text(
                  'VAULT KEY FILE (CREDENTIALS)',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark
                        ? KeyNestPalette.surfaceDark
                        : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isDark ? Colors.white12 : Colors.grey.shade300,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (selectedFile.credentials is KeyFileComposite &&
                          !_removeKeyFile &&
                          _newKeyFileBytes == null) ...[
                        Row(
                          children: [
                            const Icon(
                              Icons.vpn_key_rounded,
                              size: 20,
                              color: KeyNestPalette.primary,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Current Key File Preserved',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _pickNewKeyFile,
                              child: const Text('Change'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _removeKeyFile = true),
                              style: TextButton.styleFrom(
                                foregroundColor: KeyNestPalette.error,
                              ),
                              child: const Text('Remove'),
                            ),
                          ],
                        ),
                      ] else if (_removeKeyFile) ...[
                        Row(
                          children: [
                            const Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 20,
                              color: KeyNestPalette.error,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Key file will be removed (vault becomes password-only).',
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _removeKeyFile = false),
                              child: const Text('Undo'),
                            ),
                          ],
                        ),
                      ] else if (_newKeyFileBytes != null) ...[
                        Row(
                          children: [
                            const Icon(
                              Icons.check_circle_rounded,
                              size: 20,
                              color: KeyNestPalette.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'New Key File: ${_newKeyFileName ?? "selected"}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (_newKeyFileResult != null)
                                    Text(
                                      _newKeyFileResult!.displayName,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isDark
                                            ? Colors.white60
                                            : Colors.black54,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => setState(() {
                                _newKeyFileBytes = null;
                                _newKeyFileName = null;
                                _newKeyFilePath = null;
                                _newKeyFileResult = null;
                              }),
                            ),
                          ],
                        ),
                      ] else ...[
                        Row(
                          children: [
                            const Icon(
                              Icons.key_off_outlined,
                              size: 20,
                              color: Colors.grey,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'No key file (password only)',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _pickNewKeyFile,
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('Add Key File'),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Warning callout
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: KeyNestPalette.warning.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: KeyNestPalette.warning.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: KeyNestPalette.warning,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Make sure to write down or memorize your new password. If you lose your master password, your vault cannot be recovered.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),

                // Submit Button
                ElevatedButton(
                  onPressed: _isSaving
                      ? null
                      : () => _handleSubmit(
                          kdbxBloc: kdbxBloc,
                          selectedFile: selectedFile,
                        ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                    foregroundColor: isDark
                        ? const Color(0xFF00315D)
                        : Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 2,
                  ),
                  child: _isSaving
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              isDark ? const Color(0xFF00315D) : Colors.white,
                            ),
                          ),
                        )
                      : Text(
                          'Update Master Password',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? const Color(0xFF00315D)
                                : Colors.white,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVaultSelector({
    required List<MapEntry<FileSource, KdbxFile>> openedFilesList,
    required FileSource? selectedSource,
    required bool isDark,
  }) {
    if (openedFilesList.length <= 1) {
      final entry = openedFilesList.firstOrNull;
      final vaultName = entry?.value.body.rootGroup.name.get() ?? 'Vault';
      final sourceDisplay =
          entry?.key.displayPath ?? entry?.key.displayName ?? 'Local File';

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? KeyNestPalette.surfaceDark : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark
                ? KeyNestPalette.entryBorderDark
                : KeyNestPalette.entryBorderLight,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color:
                    (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary)
                        .withValues(alpha: isDark ? 0.20 : 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.folder_special_rounded,
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
                    vaultName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    sourceDisplay,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: KeyNestPalette.success.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Active',
                style: TextStyle(
                  color: KeyNestPalette.success,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? KeyNestPalette.surfaceDark : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? KeyNestPalette.entryBorderDark
              : KeyNestPalette.entryBorderLight,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<FileSource>(
          value: selectedSource,
          isExpanded: true,
          icon: const Icon(Icons.arrow_drop_down_rounded, size: 28),
          dropdownColor: isDark ? KeyNestPalette.surfaceDark : Colors.white,
          borderRadius: BorderRadius.circular(16),
          items: openedFilesList.map((entry) {
            final vaultName = entry.value.body.rootGroup.name.get() ?? 'Vault';
            final sourceDisplay = entry.key.displayPath;
            return DropdownMenuItem<FileSource>(
              value: entry.key,
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                              .withValues(alpha: isDark ? 0.20 : 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.folder_special_rounded,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          vaultName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          sourceDisplay,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: _isSaving ? null : _onVaultChanged,
        ),
      ),
    );
  }

  Widget _buildNoVaultsView(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color:
                    (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary)
                        .withValues(alpha: isDark ? 0.20 : 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lock_open_rounded,
                size: 36,
                color: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No Open Vaults',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Please open or unlock a vault first to change its master password.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => SelectFileScreen.navigate(context),
              icon: Icon(
                Icons.file_open_rounded,
                size: 18,
                color: isDark ? const Color(0xFF00315D) : Colors.white,
              ),
              label: Text(
                'Open Vault',
                style: TextStyle(
                  color: isDark ? const Color(0xFF00315D) : Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                foregroundColor: isDark
                    ? const Color(0xFF00315D)
                    : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
