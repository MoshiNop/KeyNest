import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx/file_source_ui.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/cloud_storage_ui.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/main_app_scaffold.dart';
import 'package:keynest/ui/widgets/keynest_cloud_connect_modal.dart';
import 'package:keynest/ui/widgets/keynest_key_file_creation_section.dart';
import 'package:keynest/ui/widgets/password_input_field.dart';
import 'package:keynest/ui/widgets/password_strength_display.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/key_file_handler.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:recase/recase.dart';
// ignore: implementation_imports
import 'package:zxcvbn/zxcvbn.dart';

final _logger = Logger('create_file');

enum _StorageLocationType {
  appStorage,
  customPath,
  cloudStorage,
}

class CreateFile extends StatefulWidget {
  const CreateFile({super.key, this.target});

  static PageRoute<void> route({CloudStorageSaveTarget? target}) =>
      MaterialPageRoute(
        settings: const RouteSettings(
          name: '/createFile',
        ),
        builder: (context) => CreateFile(
          target: target,
        ),
      );

  final CloudStorageSaveTarget? target;

  @override
  _CreateFileState createState() => _CreateFileState();
}

class _CreateFileState extends State<CreateFile> with FutureTaskStateMixin {
  static final _zxcvbn = Zxcvbn();

  final GlobalKey<FormState> _formKey = GlobalKey();
  final TextEditingController _databaseName = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _customPathController = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();

  Result? _strength;

  final KeyNestKeyFileCreationController _keyFileController =
      KeyNestKeyFileCreationController();

  _StorageLocationType _storageType = _StorageLocationType.customPath;
  FileSource? _customFileSource;
  String? _customPathLabel;
  CloudStorageSaveTarget? _cloudTarget;

  @override
  void initState() {
    super.initState();
    if (widget.target != null) {
      _storageType = _StorageLocationType.cloudStorage;
      _cloudTarget = widget.target;
    } else {
      _storageType = _StorageLocationType.customPath;
      if (KeyNestPlatform.isAndroid) {
        _customPathController.text = '/storage/emulated/0/Documents';
      }
    }
  }

  @override
  void dispose() {
    _databaseName.dispose();
    _password.dispose();
    _customPathController.dispose();
    _passwordFocus.dispose();
    _keyFileController.dispose();
    super.dispose();
  }

  bool _biometricQuickUnlockSupported = false;
  bool? _biometricQuickUnlockActivated;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final loc = AppLocalizations.of(context);
    if (_databaseName.text.isEmpty) {
      _databaseName.text = loc.databaseCreateDefaultName;
    }
    final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
    kdbxBloc.quickUnlockStorage.supportsBiometricKeyStore().then(
      (biometricQuickUnlock) {
        if (mounted) {
          setState(() {
            _biometricQuickUnlockSupported = biometricQuickUnlock;
            _biometricQuickUnlockActivated ??= true;
          });
        }
      },
    );
  }

  Future<void> _pickCustomFileLocation() async {
    final dbName = _databaseName.text.isNotEmpty ? _databaseName.text : 'vault';
    final fileName = '$dbName.kdbx';

    try {
      if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
        if (_password.text.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Please enter a master password first before choosing file location.',
              ),
            ),
          );
          _passwordFocus.requestFocus();
          return;
        }

        final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
        final Credentials credentials;
        final keyBytes = _keyFileController.effectiveKeyFileBytes;
        if (keyBytes != null && keyBytes.isNotEmpty) {
          credentials = KeyNestKeyFile.createCompositeCredentials(
            password: _password.text,
            keyFileBytes: keyBytes,
          );
        } else {
          credentials = Credentials(ProtectedValue.fromString(_password.text));
        }
        final kdbxFile = kdbxBloc.kdbxFormat.create(
          credentials,
          dbName,
          generator: Env.KeyNest,
        );
        final bytes = await kdbxBloc.saveFileToBytes<Uint8List>(
          kdbxFile,
          (b) async => b,
        );

        final fileInfo = await FileSourceLocal.createFileInNewTempDirectory(
          fileName,
          (tempFile) async {
            return await FilePickerWritable().openFileForCreate(
              fileName: fileName,
              writer: (file) async {
                await file.writeAsBytes(bytes, flush: true);
              },
            );
          },
        );

        if (fileInfo != null) {
          setState(() {
            _storageType = _StorageLocationType.customPath;
            _customFileSource = FileSourceLocal(
              FileSourceLocal.localFile(fileInfo.fileName ?? fileName),
              databaseName: _databaseName.text,
              uuid: AppDataBloc.createUuid(),
              filePickerIdentifier: fileInfo.toJsonString(),
            );
            _customPathLabel = fileInfo.fileName ?? fileInfo.uri.toString();
            _customPathController.text = _customPathLabel!;
          });
        }
      } else if (!KeyNestPlatform.isWeb) {
        final loc = AppLocalizations.of(context);
        final pathFile = await getSaveLocation(
          suggestedName: fileName,
          confirmButtonText: loc.saveButtonLabel,
        );
        if (pathFile != null) {
          final outputFile = io.File(pathFile.path);
          String? macOsBookmark;
          if (KeyNestPlatform.isMacOS) {
            await outputFile.writeAsString('.');
            macOsBookmark = await SecureBookmarks().bookmark(outputFile);
          }
          setState(() {
            _customFileSource = FileSourceLocal(
              FileSourceLocal.localFile(pathFile.path),
              databaseName: _databaseName.text,
              uuid: AppDataBloc.createUuid(),
              macOsSecureBookmark: macOsBookmark,
            );
            _customPathLabel = pathFile.path;
            _customPathController.text = pathFile.path;
          });
        }
      }
    } catch (e, st) {
      _logger.warning('Error selecting custom path', e, st);
    }
  }

  Future<void> _pickCloudLocation(CloudStorageProvider provider) async {
    if (!provider.isAuthenticated) {
      final connected = await KeyNestCloudConnectModal.show(context, provider);
      if (connected != true || !mounted) {
        return;
      }
      setState(() {});
    }

    final dbName = _databaseName.text.isNotEmpty ? _databaseName.text : 'vault';
    final createFileInfo = await Navigator.of(context)
        .push<CloudStorageSelectorSaveResult>(
          CloudStorageSelector.route(
            provider,
            CloudStorageBrowserConfig(
              defaultFileName: '$dbName.kdbx',
              isSave: true,
            ),
          ),
        );

    if (createFileInfo != null) {
      setState(() {
        _cloudTarget = CloudStorageSaveTarget(
          provider: provider,
          parent: createFileInfo.parent,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cloudBloc = context.watch<CloudStorageBloc>();

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: Text(loc.createPasswordDatabase),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: KeyNestPlatform.isDesktopOrWeb ? 640 : double.infinity,
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: KeyNestPlatform.isDesktopOrWeb ? 32 : 24,
              vertical: KeyNestPlatform.isDesktopOrWeb ? 24 : 12,
            ),
            child: Form(
              key: _formKey,
              child: Theme(
              data: theme.copyWith(
                inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                  filled: true,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // Hero Banner Card
                  KeyNestSurfaceCard(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        KeyNestCompactIconTile(
                          icon: Icons.shield_rounded,
                          tint: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestTokens.primary,
                          size: 46,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'New Encrypted Vault',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: isDark
                                      ? KeyNestTokens.textPrimaryDark
                                      : KeyNestTokens.textPrimaryLight,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Standard KDBX 4.0 database with Argon2/AES key derivation.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: isDark
                                      ? KeyNestTokens.textSecondaryDark
                                      : KeyNestTokens.textSecondaryLight,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),

                  TextFormField(
                    controller: _databaseName,
                    decoration: InputDecoration(
                      labelText: loc.nameNewPasswordDatabase,
                      suffixText: '.kdbx', // NON-NLS
                      filled: true,
                    ),
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: (val) => _passwordFocus.requestFocus(),
                    validator: (val) {
                      if (val == null || val.isEmpty) {
                        return loc.validatorNameMissing;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  PasswordInputField(
                    labelText: loc.inputMasterPasswordText,
                    controller: _password,
                    focusNode: _passwordFocus,
                    autofocus: true,
                    onFieldSubmitted: (val) => _submitCallback()?.call(),
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    onChanged: (value) {
                      final userInput = _databaseName.text.pathCase.split(
                        CharConstants.slash,
                      );
                      setState(() {
                        if (value.isEmpty) {
                          _strength = null;
                        } else {
                          _strength = _zxcvbn.evaluate(
                            value,
                            userInputs: userInput,
                          );
                        }
                      });
                    },
                    validator: (val) {
                      if (val == null || val.isEmpty) {
                        return loc.masterPasswordMissingCreate;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 8),
                  PasswordStrengthDisplay(strength: _strength),
                  const SizedBox(height: 6),
                  Text(
                    loc.masterPasswordDescription,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isDark
                          ? KeyNestTokens.textSecondaryDark
                          : KeyNestTokens.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Key File Card
                  KeyNestSurfaceCard(
                    padding: const EdgeInsets.all(16),
                    child: KeyNestKeyFileCreationSection(
                      controller: _keyFileController,
                      getVaultName: () => _databaseName.text,
                    ),
                  ),
                  if (_biometricQuickUnlockSupported) ...[
                    const SizedBox(height: 14),
                    KeyNestCompactCard(
                      child: Row(
                        children: [
                          KeyNestCompactIconTile(
                            size: 36,
                            child: const Icon(
                              Icons.fingerprint_rounded,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              loc.saveMasterPasswordBiometric,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Switch.adaptive(
                            value: _biometricQuickUnlockActivated ?? false,
                            onChanged: (value) => setState(() {
                              _biometricQuickUnlockActivated = value;
                            }),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),

                  // Storage Location Selection Card
                  KeyNestSurfaceCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.folder_special_rounded,
                              size: 20,
                              color: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestTokens.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Storage Destination',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isDark
                                    ? KeyNestTokens.textPrimaryDark
                                    : KeyNestTokens.textPrimaryLight,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        RadioGroup<_StorageLocationType>(
                          groupValue: _storageType,
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _storageType = val);
                              if (val == _StorageLocationType.customPath &&
                                  _customFileSource == null &&
                                  _customPathController.text.isEmpty) {
                                if (KeyNestPlatform.isAndroid) {
                                  _customPathController.text =
                                      '/storage/emulated/0/Download';
                                }
                              }
                            }
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Option 1: Custom Path / Phone Folder (Default)
                              RadioListTile<_StorageLocationType>(
                                value: _StorageLocationType.customPath,
                                title: Text(
                                  KeyNestPlatform.isDesktopOrWeb
                                      ? 'Local Disk / Custom Folder (Default)'
                                      : 'Phone Folder / Custom Path (Default)',
                                ),
                                subtitle: Text(
                                  _customPathLabel != null
                                      ? 'Selected: $_customPathLabel'
                                      : (KeyNestPlatform.isDesktopOrWeb
                                            ? 'Save directly to Documents, Desktop, or a custom folder.'
                                            : 'Save directly to your phone storage, Documents, or SD card.'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _customPathLabel != null
                                        ? (isDark
                                              ? KeyNestPalette.primaryDark
                                              : KeyNestPalette.primary)
                                        : null,
                                    fontWeight: _customPathLabel != null
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                                contentPadding: EdgeInsets.zero,
                                activeColor: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                              ),
                              if (_storageType ==
                                  _StorageLocationType.customPath) ...[
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 36,
                                    top: 4,
                                    bottom: 8,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      TextField(
                                        controller: _customPathController,
                                        decoration: InputDecoration(
                                          labelText: 'Folder Path or File Name',
                                          hintText: KeyNestPlatform.isAndroid
                                              ? '/storage/emulated/0/Documents'
                                              : 'Enter folder path...',
                                          isDense: true,
                                          prefixIcon: const Icon(
                                            Icons.folder_outlined,
                                            size: 20,
                                          ),
                                          suffixIcon: IconButton(
                                            icon: const Icon(
                                              Icons.folder_open_rounded,
                                              size: 20,
                                            ),
                                            tooltip:
                                                'Browse with System File Picker',
                                            onPressed: _pickCustomFileLocation,
                                          ),
                                        ),
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          if (KeyNestPlatform.isAndroid) ...[
                                            ActionChip(
                                              avatar: const Icon(
                                                Icons.description_outlined,
                                                size: 14,
                                              ),
                                              label: const Text(
                                                'Documents',
                                                style: TextStyle(fontSize: 11),
                                              ),
                                              onPressed: () {
                                                setState(() {
                                                  _customPathController.text =
                                                      '/storage/emulated/0/Documents';
                                                });
                                              },
                                            ),
                                            ActionChip(
                                              avatar: const Icon(
                                                Icons.phone_android_rounded,
                                                size: 14,
                                              ),
                                              label: const Text(
                                                'Phone Storage',
                                                style: TextStyle(fontSize: 11),
                                              ),
                                              onPressed: () {
                                                setState(() {
                                                  _customPathController.text =
                                                      '/storage/emulated/0';
                                                });
                                              },
                                            ),
                                          ],
                                          ActionChip(
                                            avatar: const Icon(
                                              Icons.folder_open_rounded,
                                              size: 14,
                                            ),
                                            label: const Text(
                                              'Browse Filesystem',
                                              style: TextStyle(fontSize: 11),
                                            ),
                                            onPressed: _pickCustomFileLocation,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],

                              // Option 2: App Internal Storage
                              RadioListTile<_StorageLocationType>(
                                value: _StorageLocationType.appStorage,
                                title: const Text('App Storage'),
                                subtitle: const Text(
                                  'Internal sandboxed storage (hidden from external file managers).',
                                  style: TextStyle(fontSize: 12),
                                ),
                                contentPadding: EdgeInsets.zero,
                                activeColor: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                              ),

                              // Option 4: Cloud Storage
                              if (cloudBloc
                                  .availableCloudStorage
                                  .isNotEmpty) ...[
                                RadioListTile<_StorageLocationType>(
                                  value: _StorageLocationType.cloudStorage,
                                  title: const Text(
                                    'Cloud Storage (Nextcloud, Dropbox, WebDAV)',
                                  ),
                                  subtitle: Text(
                                    _cloudTarget != null
                                        ? 'Target: ${_cloudTarget!.provider.displayName}${_cloudTarget!.parent != null ? ' > ${_cloudTarget!.parent!.pathOrBaseName}' : ''}'
                                        : 'Save directly to Dropbox, WebDAV, Nextcloud, or Google Drive.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _cloudTarget != null
                                          ? (isDark
                                                ? KeyNestPalette.primaryDark
                                                : KeyNestPalette.primary)
                                          : null,
                                      fontWeight: _cloudTarget != null
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                  contentPadding: EdgeInsets.zero,
                                  activeColor: isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary,
                                ),
                                if (_storageType ==
                                    _StorageLocationType.cloudStorage) ...[
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 36,
                                      top: 4,
                                      bottom: 8,
                                    ),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: cloudBloc.availableCloudStorage
                                          .map((provider) {
                                            final isSelected =
                                                _cloudTarget?.provider.id ==
                                                provider.id;
                                            return ChoiceChip(
                                              label: Text(
                                                provider.isAuthenticated
                                                    ? provider.displayName
                                                    : '${provider.displayName} (Connect)',
                                              ),
                                              avatar: provider
                                                  .displayIcon
                                                  .iconData
                                                  .widget(),
                                              selected: isSelected,
                                              onSelected: (_) =>
                                                  _pickCloudLocation(provider),
                                            );
                                          })
                                          .toList(),
                                    ),
                                  ),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerRight,
                    child: task != null
                        ? CircularProgressIndicator(
                            color: isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestTokens.primary,
                          )
                        : KeyNestPressScale(
                            onTap: _submitCallback(),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 14,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestTokens.primary,
                                borderRadius: BorderRadius.circular(
                                  KeyNestTokens.radiusCard,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color:
                                        (isDark
                                                ? KeyNestPalette.primaryDark
                                                : KeyNestTokens.primary)
                                            .withValues(alpha: 0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_circle_outline_rounded,
                                    color: isDark
                                        ? const Color(0xFF00315D)
                                        : Colors.white,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    loc.createDatabaseAction,
                                    style: TextStyle(
                                      color: isDark
                                          ? const Color(0xFF00315D)
                                          : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

  VoidCallback? _submitCallback() => asyncTaskCallback((progress) async {
    if (_formKey.currentState!.validate()) {
      FileSource? customSource;
      CloudStorageSaveTarget? target;

      if (_storageType == _StorageLocationType.customPath) {
        if (_customFileSource != null) {
          customSource = _customFileSource;
        } else if (_customPathController.text.trim().isNotEmpty) {
          var pathStr = _customPathController.text.trim();
          final dbName = _databaseName.text.trim().isNotEmpty
              ? _databaseName.text.trim()
              : 'vault';
          if (!pathStr.toLowerCase().endsWith('.kdbx')) {
            pathStr = p.join(pathStr, '$dbName.kdbx');
          }
          final targetFile = io.File(pathStr);
          if (targetFile.existsSync()) {
            throw FileExistsException(path: targetFile.path);
          }
          if (!targetFile.parent.existsSync()) {
            await targetFile.parent.create(recursive: true);
          }
          customSource = FileSourceLocal(
            FileSourceLocal.localFile(targetFile.path),
            databaseName: dbName,
            uuid: AppDataBloc.createUuid(),
          );
        } else {
          await _pickCustomFileLocation();
          if (_customFileSource == null) {
            if (!mounted) {
              return;
            }
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Please select or enter a valid file path.'),
              ),
            );
            return;
          }
          customSource = _customFileSource;
        }
      } else if (_storageType == _StorageLocationType.cloudStorage) {
        target = _cloudTarget;
        if (target == null) {
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please select a cloud storage destination.'),
            ),
          );
          return;
        }
      }

      if (!mounted) {
        return;
      }

      final keyFileOk = await _keyFileController.validateAndEnsureSaved(
        context: context,
        defaultBaseName: _databaseName.text,
      );
      if (!keyFileOk) {
        return;
      }

      if (!mounted) {
        return;
      }

      final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
      try {
        final created = await kdbxBloc.createFile(
          password: _password.text,
          databaseName: _databaseName.text.trim(),
          keyFileBytes: _keyFileController.effectiveKeyFileBytes,
          openAfterCreate: true,
          target: target,
          customFileSource: customSource,
          addToQuickUnlock: _biometricQuickUnlockActivated ?? false,
        );
        await _keyFileController.saveReferenceForVault(created.uuid);
        _logger.finest('Created file $created');
        await KeyNestPreferencesService.setCompletedOnboarding(true);
        if (!mounted) {
          return;
        }
        unawaited(
          Navigator.of(
            context,
          ).pushAndRemoveUntil(MainAppScaffold.route(), (route) => false),
        );
      } on FileExistsException catch (e, stackTrace) {
        _logger.warning('Showing file exists error dialog.', e, stackTrace);
        if (!mounted) {
          _logger.severe('context no longer mounted. not showing dialog.');
          return;
        }
        final loc = AppLocalizations.of(context);
        await DialogUtils.showSimpleAlertDialog(
          context,
          loc.databaseExistsError,
          loc.databaseExistsErrorDescription(e.path),
          routeAppend: 'createFileExists',
        );
      } catch (e, stackTrace) {
        _logger.severe('Error while creating file.', e, stackTrace);
        rethrow;
      }
    }
  });
}
