// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:autofill_service/autofill_service.dart';
import 'package:biometric_storage/biometric_storage.dart';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:filesystem_picker/filesystem_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/deps.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx/file_source_ui.dart';
import 'package:keynest/bloc/kdbx/file_source_web_none.dart'
    if (dart.library.js) 'package:keynest/bloc/kdbx/file_source_web.dart'
    if (dart.library.html) 'package:keynest/bloc/kdbx/file_source_web.dart'
    if (dart.library.js_interop) 'package:keynest/bloc/kdbx/file_source_web.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/cloud_storage_ui.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_state.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/autofill_resume_helper.dart';
import 'package:keynest/services/key_file_store.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/app_bar_menu.dart';
import 'package:keynest/ui/screens/create_file.dart';
import 'package:keynest/ui/screens/keynest_cloud_vault_browser_screen.dart';
import 'package:keynest/ui/screens/main_app_scaffold.dart';
import 'package:keynest/ui/widgets/keynest_cloud_connect_modal.dart';
import 'package:keynest/ui/widgets/keynest_progress_indicator.dart';
import 'package:keynest/ui/widgets/link_button.dart';
import 'package:keynest/ui/widgets/password_input_field.dart';
import 'package:keynest/ui/widgets/primary_button.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/format_utils.dart';
import 'package:keynest/utils/key_file_handler.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

import '../../theme.dart';

final _logger = Logger('keynest.select_file_screen');

class SelectFileScreen extends StatelessWidget {
  const SelectFileScreen({super.key, this.skipQuickUnlock = false});

  static Route<Object> route({bool skipQuickUnlock = false}) =>
      MaterialPageRoute(
        settings: const RouteSettings(name: '/selectFile'),
        builder: (context) => SelectFileScreen(
          skipQuickUnlock: skipQuickUnlock,
        ),
      );

  static Future<void> navigate(
    BuildContext context, {
    bool skipQuickUnlock = false,
  }) =>
      Navigator.of(
        context,
        rootNavigator: true,
      ).pushAndRemoveUntil(
        SelectFileScreen.route(skipQuickUnlock: skipQuickUnlock),
        (_) => false,
      );

  static bool isValidKdbxHeader(Uint8List bytes) {
    if (bytes.length < 8) {
      return false;
    }
    final b = ByteData.sublistView(bytes);
    final sig1 = b.getUint32(0, Endian.little);
    final sig2 = b.getUint32(4, Endian.little);
    return (sig1 == 0x9AA2D903 &&
            (sig2 == 0xB54BFB67 || sig2 == 0xB54BFB66 || sig2 == 0xB54BFB65)) ||
        (sig1 == 0x9AA2D9A5 && sig2 == 0x354B4156);
  }

  final bool skipQuickUnlock;

  @override
  Widget build(BuildContext context) {
    final cloudBloc = context.watch<Deps>().cloudStorageBloc;
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.selectKeepassFile),
        actions: <Widget>[
          AppBarMenu.createOverflowMenuButton(
            context,
            isOnOpenFileScreen: true,
          ),
        ],
      ),
      body: Provider<CloudStorageBloc>.value(
        value: cloudBloc,
        child: SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: SelectFileWidget(
            skipQuickUnlock: skipQuickUnlock,
          ),
        ),
      ),
    );
  }
}

class ProgressOverlay extends StatelessWidget {
  const ProgressOverlay({super.key, required this.child, this.task});

  final FutureTask? task;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final task = this.task;

    return Stack(
      children: <Widget>[
        child,
        Positioned.fill(
          child: AnimatedCrossFade(
            firstChild: task == null
                ? Container()
                : Container(
                    color: Colors.black12,
                    child: Center(
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.cardColor.withAlpha(
                            250,
                          ),
                          borderRadius: const BorderRadius.all(
                            Radius.circular(8),
                          ),
                        ),
                        padding: const EdgeInsets.all(32),
                        child: ValueListenableBuilder<FutureTask>(
                          valueListenable: task,
                          builder: (context, value, child) {
                            _logger.fine(
                              'Generating progress dialog'
                              ' with label ${value.progressLabel}',
                            );
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const CircularProgressIndicator(),
                                ...?(value.progressLabel == null
                                    ? null
                                    : [
                                        const SizedBox(height: 16),
                                        Text(value.progressLabel!),
                                      ]),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
            secondChild: Container(),
            crossFadeState: task != null
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 200),
          ),
        ),
      ],
    );
  }
}

class SelectFileWidget extends StatefulWidget {
  const SelectFileWidget({
    super.key,
    this.skipQuickUnlock = false,
  });

  final bool skipQuickUnlock;

  @override
  _SelectFileWidgetState createState() => _SelectFileWidgetState();
}

class _SelectFileWidgetState extends State<SelectFileWidget>
    with FutureTaskStateMixin {
  bool _quickUnlockAttempted = false;
  bool _showLinuxAppArmorMessage = false;
  @NonNls
  static const _linuxAppArmorCommand =
      'snap connect keynest:password-manager-service';
  int counter = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _logger.finer('didChangeDependencies ${widget.skipQuickUnlock}');
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      if (!widget.skipQuickUnlock) {
        _checkQuickUnlock();
      }
    });
    _linuxAppArmorCheck();
  }

  Future<bool> _linuxAppArmorCheck() async {
    if (!KeyNestPlatform.isLinux) {
      return true;
    }
    final isError = await BiometricStorage().linuxCheckAppArmorError();
    if (isError != _showLinuxAppArmorMessage) {
      setState(() {
        _showLinuxAppArmorMessage = isError;
      });
    }
    return !isError;
  }

  @override
  void didUpdateWidget(covariant SelectFileWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _logger.finer('didUpdateWidget --- ${oldWidget != widget}');
    if (oldWidget != widget && !widget.skipQuickUnlock) {
      _checkQuickUnlock();
    }
  }

  Future<void> _checkQuickUnlock() {
    final loc = AppLocalizations.of(context);
    return asyncRunTask((progress) async {
      if (_quickUnlockAttempted) {
        _logger.fine('_checkQuickUnlock already did quick unlock. skipping.');
        return;
      }
      _quickUnlockAttempted = true;
      final appDataBloc = Provider.of<AppDataBloc>(context, listen: false);
      final appData =
          appDataBloc.store.cachedValue ?? await appDataBloc.store.load();
      if (appData.previousFiles.isEmpty) {
        _logger.fine(
          'No previous files in AppData. Not attempting quick unlock.',
        );
        return;
      }
      progress.progressLabel = loc.quickUnlockingFiles;
      final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
      if (kdbxBloc.openedFilesWithSources.isNotEmpty) {
        _logger.fine(
          'We already have files open. Not attempting quick unlock.',
        );
        return;
      }
      _logger.finer(
        'opening quick unlock. ${++counter} $_quickUnlockAttempted $mounted',
      );
      final opened = await kdbxBloc.reopenQuickUnlock(loc, progress);
      _logger.info(
        'opened $opened files with quick unlock. ${kdbxBloc.openedFilesKdbx.isNotEmpty}',
      );
      if (opened > 0 && kdbxBloc.openedFilesKdbx.isNotEmpty) {
        _logger.finer('Pushing main app scaffold. (mounted: $mounted)');
        unawaited(
          Navigator.of(context).pushReplacement(MainAppScaffold.route()),
        );
      }
    }, label: loc.quickUnlockingFiles);
  }

  @override
  Widget build(BuildContext context) {
    final appData = Provider.of<AppData>(context);
    final appDataBloc = Provider.of<AppDataBloc>(context);
    final cloudStorageBloc = Provider.of<CloudStorageBloc>(context);
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ProgressOverlay(
      task: task,
      child: Container(
        alignment: Alignment.center,
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            children: <Widget>[
              ...?(_showLinuxAppArmorMessage
                  ? [
                      const SizedBox(height: 16),
                      Text(
                        loc.linuxAppArmorWarning,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall!.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.error,
                        ),
                      ),
                      LinkButton(
                        icon: const Icon(Icons.content_copy),
                        onPressed: () async {
                          await Clipboard.setData(
                            const ClipboardData(text: _linuxAppArmorCommand),
                          );
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(
                              SnackBar(
                                content: Text(loc.copiedToClipboard),
                              ),
                            );
                          await _linuxAppArmorCheck();
                        },
                        child: const Text(
                          _linuxAppArmorCommand,
                          style: TextStyle(
                            fontFamily: KeyNestTheme.monoFontFamily,
                          ),
                          maxLines: null,
                        ),
                      ),
                    ]
                  : null),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color:
                                (theme.brightness == Brightness.dark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary)
                                    .withValues(
                                      alpha: theme.brightness == Brightness.dark
                                          ? 0.20
                                          : 0.12,
                                    ),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.shield_rounded,
                            size: 34,
                            color: theme.brightness == Brightness.dark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'KeyNest Vaults',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Open a KeePass (.kdbx) file or create a new encrypted database.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.brightness == Brightness.dark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                        ),
                      ),
                      const SizedBox(height: 20),

                      KeyNestSurfaceCard(
                        onClick: () => _openLocalOrInternalFile(context),
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            KeyNestCompactIconTile(
                              size: 44,
                              cornerRadius: 12,
                              containerColor:
                                  (theme.brightness == Brightness.dark
                                          ? KeyNestPalette.primaryDark
                                          : KeyNestPalette.primary)
                                      .withValues(
                                        alpha:
                                            theme.brightness == Brightness.dark
                                            ? 0.20
                                            : 0.12,
                                      ),
                              contentColor: theme.brightness == Brightness.dark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary,
                              child: Icon(
                                Icons.folder_open_rounded,
                                color: theme.brightness == Brightness.dark
                                    ? KeyNestPalette.primaryDark
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
                                    loc.openLocalFile,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Open a .kdbx file from phone storage or documents',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.brightness == Brightness.dark
                                          ? KeyNestPalette.textSecondaryDark
                                          : KeyNestPalette.textSecondaryLight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_ios_rounded,
                              size: 16,
                              color: theme.brightness == Brightness.dark
                                  ? KeyNestTokens.darkOutline
                                  : KeyNestTokens.lightOutline,
                            ),
                          ],
                        ),
                      ),

                      KeyNestSurfaceCard(
                        onClick: () =>
                            Navigator.of(context).push(CreateFile.route()),
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            KeyNestCompactIconTile(
                              size: 44,
                              cornerRadius: 12,
                              containerColor: KeyNestPalette.success.withValues(
                                alpha: 0.12,
                              ),
                              contentColor: KeyNestPalette.success,
                              child: const Icon(
                                Icons.add_circle_outline_rounded,
                                color: KeyNestPalette.success,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    loc.createNewFile,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Create a new encrypted database on your device',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.brightness == Brightness.dark
                                          ? KeyNestPalette.textSecondaryDark
                                          : KeyNestPalette.textSecondaryLight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_ios_rounded,
                              size: 16,
                              color: theme.brightness == Brightness.dark
                                  ? KeyNestTokens.darkOutline
                                  : KeyNestTokens.lightOutline,
                            ),
                          ],
                        ),
                      ),

                      if (cloudStorageBloc
                          .availableCloudStorage
                          .isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: cloudStorageBloc.availableCloudStorage.map((
                            cs,
                          ) {
                            return ActionChip(
                              avatar: cs.displayIcon.iconData.widget(size: 16),
                              label: Text(cs.displayName),
                              onPressed: () =>
                                  _loadFromCloudStorage(context, cs),
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'RECENT VAULTS',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                          color: theme.brightness == Brightness.dark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (appData.previousFiles.isNotEmpty)
                        Builder(
                          builder: (context) {
                            final validFiles = appData.previousFiles.reversed
                                .where((f) {
                                  if (f.sourceType ==
                                      OpenedFilesSourceType.Local) {
                                    if (f.filePickerIdentifier != null) {
                                      return true;
                                    }
                                    try {
                                      return FileSourceLocal.localFile(
                                        f.sourcePath,
                                      ).existsSync();
                                    } catch (_) {
                                      return false;
                                    }
                                  }
                                  return true;
                                })
                                .take(5)
                                .toList();
                            if (validFiles.isEmpty) {
                              return KeyNestSurfaceCard(
                                padding: const EdgeInsets.all(20),
                                child: Center(
                                  child: Text(
                                    loc.noFilesHaveBeenOpenYet,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.brightness == Brightness.dark
                                          ? KeyNestPalette.textSecondaryDark
                                          : KeyNestPalette.textSecondaryLight,
                                    ),
                                  ),
                                ),
                              );
                            }
                            return Column(
                              children: validFiles.map((f) {
                                final source = f.toFileSource(cloudStorageBloc);
                                return OpenedFileTile(
                                  openedFile: source,
                                  color: f.color,
                                  onPressed: () =>
                                      _loadAndGoToCredentials(source),
                                  onLongPressed: () {
                                    KeyNestBottomSheet.show<void>(
                                      context: context,
                                      builder: (ctx) => KeyNestBottomSheet(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                left: 4,
                                                bottom: 12,
                                              ),
                                              child: Text(
                                                source.displayName,
                                                style: theme
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                              ),
                                            ),
                                            KeyNestCompactCard(
                                              onClick: () async {
                                                await appDataBloc.update((
                                                  builder,
                                                  data,
                                                ) {
                                                  builder.previousFiles.remove(
                                                    f,
                                                  );
                                                });
                                                KeyNestVaultScope.instance
                                                    .clearVaultFromAllTabs(
                                                      f.uuid,
                                                    );
                                                KeyNestVaultScope.instance
                                                    .clearVaultFromAllTabs(
                                                      f.name,
                                                    );
                                                KeyNestVaultScope.instance
                                                    .clearVaultFromAllTabs(
                                                      f.sourcePath,
                                                    );
                                                unawaited(
                                                  DropboxSyncStateStore()
                                                      .clearVaultSyncState(
                                                        f.uuid,
                                                      ),
                                                );
                                                unawaited(
                                                  GoogleDriveSyncStateStore()
                                                      .clearVaultSyncState(
                                                        f.uuid,
                                                      ),
                                                );
                                                Navigator.of(ctx).pop();
                                              },
                                              child: Row(
                                                children: [
                                                  KeyNestCompactIconTile(
                                                    containerColor:
                                                        KeyNestTokens
                                                            .darkErrorContainer
                                                            .withValues(
                                                              alpha: 0.3,
                                                            ),
                                                    contentColor: KeyNestTokens
                                                        .lightError,
                                                    child: const Icon(
                                                      Icons
                                                          .remove_circle_outline_rounded,
                                                      size: 20,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 14),
                                                  Expanded(
                                                    child: Text(
                                                      loc.removerecentfile,
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
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
                                );
                              }).toList(),
                            );
                          },
                        )
                      else
                        KeyNestSurfaceCard(
                          padding: const EdgeInsets.all(20),
                          child: Center(
                            child: Text(
                              loc.noFilesHaveBeenOpenYet,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.brightness == Brightness.dark
                                    ? KeyNestTokens.darkOnSurfaceVariant
                                    : KeyNestTokens.lightOnSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadFromCloudStorage(
    BuildContext context,
    CloudStorageProvider cs,
  ) async {
    if (!cs.isAuthenticated) {
      final connected = await KeyNestCloudConnectModal.show(context, cs);
      if (connected != true || !mounted) {
        return;
      }
      setState(() {});
    }
    if (cs is GoogleDriveProvider || cs is DropboxProvider) {
      await Navigator.of(
        context,
      ).push(KeyNestCloudVaultBrowserScreen.route(cs));
      return;
    }
    final source = await Navigator.of(
      context,
    ).push(CloudStorageSelector.route(cs, CloudStorageOpenConfig()));
    if (source != null && mounted) {
      await Navigator.of(
        context,
      ).push(CredentialsScreen.route(source.fileSource));
    }
  }

  Future<void> _openLocalOrInternalFile(BuildContext context) async {
    if (!KeyNestPlatform.isWeb) {
      await showModalBottomSheet<void>(
        context: context,
        routeSettings: const RouteSettings(name: '/openfileLocal/chooser'),
        builder: (context) => OpenFileBottomSheet(
          openFilePickerWritable: () => _openLocalFile(context),
        ),
      );
      return;
    }
    await _openLocalFile(context);
  }

  Future<void> _openLocalFile(BuildContext context) async {
    if (KeyNestPlatform.isWeb) {
      const typeGroup = XTypeGroup(
        label: 'KeePass Databases (*.kdbx)',
        extensions: ['kdbx'],
      );
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file != null) {
        final bytes = await file.readAsBytes();
        final dbName = path.basenameWithoutExtension(file.name);
        final source = FileSourceWeb(
          databaseName: dbName.isNotEmpty ? dbName : 'vault',
          uuid: AppDataBloc.createUuid(),
          initialCachedContent: FileContent(bytes),
        );
        await source.contentWrite(bytes, metadata: <String, dynamic>{});
        if (!context.mounted) {
          return;
        }
        await Navigator.of(context).push(
          CredentialsScreen.route(source),
        );
      }
      return;
    }

    if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
      await _openIosAndAndroidLocalFilePicker();
    } else {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'KeePass Databases (*.kdbx)',
            extensions: ['kdbx'],
          ),
        ],
      );
      if (file != null) {
        String? macOsBookmark;
        if (KeyNestPlatform.isMacOS) {
          macOsBookmark = await SecureBookmarks().bookmark(io.File(file.path));
        }
        if (!context.mounted) {
          return;
        }
        await Navigator.of(context).push(
          CredentialsScreen.route(
            FileSourceLocal(
              FileSourceLocal.localFile(file.path),
              uuid: AppDataBloc.createUuid(),
              macOsSecureBookmark: macOsBookmark,
              filePickerIdentifier: null,
            ),
          ),
        );
      }
    }
  }

  static bool isValidKdbxHeader(Uint8List bytes) =>
      SelectFileScreen.isValidKdbxHeader(bytes);

  Future<void> _openIosAndAndroidLocalFilePicker() async {
    try {
      await FilePickerWritable().openFile((fileInfo, file) async {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          if (!mounted) {
            return;
          }
          await DialogUtils.showSimpleAlertDialog(
            context,
            'Empty File',
            'The selected file "${fileInfo.fileName ?? 'database'}" is empty (0 bytes). Please select a valid KeePass (.kdbx) file.',
            routeAppend: 'emptyFile',
          );
          return;
        }
        if (bytes.length >= 13 &&
            String.fromCharCodes(bytes.sublist(0, 13)) == '<placeholder>') {
          if (!mounted) {
            return;
          }
          await DialogUtils.showSimpleAlertDialog(
            context,
            'Incomplete / Corrupted File',
            'The selected file "${fileInfo.fileName ?? 'database'}" contains placeholder data from an incomplete file creation or save. Please select a valid .kdbx file or create a new database.',
            routeAppend: 'placeholderFile',
          );
          return;
        }
        if (!isValidKdbxHeader(bytes)) {
          if (!mounted) {
            return;
          }
          await DialogUtils.showSimpleAlertDialog(
            context,
            'Invalid KeePass File',
            'The file "${fileInfo.fileName ?? 'database'}" does not have a valid KeePass header structure. Please verify this is a genuine .kdbx database file.',
            routeAppend: 'invalidKdbx',
          );
          return;
        }
        if (!mounted) {
          return;
        }
        await Navigator.of(context).push(
          CredentialsScreen.route(
            FileSourceLocal(
              FileSourceLocal.localFile(file.path),
              uuid: AppDataBloc.createUuid(),
              filePickerIdentifier: fileInfo.toJsonString(),
              initialCachedContent: FileContent(bytes),
            ),
          ),
        );
      });
    } catch (e, stackTrace) {
      _logger.warning(
        'Error while opening file with file picker',
        e,
        stackTrace,
      );
      if (!mounted) {
        return;
      }
      await DialogUtils.showSimpleAlertDialog(
        context,
        'Error Opening File',
        'Could not access the selected file: $e',
        routeAppend: 'pickerError',
      );
    }
  }

  void _loadAndGoToCredentials(FileSource source) {
    final loc = AppLocalizations.of(context);
    asyncRunTask((progress) {
      return source
          .content()
          .last
          .then((value) {
            return Navigator.of(context).push(CredentialsScreen.route(source));
          })
          .catchError((Object error, StackTrace stackTrace) {
            _logger.fine('Error while trying to load file source $source');
            DialogUtils.showErrorDialog(
              context,
              loc.errorLoadFileFromSourceTitle,
              loc.errorLoadFileFromSourceBody(source, error),
            );
            return Future<dynamic>.error(error, stackTrace);
          });
    }, label: loc.loadingFile);
    setState(() {});
  }
}

class OpenFileBottomSheet extends StatelessWidget {
  const OpenFileBottomSheet({
    super.key,
    required this.openFilePickerWritable,
  });

  final Future<void> Function() openFilePickerWritable;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: 16,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const FaIcon(FontAwesomeIcons.hardDrive, size: 24),
            title: Text(
              loc.filePicker,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(loc.filePickerSubtitle),
            onTap: () async {
              Navigator.of(context).pop();
              await openFilePickerWritable();
            },
          ),
          ListTile(
            leading: const ImageIcon(
              AssetImage('assets/images/logo_icon.png'),
              size: 24,
            ),
            title: Text(
              loc.internalFile,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(loc.internalFileSubtitle),
            onTap: () async {
              Navigator.of(context).pop();
              final rootDirectory = await PathUtils().getAppDocDirectory(
                ensureCreated: true,
              );
              _logger.fine('Opening picker for $rootDirectory');
              final filePath = await FilesystemPicker.open(
                context: context,
                rootDirectory: rootDirectory,
                fsType: FilesystemType.file,
                allowedExtensions: [AppConstants.kdbxExtension],
                fileTileSelectMode: FileTileSelectMode.wholeTile,
              );
              if (filePath == null) {
                _logger.fine('User canceled FilesystemPicker.');
                return;
              }
              await Navigator.of(context).push(
                CredentialsScreen.route(
                  FileSourceLocal(
                    FileSourceLocal.localFile(filePath),
                    uuid: AppDataBloc.createUuid(),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class OpenedFileTile extends StatelessWidget {
  const OpenedFileTile({
    super.key,
    required this.openedFile,
    this.onPressed,
    this.onLongPressed,
    required this.color,
  });

  final FileSource openedFile;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPressed;
  final Color? color;

  String get _displayPath {
    try {
      return openedFile.displayPath;
    } catch (e) {
      return CharConstants.empty;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return KeyNestCompactCard(
      onClick: onPressed,
      onLongPress: onLongPressed,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          KeyNestCompactIconTile(
            containerColor: color?.withValues(alpha: isDark ? 0.25 : 0.15),
            contentColor: color,
            child: openedFile.displayIcon.iconData.widget(
              color:
                  color ??
                  (isDark
                      ? KeyNestTokens.darkPrimary
                      : KeyNestTokens.lightPrimary),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  openedFile.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _displayPath,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isDark
                        ? KeyNestTokens.darkOnSurfaceVariant
                        : KeyNestTokens.lightOnSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onLongPressed,
            icon: Icon(
              Icons.more_vert_rounded,
              size: 20,
              color: isDark
                  ? KeyNestTokens.darkOutline
                  : KeyNestTokens.lightOutline,
            ),
            tooltip: 'Vault options',
          ),
        ],
      ),
    );
  }
}

class SelectFileActionChrome extends StatelessWidget {
  const SelectFileActionChrome({
    super.key,
    this.backgroundColor,
    required this.child,
  });

  final Widget child;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 120,
        maxWidth: 120,
        minHeight: 96,
      ),
      child: Material(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        color: backgroundColor ?? theme.primaryColor,
        elevation: 4,
        child: child,
      ),
    );
  }
}

class SelectFileAction extends StatelessWidget {
  const SelectFileAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.backgroundColor,
  });

  final IconDataWrapperBase icon;
  final String label;
  final Color? backgroundColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SelectFileActionChrome(
      backgroundColor: backgroundColor,
      child: InkWell(
        onTap: onPressed,
        child: SelectFileActionContent(icon: icon, label: label),
      ),
    );
  }
}

class SelectFileActionContent extends StatelessWidget {
  const SelectFileActionContent({
    super.key,
    required this.icon,
    required this.label,
  });

  final IconDataWrapperBase icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: DefaultTextStyle(
        style: theme.primaryTextTheme.bodyMedium!,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            icon.widget(
              color: theme.primaryTextTheme.bodyMedium!.color!.withValues(
                alpha: 0.8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.primaryTextTheme.bodyMedium!.copyWith(
                letterSpacing: 0.9,
              ),
              strutStyle: const StrutStyle(leading: 0.2),
            ),
          ],
        ),
      ),
    );
  }
}

class SelectUrlDialog extends StatefulWidget {
  @override
  _SelectUrlDialogState createState() => _SelectUrlDialogState();
}

class _SelectUrlDialogState extends State<SelectUrlDialog> {
  final _formKey = GlobalKey<FormState>();
  Uri? _enteredUrl;

  String? Function(String? urlString) _parseUrl(AppLocalizations loc) {
    return (urlString) {
      try {
        final uri = Uri.parse(urlString!);
        if (!uri.scheme.startsWith(nonNls('http'))) {
          // NON-NLS
          _logger.fine(
            'User entered url with invalid schema ${FormatUtils.anonymizeUrl(urlString)}',
          );
          return loc.loadFromUrlErrorEnterFullUrl;
        }
        _enteredUrl = uri;
        return null;
      } on FormatException catch (e) {
        _logger.fine(
          'User entered invalid url ${FormatUtils.anonymizeUrl(urlString!)}',
          e,
        );
        return loc.loadFromUrlErrorInvalidUrl;
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final matLoc = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(loc.loadFromUrl),
      content: Form(
        key: _formKey,
        child: TextFormField(
          validator: _parseUrl(loc),
          onSaved: _parseUrl(loc),
          decoration: InputDecoration(
            icon: const Icon(Icons.cloud_download),
            labelText: loc.loadFromUrlEnterUrl,
            hintText: nonNls('https://'),
          ),
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text(loc.cancel),
        ),
        TextButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              _formKey.currentState!.save();
              Navigator.of(
                context,
              ).pop(FileSourceUrl(_enteredUrl, uuid: AppDataBloc.createUuid()));
            } else {
              Navigator.of(context).pop();
            }
          },
          child: Text(matLoc.okButtonLabel),
        ),
      ],
    );
  }
}

class CredentialsScreen extends StatefulWidget {
  const CredentialsScreen({super.key, required this.kdbxFilePath});

  static Route<void> route(FileSource kdbxFilePath) => MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/credentials'),
    builder: (context) => CredentialsScreen(
      kdbxFilePath: kdbxFilePath,
    ),
  );

  final FileSource kdbxFilePath;

  @override
  _CredentialsScreenState createState() => _CredentialsScreenState();
}

abstract class KeyFile {
  Future<Uint8List> readAsBytes();

  String? get displayName;

  String? get formatName;
}

class KeyFileFile implements KeyFile {
  KeyFileFile(this.file, {this.cachedBytes, this.formatName});

  final XFile file;
  final Uint8List? cachedBytes;
  @override
  final String? formatName;

  @override
  Future<Uint8List> readAsBytes() async {
    if (cachedBytes != null) {
      return cachedBytes!;
    }
    return await file.readAsBytes();
  }

  @override
  String get displayName =>
      path.basename(file.name.isNotEmpty ? file.name : file.path);
}

class KeyFileInfo implements KeyFile {
  KeyFileInfo({required this.fileInfo, required this.bytes, this.formatName});

  final FileInfo fileInfo;
  final Uint8List bytes;
  @override
  final String? formatName;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  String? get displayName => fileInfo.fileName;
}

class KeyFileResolved implements KeyFile {
  KeyFileResolved({
    required this.displayName,
    required this.bytes,
    this.reference,
    this.formatName,
  });

  @override
  final String displayName;
  final Uint8List bytes;
  final KeyFileReference? reference;
  @override
  final String? formatName;

  @override
  Future<Uint8List> readAsBytes() async => bytes;
}

class _CredentialsScreenState extends State<CredentialsScreen> {
  final _formKey = GlobalKey<FormState>();
  String? _invalidPassword;
  String? _credentialErrorMessage;
  String? _keyFileMissingNotice;

  final _controller = TextEditingController();
  Future<bool>? _loadingFile;

  late KdbxBloc _kdbxBloc;
  bool _biometricQuickUnlockSupported = false;
  bool? _biometricQuickUnlockActivated;

  KeyFile? _keyFile;

  @override
  void initState() {
    super.initState();
    unawaited(
      (() async {
        _logger.finest('Precaching...');
        await widget.kdbxFilePath.contentPreCache();
        await _loadSavedKeyFileReference();
      })(),
    );
  }

  Future<void> _loadSavedKeyFileReference() async {
    try {
      final ref = await KeyNestKeyFileStore.instance.getReference(
        widget.kdbxFilePath.uuid,
      );
      if (ref != null && mounted) {
        final bytes = await KeyNestKeyFileStore.instance.resolveKeyFileBytes(
          widget.kdbxFilePath.uuid,
        );
        if (bytes != null && mounted) {
          try {
            final parsed = KeyNestKeyFile.parse(
              bytes,
              fileName: ref.displayName,
            );
            setState(() {
              _keyFile = KeyFileResolved(
                displayName: ref.displayName,
                bytes: bytes,
                reference: ref,
                formatName: parsed.displayName,
              );
            });
          } catch (e) {
            if (mounted) {
              setState(() {
                _keyFileMissingNotice =
                    'Key file "${ref.displayName}" is damaged or invalid. Please locate and select the correct file.';
              });
            }
          }
        } else if (mounted) {
          setState(() {
            _keyFileMissingNotice =
                'Vault is configured with key file "${ref.displayName}". Please locate and select it.';
          });
        }
      }
    } catch (e) {
      _logger.fine('Failed to load saved key file reference: $e');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _kdbxBloc = Provider.of<KdbxBloc>(context);
    _kdbxBloc.quickUnlockStorage.supportsBiometricKeyStore().then(
      (biometricQuickUnlock) => setState(() {
        _biometricQuickUnlockSupported = biometricQuickUnlock;
        _biometricQuickUnlockActivated ??= true;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final loc = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: isDark
          ? KeyNestTokens.darkBackground
          : KeyNestTokens.lightBackground,
      appBar: AppBar(
        title: Text(loc.credentialsAppBarTitle),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: KeyNestTokens.contentMaxWidth,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  KeyNestSurfaceCard(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        KeyNestCompactIconTile(
                          size: 48,
                          cornerRadius: KeyNestTokens.radiusCompact,
                          child: const Icon(Icons.shield_rounded, size: 26),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                loc.credentialLabel,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: isDark
                                      ? KeyNestTokens.darkOnSurfaceVariant
                                      : KeyNestTokens.lightOnSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.kdbxFilePath.displayName,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.kdbxFilePath.displayPath,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: isDark
                                      ? KeyNestTokens.darkOnSurfaceVariant
                                      : KeyNestTokens.lightOnSurfaceVariant,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  PasswordInputField(
                    controller: _controller,
                    labelText: loc.masterPasswordInputLabel,
                    autovalidateMode: _invalidPassword != null
                        ? AutovalidateMode.always
                        : AutovalidateMode.onUserInteraction,
                    validator: (val) {
                      if (_invalidPassword != null && _invalidPassword == val) {
                        return _credentialErrorMessage ??
                            loc.masterPasswordIncorrectValidator;
                      }
                      return null;
                    },
                    onEditingComplete: () async {
                      FocusScope.of(context).unfocus();
                      await _tryUnlock();
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_keyFileMissingNotice != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.amber.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.info_outline_rounded,
                            color: Colors.amber,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _keyFileMissingNotice!,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? Colors.amber.shade200
                                    : Colors.amber.shade900,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  KeyNestCompactCard(
                    onClick: () async {
                      _invalidPassword = null;
                      _credentialErrorMessage = null;
                      if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
                        final fileInfo = await FilePickerWritable().openFile((
                          fileInfo,
                          file,
                        ) async {
                          final bytes = await file.readAsBytes();
                          try {
                            final parsed = KeyNestKeyFile.parse(
                              bytes,
                              fileName: fileInfo.fileName,
                            );
                            final keyFile = KeyFileInfo(
                              fileInfo: fileInfo,
                              bytes: bytes,
                              formatName: parsed.displayName,
                            );
                            setState(() {
                              _keyFile = keyFile;
                              _keyFileMissingNotice = null;
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
                            return null;
                          }
                          return fileInfo;
                        });
                        if (fileInfo == null && _keyFile == null) {
                          setState(() => _keyFile = null);
                        }
                      } else {
                        const typeGroup = XTypeGroup(
                          label: 'Key Files (*.key, *.keyx, *.xml)',
                          extensions: ['key', 'keyx', 'xml', 'bin', 'txt'],
                        );
                        final file = await openFile(
                          acceptedTypeGroups: [typeGroup],
                        );
                        if (file != null) {
                          final bytes = await file.readAsBytes();
                          try {
                            final parsed = KeyNestKeyFile.parse(
                              bytes,
                              fileName: file.name,
                            );
                            setState(() {
                              _keyFile = KeyFileFile(
                                file,
                                cachedBytes: bytes,
                                formatName: parsed.displayName,
                              );
                              _keyFileMissingNotice = null;
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
                    },
                    child: Row(
                      children: [
                        KeyNestCompactIconTile(
                          size: 36,
                          child: FaIcon(
                            _keyFile == null
                                ? FontAwesomeIcons.folderOpen
                                : FontAwesomeIcons.key,
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _keyFile == null
                                    ? loc.useKeyFile
                                    : path.basename(_keyFile!.displayName!),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: _keyFile != null
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (_keyFile != null &&
                                  _keyFile!.formatName != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  _keyFile!.formatName!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 11,
                                    color: isDark
                                        ? KeyNestTokens.textSecondaryDark
                                        : KeyNestTokens.textSecondaryLight,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (_keyFile != null)
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () async {
                              final ref = await KeyNestKeyFileStore.instance
                                  .getReference(widget.kdbxFilePath.uuid);
                              if (mounted) {
                                setState(() {
                                  _keyFile = null;
                                  if (ref != null) {
                                    _keyFileMissingNotice =
                                        'Vault is configured with key file "${ref.displayName}". Please locate and select it.';
                                  } else {
                                    _keyFileMissingNotice = null;
                                  }
                                });
                              }
                            },
                            tooltip: 'Deselect key file',
                          )
                        else
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: isDark
                                ? KeyNestTokens.darkOutline
                                : KeyNestTokens.lightOutline,
                          ),
                      ],
                    ),
                  ),
                  if (_biometricQuickUnlockSupported) ...[
                    const SizedBox(height: 12),
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
                  const SizedBox(height: 28),
                  if (_loadingFile != null)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: KeyNestProgressIndicator(),
                      ),
                    )
                  else
                    PrimaryButton(
                      key: const ValueKey('continue'),
                      onPressed: () async {
                        await _tryUnlock();
                      },
                      icon: const Icon(Icons.lock_open_rounded, size: 20),
                      child: Text(loc.dialogContinue),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _fileExtension() {
    final filePath = widget.kdbxFilePath.displayPath;
    return path.extension(filePath);
  }

  Future<void> _tryUnlock() async {
    if (_formKey.currentState!.validate()) {
      final deps = Provider.of<Deps>(context, listen: false);
      final loc = AppLocalizations.of(context);
      final analytics = deps.analytics;
      final kdbxBloc = deps.kdbxBloc;
      final pw = _controller.text;

      // Enforce persistent vault-specific key file requirement:
      // If this vault has a configured key file reference, a key file must be provided.
      // Do not silently ignore, bypass, or attempt password-only decryption.
      final savedRef = await KeyNestKeyFileStore.instance.getReference(
        widget.kdbxFilePath.uuid,
      );
      if (savedRef != null && _keyFile == null) {
        setState(() {
          _credentialErrorMessage =
              'This vault is protected with key file "${savedRef.displayName}". Please locate and select the key file to unlock.';
          _keyFileMissingNotice =
              'Vault is configured with key file "${savedRef.displayName}". Please locate and select it.';
          _invalidPassword = pw;
          _formKey.currentState!.validate();
        });
        return;
      }

      final stopWatch = Stopwatch();
      try {
        stopWatch.start();
        final Credentials credentials;
        if (_keyFile != null) {
          final keyFileContents = await _keyFile!.readAsBytes();
          credentials = KeyNestKeyFile.createCompositeCredentials(
            password: pw.isNotEmpty ? pw : null,
            keyFileBytes: keyFileContents,
          );
        } else {
          credentials = Credentials.composite(
            pw == CharConstants.empty ? null : ProtectedValue.fromString(pw),
            null,
          );
        }
        final openFileStream = kdbxBloc.openFile(
          widget.kdbxFilePath,
          credentials,
          addToQuickUnlock: _biometricQuickUnlockActivated ?? false,
        );
        // TODO handle subsequent errors.
        final openIt = StreamIterator(openFileStream);
        _loadingFile = openIt.moveNext();
        setState(() {});
        final result = await _loadingFile;
        _logger.info('waited for file $result');
        await KeyNestPreferencesService.setCompletedOnboarding(true);
        final fileResult = openIt.current;
        analytics.trackTiming(
          'tryUnlockFile',
          fileResult.unlockStopwatch!.elapsedMilliseconds,
          category: 'unlock',
          label: 'successfully unlocked (${fileResult.fileContent!.source})',
        );
        analytics.events.trackTryUnlock(
          action: TryUnlockResult.success,
          ext: _fileExtension(),
          source: widget.kdbxFilePath.typeDebug,
        );
        final fileSource = fileResult.kdbxOpenedFile!.fileSource;
        if (_keyFile != null) {
          String? macOsBookmark;
          String? filePath;
          String? filePickerIdentifier;
          if (_keyFile is KeyFileFile) {
            filePath = (_keyFile as KeyFileFile).file.path;
            if (KeyNestPlatform.isMacOS) {
              try {
                macOsBookmark = await SecureBookmarks().bookmark(
                  io.File(filePath),
                );
              } catch (_) {}
            }
          } else if (_keyFile is KeyFileInfo) {
            filePickerIdentifier = (_keyFile as KeyFileInfo).fileInfo
                .toJsonString();
          } else if (_keyFile is KeyFileResolved) {
            final ref = (_keyFile as KeyFileResolved).reference;
            filePath = ref?.filePath;
            filePickerIdentifier = ref?.filePickerIdentifier;
            macOsBookmark = ref?.macOsBookmark;
          }

          await KeyNestKeyFileStore.instance.saveReference(
            vaultUuid: fileSource.uuid,
            displayName: _keyFile!.displayName ?? 'keyfile',
            filePath: filePath,
            filePickerIdentifier: filePickerIdentifier,
            macOsBookmark: macOsBookmark,
            formatName: _keyFile!.formatName,
          );
        }
        KeyNestVaultScope.instance.setSelectedVault(
          kdbxBloc,
          fileResult.kdbxOpenedFile!.kdbxFile,
        );
        KeyNestVaultScope.instance.notifyScopeChanged();
        unawaited(
          kdbxBloc.continueLoadInBackground(
            openIt,
            debugName: fileSource.displayName,
            fileSource: fileSource,
          ),
        );
        if (await AutofillService().hasPendingAutofillRequest() && mounted) {
          await AutofillResumeHelper.resumeAutofill(context, kdbxBloc);
          return;
        }
        await Navigator.of(
          context,
        ).pushAndRemoveUntil(MainAppScaffold.route(), (route) => false);
      } on KdbxInvalidKeyException catch (e, stackTrace) {
        _logger.fine('Invalid credentials.', e, stackTrace);
        analytics.trackTiming(
          'tryUnlockFile',
          stopWatch.elapsedMilliseconds,
          category: 'unlock',
          label: 'invalid credentials',
        );
        analytics.events.trackTryUnlock(
          action: TryUnlockResult.invalidCredential,
          ext: _fileExtension(),
          source: widget.kdbxFilePath.typeDebug,
        );
        if (!mounted) {
          _logger.warning(
            'Credential screen no longer mounted when handling error.',
          );
          return;
        }
        setState(() {
          _invalidPassword = pw;
          if (_keyFile == null) {
            _credentialErrorMessage =
                'Invalid master password or missing key file. If this vault requires a key file, please select it below.';
          } else {
            _credentialErrorMessage =
                'Decryption failed. The master password or key file is incorrect.';
          }
          _formKey.currentState!.validate();
        });
      } on FileAlreadyOpenException catch (e, stackTrace) {
        _logger.fine('File already open.', e, stackTrace);
        final dbName = widget.kdbxFilePath.displayName;
        if (mounted) {
          await DialogUtils.showSimpleAlertDialog(
            context,
            'Vault Already Open',
            'The database "$dbName" is already open in KeyNest.',
            routeAppend: 'alreadyOpen',
          );
          if (mounted) {
            Navigator.of(context).pop();
          }
        }
      } on KdbxInvalidFileStructure catch (e, stackTrace) {
        _logger.fine(
          'Invalid file structore for file ${widget.kdbxFilePath}',
          e,
          stackTrace,
        );
        await _handleOpenError(
          analytics: analytics,
          result: TryUnlockResult.invalidFileStructure,
          errorTitle: loc.errorOpenFileInvalidFileStructureTitle,
          errorBody: loc.errorOpenFileInvalidFileStructureBody(
            widget.kdbxFilePath.displayName,
          ),
          stopWatch: stopWatch,
        );
      } catch (e, stackTrace) {
        _logger.fine('Unable to open kdbx file. ', e, stackTrace);
        await _handleOpenError(
          analytics: analytics,
          result: TryUnlockResult.failure,
          errorTitle: loc.errorUnlockFileTitle,
          errorBody: loc.errorUnlockFileBody(e),
          stopWatch: stopWatch,
        );
      } finally {
        if (mounted) {
          setState(() {
            _loadingFile = null;
          });
        } else {
          _logger.warning(
            'User navigated away from $runtimeType, '
            'not updating UI.',
          );
        }
      }
    }
  }

  Future<void> _handleOpenError({
    required Analytics analytics,
    required TryUnlockResult result,
    required String errorTitle,
    required String errorBody,
    required Stopwatch stopWatch,
  }) async {
    analytics.trackTiming(
      'tryUnlockFile',
      stopWatch.elapsedMilliseconds,
      category: 'unlock',
      label: 'error: $result',
    );
    analytics.events.trackTryUnlock(
      action: TryUnlockResult.alreadyOpen,
      ext: _fileExtension(),
      source: widget.kdbxFilePath.typeDebug,
    );
    await DialogUtils.showErrorDialog(
      context,
      errorTitle,
      errorBody,
      routeAppend: 'errorOpenFile',
    );
  }
}
