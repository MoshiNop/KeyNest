import 'dart:io';
import 'package:autofill_service/autofill_service.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/cloud_storage_ui.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_sync_state.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_sync_state.dart';
import 'package:keynest/cloud_storage/keynest_cloud_sync_manager.dart';
import 'package:keynest/cloud_storage/webdav/webdav_provider.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_dynamic_icon_service.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/keynest_cloud_management_screen.dart';
import 'package:keynest/ui/screens/keynest_data_screens.dart';
import 'package:keynest/ui/screens/keynest_duplicates_screen.dart';
import 'package:keynest/ui/screens/keynest_import_export.dart';
import 'package:keynest/ui/screens/keynest_merge_vaults_screen.dart';
import 'package:keynest/ui/screens/keynest_vault_health_screen.dart';
import 'package:keynest/ui/screens/keynest_vault_manager_screen.dart';
import 'package:keynest/ui/screens/locked_screen.dart';
import 'package:keynest/ui/screens/master_password_change.dart';
import 'package:keynest/ui/screens/password_generator.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/ui/widgets/keyboard_handler.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_cloud_connect_modal.dart';
import 'package:keynest/ui/widgets/keynest_popup_menu.dart';
import 'package:keynest/ui/widgets/keynest_settings_tile.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

final _logger = Logger('preferences');

class PreferencesScreen extends StatelessWidget {
  static Route<void> route() => KeyNestPushPageRoute(
    settings: const RouteSettings(name: '/preferences'),
    builder: (context) => PreferencesScreen(),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final loc = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          loc.preferenceTitle,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: isDark
                ? KeyNestPalette.textPrimaryDark
                : KeyNestPalette.textPrimaryLight,
          ),
        ),
        actions: [PreferencesOverflowMenuAction()],
      ),
      body: Stack(
        children: [
          if (isDark) ...[
            // Atmospheric soft ambient background blobs matching reference
            Positioned(
              top: -80,
              right: -60,
              width: 320,
              height: 320,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFF1E3A6E).withValues(alpha: 0.18),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 280,
              left: -80,
              width: 280,
              height: 280,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFF0F3B56).withValues(alpha: 0.14),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 32),
              child: PreferencesBody(),
            ),
          ),
        ],
      ),
    );
  }
}

class PreferencesBody extends StatefulWidget {
  @override
  _PreferencesBodyState createState() => _PreferencesBodyState();
}

class _PreferencesBodyState extends State<PreferencesBody>
    with StreamSubscriberMixin, WidgetsBindingObserver {
  KdbxBloc? _kdbxBloc;
  bool _isSyncingVaults = false;
  bool _isSyncingDropbox = false;
  String? _dropboxSyncStatus;
  bool _isSyncingGoogleDrive = false;
  String? _googleDriveSyncStatus;

  AutofillServiceStatus? _autofillStatus;
  AutofillPreferences? _autofillPrefs;

  /// Browsers which will not forward anything to us until the user enables
  /// third party autofill in the browser settings.
  List<BrowserAutofillStatus> _browsersWithoutAutofill = [];

  late AppDataBloc _appDataBloc;
  AppData? _appData;

  Analytics get _analytics => context.read<Analytics>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _doInit();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // the user might have changed autofill settings of the system or of a
      // browser while we were in the background.
      _doInit();
    }
  }

  Future<void> _doInit() async {
    if (KeyNestPlatform.isWeb) {
      return;
    }
    final autofill = AutofillService();
    _autofillStatus = await autofill.status();
    if (_autofillStatus != AutofillServiceStatus.unsupported) {
      _autofillPrefs = await autofill.getPreferences();
      _browsersWithoutAutofill = (await autofill.getBrowserAutofillStatus())
          .where((browser) => !browser.thirdPartyModeEnabled)
          .toList();
    }
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_kdbxBloc == null) {
      _kdbxBloc = Provider.of<KdbxBloc>(context);
      _appDataBloc = Provider.of<AppDataBloc>(context);
      handleSubscription(
        _appDataBloc.store.onValueChangedAndLoad.listen((appData) {
          setState(() {
            _appData = appData;
          });
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appData = _appData;
    if (appData == null) {
      return const Text('loading'); // NON-NLS
    }
    final loc = AppLocalizations.of(context);
    final env = Provider.of<Env>(context);
    final commonFields = context.watch<CommonFields>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cloudStorageBloc = context.watch<CloudStorageBloc>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Autofill Hero Card
        if (_autofillStatus != AutofillServiceStatus.unsupported &&
            _autofillPrefs != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: KeyNestCard(
              padding: const EdgeInsets.all(20),
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
                          color:
                              (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                  .withValues(alpha: isDark ? 0.20 : 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.flash_on_rounded,
                          color: isDark
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
                              'Fill passwords anywhere',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: isDark
                                    ? KeyNestPalette.textPrimaryDark
                                    : KeyNestPalette.textPrimaryLight,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'KeyNest can fill logins automatically in apps and browsers.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 13,
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
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Autofill Diagnostics',
                        icon: const Icon(Icons.troubleshoot_rounded, size: 22),
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                        onPressed: () => _showAutofillDiagnostics(context),
                      ),
                      const SizedBox(width: 8),
                      if (_autofillStatus == AutofillServiceStatus.enabled)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            side: BorderSide(
                              color:
                                  (isDark
                                          ? KeyNestTokens.primaryAccent
                                          : KeyNestPalette.primary)
                                      .withValues(alpha: 0.5),
                            ),
                          ),
                          icon: Icon(
                            Icons.check_circle_rounded,
                            color: isDark
                                ? KeyNestTokens.primaryAccent
                                : KeyNestPalette.primary,
                            size: 18,
                          ),
                          label: Text(
                            'Autofill Active',
                            style: TextStyle(
                              color: isDark
                                  ? KeyNestTokens.primaryAccent
                                  : KeyNestPalette.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          onPressed: () async {
                            await AutofillService().disableAutofillServices();
                            await AutofillService().clearAllCredentials();
                            await _doInit();
                          },
                        )
                      else if (_autofillStatus ==
                          AutofillServiceStatus.disabled)
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary,
                            foregroundColor: isDark
                                ? const Color(0xFF00315D)
                                : Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 10,
                            ),
                          ),
                          icon: const Icon(Icons.touch_app_rounded, size: 18),
                          label: const Text(
                            'Turn on Autofill',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          onPressed: () async {
                            await AutofillService().requestSetAutofillService();
                            await _doInit();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          ..._browsersWithoutAutofill.map(
            (browser) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: KeyNestCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.open_in_browser_rounded,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            loc.browserAutofillThirdPartyModeTitle(
                              browser.label,
                            ),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            loc.browserAutofillThirdPartyModeSubtitle(
                              browser.label,
                            ),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.open_in_new_rounded, size: 20),
                      onPressed: () async {
                        await AutofillService().openBrowserAutofillSettings(
                          browser.packageName,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],

        // Security Settings
        KeyNestSettingsGroup(
          header: 'Security',
          headerIcon: Icons.security_rounded,
          children: [
            KeyNestSettingsTile(
              title: 'Change Master Password',
              subtitle: 'Update master password for open vaults',
              icon: Icons.password_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MasterPasswordChangeScreen.route(),
                );
              },
            ),
            KeyNestSettingsTile(
              title: loc.lockAllFiles,
              subtitle: 'Instantly lock and secure all open vaults',
              icon: Icons.lock_outline_rounded,
              onTap: () async {
                final kdbxBloc = _kdbxBloc ?? context.read<KdbxBloc>();
                if (kdbxBloc.openedFilesWithSources.isNotEmpty) {
                  await kdbxBloc.closeAllFiles(clearQuickUnlock: false);
                  if (context.mounted) {
                    await Navigator.of(
                      context,
                      rootNavigator: true,
                    ).pushAndRemoveUntil(LockedScreen.route(), (_) => false);
                  }
                }
              },
            ),
            KeyNestSettingsTile(
              title: loc.clearQuickUnlock,
              subtitle: loc.clearQuickUnlockSubtitle,
              icon: Icons.fingerprint_rounded,
              onTap: () async {
                final kdbxBloc = _kdbxBloc ?? context.read<KdbxBloc>();
                await kdbxBloc.closeAllFiles(clearQuickUnlock: true);
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(loc.clearQuickUnlockSuccess),
                        duration: const Duration(milliseconds: 1800),
                      ),
                    );
                  await SelectFileScreen.navigate(context);
                }
              },
            ),
            if (KeyNestPlatform.isAndroid)
              KeyNestSettingsTile(
                title: loc.preferenceAllowScreenshots,
                subtitle: 'Disabled by default for security',
                icon: Icons.camera_alt_rounded,
                trailing: Switch(
                  value: !appData.secureWindowOrDefault,
                  onChanged: (value) {
                    _appDataBloc.update(
                      (builder, data) => builder.secureWindow = !value,
                    );
                    _analytics.events.trackPreferences(
                      setting: 'allowScreenshots',
                      to: '$value',
                    );
                  },
                ),
              ),
          ],
        ),

        // Vault & Storage Settings
        KeyNestSettingsGroup(
          header: 'Vault & Storage',
          headerIcon: Icons.folder_open_outlined,
          children: [
            KeyNestSettingsTile(
              title: 'Manage Vaults & Folders',
              subtitle:
                  '${_kdbxBloc?.openedFiles.length ?? 0} active vault(s) • Organize hierarchy',
              icon: Icons.folder_open_rounded,
              onTap: () {
                Navigator.of(context).push(KeyNestVaultManagerScreen.route());
              },
            ),
          ],
        ),

        // Dedicated Vault Merge Settings
        KeyNestSettingsGroup(
          header: 'Vault Merge',
          headerIcon: Icons.merge_type_rounded,
          children: [
            KeyNestSettingsTile(
              title: 'Merge KDBX Vaults',
              subtitle:
                  'Combine entries and folder hierarchies from multiple open vaults',
              icon: Icons.merge_type_rounded,
              onTap: () {
                Navigator.of(context).push(KeyNestMergeVaultsScreen.route());
              },
            ),
          ],
        ),

        // Cloud Storage Services
        KeyNestSettingsGroup(
          header: 'Your Own Cloud',
          headerIcon: Icons.cloud_outlined,
          children: [
            _buildCloudProviderTile(
              provider: cloudStorageBloc.availableCloudStorage.firstWhereOrNull(
                (p) => p is GoogleDriveProvider,
              ),
              name: 'Google Drive',
              subtitle: 'Sync vault databases seamlessly with Google Drive',
              icon: FontAwesomeIcons.googleDrive,
            ),
            if ((cloudStorageBloc.availableCloudStorage.firstWhereOrNull(
                          (p) => p is GoogleDriveProvider,
                        )
                        as GoogleDriveProvider?)
                    ?.isAuthenticated ==
                true) ...[
              _buildGoogleDriveSyncTile(
                cloudStorageBloc.availableCloudStorage.firstWhereOrNull(
                      (p) => p is GoogleDriveProvider,
                    )!
                    as GoogleDriveProvider,
              ),
              _buildGoogleDriveRestoreTile(
                cloudStorageBloc.availableCloudStorage.firstWhereOrNull(
                      (p) => p is GoogleDriveProvider,
                    )!
                    as GoogleDriveProvider,
              ),
            ],
            _buildCloudProviderTile(
              provider: cloudStorageBloc.availableCloudStorage.firstWhereOrNull(
                (p) => p is DropboxProvider,
              ),
              name: 'Dropbox',
              subtitle: 'Connect and synchronize with your Dropbox account',
              icon: FontAwesomeIcons.dropbox,
            ),
            if ((cloudStorageBloc.availableCloudStorage.firstWhereOrNull(
                          (p) => p is DropboxProvider,
                        )
                        as DropboxProvider?)
                    ?.isAuthenticated ==
                true) ...[
              _buildDropboxSyncTile(
                cloudStorageBloc.availableCloudStorage.firstWhereOrNull(
                      (p) => p is DropboxProvider,
                    )!
                    as DropboxProvider,
              ),
              _buildDropboxRestoreTile(
                cloudStorageBloc.availableCloudStorage.firstWhereOrNull(
                      (p) => p is DropboxProvider,
                    )!
                    as DropboxProvider,
              ),
            ],
            _buildCloudProviderTile(
              provider: cloudStorageBloc.availableCloudStorage.firstWhereOrNull(
                (p) => p is WebDavProvider,
              ),
              name: 'WebDAV / Nextcloud',
              subtitle: 'Connect Nextcloud, ownCloud, or custom WebDAV server',
              icon: FontAwesomeIcons.server,
            ),
            KeyNestSettingsTile(
              title: 'Sync Open Vaults Now',
              subtitle: _isSyncingVaults
                  ? 'Synchronizing open vaults with storage, please wait…'
                  : 'Force sync remote cloud storage with local cache',
              icon: _isSyncingVaults
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        ),
                      ),
                    )
                  : Icons.sync_rounded,
              trailing: _isSyncingVaults
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        ),
                      ),
                    )
                  : null,
              onTap: _isSyncingVaults ? null : _syncOpenVaults,
            ),
          ],
        ),

        // Security & Auto-Lock Settings
        KeyNestSettingsGroup(
          header: 'Security & Auto-Lock',
          headerIcon: Icons.lock_clock_outlined,
          children: [
            KeyNestSettingsTile(
              title: 'Auto-Lock Vault',
              subtitle:
                  'Timeout: ${_autoLockLabel(SecuritySettingsStore.instance.autoLockSeconds)}',
              icon: Icons.timer_outlined,
              onTap: () => _showAutoLockPicker(context),
            ),
            KeyNestSettingsTile(
              title: 'Clipboard Auto-Clear',
              subtitle:
                  'Clear copied secrets after: ${_clipboardClearLabel(SecuritySettingsStore.instance.clipboardClearSeconds)}',
              icon: Icons.content_paste_off_rounded,
              onTap: () => _showClipboardClearPicker(context),
            ),
          ],
        ),

        // Data Management
        KeyNestSettingsGroup(
          header: 'Data',
          headerIcon: Icons.dns_outlined,
          children: [
            KeyNestSettingsTile(
              title: 'Import & Export',
              subtitle:
                  'Export KDBX, CSV, JSON • Import Bitwarden, LastPass, 1Password',
              icon: Icons.swap_vert_rounded,
              onTap: () {
                Navigator.of(context).push(KeyNestImportExportScreen.route());
              },
            ),
            KeyNestSettingsTile(
              title: 'Vault Health Overview',
              subtitle:
                  'Check weak passwords, duplicates, 2FA, and card expiry',
              icon: Icons.health_and_safety_outlined,
              onTap: () {
                Navigator.of(context).push(KeyNestVaultHealthScreen.route());
              },
            ),
            KeyNestSettingsTile(
              title: 'Find & Clean Duplicates',
              subtitle: 'Scan for matching logins, websites, and usernames',
              icon: Icons.copy_all_rounded,
              onTap: () {
                Navigator.of(context).push(KeyNestDuplicatesScreen.route());
              },
            ),
            KeyNestSettingsTile(
              title: 'Manage Categories',
              subtitle: 'Custom labels, colors, and organization',
              icon: Icons.category_rounded,
              onTap: () {
                Navigator.of(
                  context,
                ).push(KeyNestManageCategoriesScreen.route());
              },
            ),
            KeyNestSettingsTile(
              title: 'Recently Deleted',
              subtitle: 'Recycle bin • Restore or purge items',
              icon: Icons.delete_outline_rounded,
              onTap: () {
                Navigator.of(
                  context,
                ).push(KeyNestRecentlyDeletedScreen.route());
              },
            ),
          ],
        ),

        // Tools
        KeyNestSettingsGroup(
          header: 'Tools',
          headerIcon: Icons.build_circle_outlined,
          children: [
            KeyNestSettingsTile(
              title: loc.generatePassword,
              subtitle: 'Generate strong passwords and passphrases',
              icon: Icons.shuffle_rounded,
              onTap: () {
                Navigator.of(context).push(
                  PasswordGeneratorScreen.route(
                    finishButton: FinishButtonStyle.save,
                  ),
                );
              },
            ),
            if (KeyboardHandler.supportsSystemWideShortcuts)
              KeyNestSettingsTile(
                title: loc.preferenceEnableSystemWideShortcuts,
                subtitle: loc.preferenceEnableSystemWideShortcutsHelp,
                icon: Icons.keyboard_rounded,
                trailing: Switch(
                  value: appData.systemWideShortcuts,
                  onChanged: (value) {
                    _analytics.events.trackPreferences(
                      setting: 'systemWideShortcuts',
                      to: '$value',
                    );
                    _appDataBloc.update(
                      (builder, data) => builder.systemWideShortcuts = value,
                    );
                  },
                ),
              ),
          ],
        ),

        // Appearance Settings
        KeyNestSettingsGroup(
          header: 'Appearance',
          headerIcon: Icons.palette_outlined,
          children: [
            KeyNestSettingsTile(
              title: loc.preferenceTheme,
              subtitle: appData.theme == null
                  ? loc.preferenceSystemDefault
                  : appData.theme == AppDataTheme.light
                  ? loc.preferenceThemeLight
                  : loc.preferenceThemeDark,
              icon: Icons.palette_rounded,
              onTap: () async {
                final newTheme = await _appDataBloc.updateNextTheme();
                _analytics.events.trackPreferences(
                  setting: 'theme',
                  to: '$newTheme',
                );
              },
            ),
            KeyNestSettingsTile(
              title: 'Fetch website icons',
              subtitle:
                  'When enabled, requests website icons from external services (Google, DuckDuckGo) using domain names in the ${commonFields.url.displayName} field.',
              icon: Icons.image_search_rounded,
              trailing: Switch(
                value:
                    appData.fetchWebsiteIcons ??
                    env.featureFetchWebsiteIconEnabledByDefault,
                onChanged: (value) {
                  _analytics.events.trackPreferences(
                    setting: 'fetchWebsiteIcons',
                    to: '$value',
                  );
                  KeyNestDynamicIconService.instance.networkFetchEnabled =
                      value;
                  _appDataBloc.update(
                    (builder, data) => builder.fetchWebsiteIcons = value,
                  );
                },
              ),
            ),
            ValueSelectorTile(
              icon: const FaIcon(FontAwesomeIcons.leftRight),
              title: Text(loc.preferenceVisualDensity),
              onChanged: (value) {
                _appDataBloc.update(
                  (builder, data) => builder.themeVisualDensity = value,
                );
                _analytics.events.trackPreferences(
                  setting: 'themeVisualDensity',
                  to: '$value',
                );
              },
              value: appData.themeVisualDensity,
              minValue: -4,
              maxValue: 4,
              steps: 16,
            ),
            ValueSelectorTile(
              icon: const FaIcon(FontAwesomeIcons.textHeight),
              title: Text(loc.preferenceTextScaleFactor),
              onChanged: (value) {
                _appDataBloc.update(
                  (builder, data) => builder.themeFontSizeFactor = value,
                );
                _analytics.events.trackPreferences(
                  setting: 'themeFontSizeFactor',
                  to: '$value',
                );
              },
              value: appData.themeFontSizeFactor,
              minValue: 0.5,
              maxValue: 2,
              valueForNull: 1,
              steps: 15,
            ),
          ],
        ),

        // About KeyNest
        KeyNestSettingsGroup(
          header: 'About',
          headerIcon: Icons.info_outline_rounded,
          children: [
            KeyNestSettingsTile(
              title: 'KeyNest Password Manager',
              subtitle: 'Version 1.0.0 • Open Source',
              icon: Icons.shield_rounded,
              onTap: () {
                showAboutDialog(
                  context: context,
                  applicationName: 'KeyNest',
                  applicationVersion: '1.0.0',
                  applicationLegalese:
                      'A secure, offline-first KeePass compatible password manager.',
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  String _autoLockLabel(int seconds) {
    if (seconds == 0) {
      return 'Immediate on background';
    }
    if (seconds == 60) {
      return '1 minute';
    }
    if (seconds == 300) {
      return '5 minutes';
    }
    if (seconds == 900) {
      return '15 minutes';
    }
    if (seconds < 0) {
      return 'Never';
    }
    return '${seconds ~/ 60} minutes';
  }

  String _clipboardClearLabel(int seconds) {
    if (seconds < 0) {
      return 'Never';
    }
    return '$seconds seconds';
  }

  void _showAutoLockPicker(BuildContext context) {
    final current = SecuritySettingsStore.instance.autoLockSeconds;
    final options = <int, String>{
      0: 'Immediate on background',
      60: '1 minute',
      300: '5 minutes (Recommended)',
      900: '15 minutes',
      -1: 'Never (Not Recommended)',
    };

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFFF59E0B,
                              ).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.timer_outlined,
                              color: Color(0xFFF59E0B),
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Auto-Lock Vault',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? KeyNestPalette.textPrimaryDark
                                  : KeyNestPalette.textPrimaryLight,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Lock database when KeyNest is sent to background.',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ...options.entries.map((e) {
                    final isSelected = current == e.key;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: KeyNestCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: isSelected
                            ? Border.all(
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                                width: 1.5,
                              )
                            : null,
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          SecuritySettingsStore.instance
                              .save(autoLockSeconds: e.key)
                              .then((_) {
                                if (mounted) {
                                  setState(() {});
                                }
                              });
                        },
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.value,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? (isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary)
                                      : null,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Icon(
                                Icons.check_circle_rounded,
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                                size: 20,
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showClipboardClearPicker(BuildContext context) {
    final current = SecuritySettingsStore.instance.clipboardClearSeconds;
    final options = <int, String>{
      30: '30 seconds (Recommended)',
      60: '60 seconds',
      90: '90 seconds',
      -1: 'Never',
    };

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF10B981,
                              ).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.content_paste_off_rounded,
                              color: Color(0xFF10B981),
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Clipboard Auto-Clear',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? KeyNestPalette.textPrimaryDark
                                  : KeyNestPalette.textPrimaryLight,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Automatically wipe sensitive credentials from the clipboard after copying.',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ...options.entries.map((e) {
                    final isSelected = current == e.key;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: KeyNestCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: isSelected
                            ? Border.all(
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                                width: 1.5,
                              )
                            : null,
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          SecuritySettingsStore.instance
                              .save(clipboardClearSeconds: e.key)
                              .then((_) {
                                if (mounted) {
                                  setState(() {});
                                }
                              });
                        },
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.value,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? (isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary)
                                      : null,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Icon(
                                Icons.check_circle_rounded,
                                color: isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary,
                                size: 20,
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCloudProviderTile({
    required CloudStorageProvider? provider,
    required String name,
    required String subtitle,
    required dynamic icon,
  }) {
    if (provider == null) {
      return const SizedBox.shrink();
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAuthed = provider.isAuthenticated;
    return KeyNestSettingsTile(
      title: name,
      titleWidget: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Text(
            name,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 15.5,
              color: isDark
                  ? KeyNestPalette.textPrimaryDark
                  : KeyNestPalette.textPrimaryLight,
            ),
          ),
          if (isAuthed)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 7,
                vertical: 2.5,
              ),
              decoration: BoxDecoration(
                color: (isDark
                        ? KeyNestPalette.successDark
                        : KeyNestPalette.success)
                    .withValues(alpha: isDark ? 0.20 : 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    size: 12,
                    color: isDark
                        ? KeyNestPalette.successDark
                        : KeyNestPalette.success,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Connected',
                    style: TextStyle(
                      color: isDark
                          ? KeyNestPalette.successDark
                          : KeyNestPalette.success,
                      fontWeight: FontWeight.bold,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      subtitle: isAuthed ? 'Connected and ready to sync' : subtitle,
      icon: icon,
      trailing: isAuthed
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                  tooltip: 'Configure $name',
                  icon: const Icon(Icons.settings_outlined, size: 20),
                  onPressed: () async {
                    await KeyNestCloudConnectModal.show(context, provider);
                    if (mounted) {
                      context.read<CloudStorageBloc>().notifyAuthChanged();
                      setState(() {});
                    }
                  },
                ),
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                  tooltip: 'Disconnect $name',
                  icon: const Icon(Icons.link_off_rounded, size: 20),
                  onPressed: () async {
                    await provider.logout();
                    if (mounted) {
                      context.read<CloudStorageBloc>().notifyAuthChanged();
                      setState(() {});
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(
                          SnackBar(
                            content: Text(
                              'Disconnected from $name. Your local vault was not deleted.',
                            ),
                            duration: const Duration(milliseconds: 1800),
                          ),
                        );
                    }
                  },
                ),
              ],
            )
          : ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                foregroundColor: isDark
                    ? const Color(0xFF00315D)
                    : Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () async {
                final connected = await KeyNestCloudConnectModal.show(
                  context,
                  provider,
                );
                if (connected == true && mounted) {
                  context.read<CloudStorageBloc>().notifyAuthChanged();
                  setState(() {});
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(
                      SnackBar(
                        content: Text('Connected to $name successfully!'),
                        duration: const Duration(milliseconds: 1800),
                      ),
                    );
                }
              },
              child: const Text(
                'Connect',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
      onTap: () async {
        if (isAuthed) {
          if (provider is GoogleDriveProvider || provider is DropboxProvider) {
            Navigator.of(
              context,
            ).push(KeyNestCloudManagementScreen.route(provider));
          } else {
            Navigator.of(context).push(CloudStorageSelector.route(provider));
          }
        } else {
          final connected = await KeyNestCloudConnectModal.show(
            context,
            provider,
          );
          if (connected == true && mounted) {
            context.read<CloudStorageBloc>().notifyAuthChanged();
            setState(() {});
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                SnackBar(
                  content: Text('Connected to $name successfully!'),
                  duration: const Duration(milliseconds: 1800),
                ),
              );
          }
        }
      },
    );
  }

  Widget _buildGoogleDriveSyncTile(GoogleDriveProvider google) {
    return KeyNestSettingsTile(
      title: 'Sync Vault with Google Drive',
      subtitle: _googleDriveSyncStatus ?? 'Tap to synchronize open vault now',
      icon: _isSyncingGoogleDrive
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1EA362)),
              ),
            )
          : Icons.cloud_sync_rounded,
      iconColor: const Color(0xFF1EA362),
      trailing: _isSyncingGoogleDrive
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1EA362)),
              ),
            )
          : ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1EA362),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _syncGoogleDrive(google),
              child: const Text(
                'Sync Now',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
      onTap: _isSyncingGoogleDrive ? null : () => _syncGoogleDrive(google),
    );
  }

  Widget _buildGoogleDriveRestoreTile(GoogleDriveProvider google) {
    return KeyNestSettingsTile(
      title: 'Restore from Google Drive Backup',
      subtitle: 'View and restore from the last 5 automatic pre-sync backups',
      icon: Icons.history_rounded,
      iconColor: const Color(0xFF1EA362),
      onTap: () => _showGoogleDriveBackupsSheet(context, google),
    );
  }

  Future<void> _syncGoogleDrive(GoogleDriveProvider google) async {
    if (_isSyncingGoogleDrive) {
      return;
    }
    final kdbxBloc = _kdbxBloc ?? context.read<KdbxBloc>();
    final openedList = kdbxBloc.openedFiles.values.toList();
    if (openedList.isEmpty) {
      if (mounted) {
        await DialogUtils.showSimpleAlertDialog(
          context,
          'No Open Vaults',
          'Please unlock or open your vault first before synchronizing with Google Drive.',
          routeAppend: 'gdriveNoVaults',
        );
      }
      return;
    }

    setState(() {
      _isSyncingGoogleDrive = true;
      _googleDriveSyncStatus = 'Synchronizing with Google Drive...';
    });

    try {
      for (final opened in openedList) {
        final result = await KeyNestCloudSyncManager.instance.syncVault(
          provider: google,
          source: opened.fileSource,
          openedFile: opened,
          kdbxBloc: kdbxBloc,
        );

        setState(() {
          _googleDriveSyncStatus = result.message;
        });

        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(result.message ?? 'Sync completed.'),
                duration: const Duration(seconds: 3),
              ),
            );
        }
      }
    } catch (e) {
      setState(() {
        _googleDriveSyncStatus = 'Sync error: $e';
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('Sync failed: $e'),
              backgroundColor: Colors.redAccent,
            ),
          );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncingGoogleDrive = false;
        });
      }
    }
  }

  Future<void> _showGoogleDriveBackupsSheet(
    BuildContext context,
    GoogleDriveProvider google,
  ) async {
    final kdbxBloc = _kdbxBloc ?? context.read<KdbxBloc>();
    final openedList = kdbxBloc.openedFiles.values.toList();
    final backups = <GoogleDriveBackupInfo>[];
    for (final opened in openedList) {
      final vBackups = await google.stateStore.listBackups(opened.fileSource.uuid);
      backups.addAll(vBackups);
    }
    if (backups.isEmpty && openedList.isNotEmpty) {
      backups.addAll(await google.stateStore.listBackups('default'));
    }
    backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (!context.mounted) {
      return;
    }

    if (backups.isEmpty) {
      await DialogUtils.showSimpleAlertDialog(
        context,
        'No Backups Available',
        'No local backups have been created yet. Backups are created automatically before every Google Drive sync (keeping the last 5).',
        routeAppend: 'gdriveBackupsEmpty',
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (modalCtx) {
        final isDark = Theme.of(modalCtx).brightness == Brightness.dark;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.history_rounded, color: Color(0xFF1EA362)),
                    const SizedBox(width: 8),
                    const Text(
                      'Google Drive Backups (Last 5)',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(modalCtx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'These snapshots are saved automatically before each sync operation.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: backups.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final b = backups[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const CircleAvatar(
                          backgroundColor: Color(0x1A1EA362),
                          child: Icon(
                            Icons.restore_page_rounded,
                            color: Color(0xFF1EA362),
                            size: 20,
                          ),
                        ),
                        title: Text(
                          b.displayName,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          b.filePath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary,
                            foregroundColor: isDark
                                ? const Color(0xFF00315D)
                                : Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () async {
                            Navigator.of(modalCtx).pop();
                            final confirm = await DialogUtils.showConfirmDialog(
                              context: context,
                              params: ConfirmDialogParams(
                                title: 'Restore Backup',
                                content:
                                    'Are you sure you want to restore this backup? A snapshot of the current state will be taken first.',
                                positiveButtonText: 'Restore',
                              ),
                            );
                            if (confirm == true && openedList.isNotEmpty) {
                              final backupFile = File(b.filePath);
                              final bytes = await backupFile.readAsBytes();
                              final target = openedList.firstWhereOrNull(
                                    (of) => of.fileSource.uuid == b.vaultId,
                                  ) ??
                                  openedList.first;
                              await target.fileSource.contentWrite(
                                bytes,
                                metadata: null,
                              );
                              await for (final _ in kdbxBloc.reload(target)) {}
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Vault restored from backup successfully!',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text(
                            'Restore',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDropboxSyncTile(DropboxProvider dropbox) {
    return KeyNestSettingsTile(
      title: 'Sync Vault with Dropbox',
      subtitle: _dropboxSyncStatus ?? 'Tap to synchronize open vault now',
      icon: _isSyncingDropbox
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0061FF)),
              ),
            )
          : Icons.cloud_sync_rounded,
      iconColor: const Color(0xFF0061FF),
      trailing: _isSyncingDropbox
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0061FF)),
              ),
            )
          : ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0061FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _syncDropbox(dropbox),
              child: const Text(
                'Sync Now',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
      onTap: _isSyncingDropbox ? null : () => _syncDropbox(dropbox),
    );
  }

  Widget _buildDropboxRestoreTile(DropboxProvider dropbox) {
    return KeyNestSettingsTile(
      title: 'Restore from Dropbox Backup',
      subtitle: 'View and restore from the last 5 automatic pre-sync backups',
      icon: Icons.history_rounded,
      iconColor: const Color(0xFF0061FF),
      onTap: () => _showDropboxBackupsSheet(context, dropbox),
    );
  }

  Future<void> _syncDropbox(DropboxProvider dropbox) async {
    if (_isSyncingDropbox) {
      return;
    }
    final kdbxBloc = _kdbxBloc ?? context.read<KdbxBloc>();
    final openedList = kdbxBloc.openedFiles.values.toList();
    if (openedList.isEmpty) {
      if (mounted) {
        await DialogUtils.showSimpleAlertDialog(
          context,
          'No Open Vaults',
          'Please unlock or open your vault first before synchronizing with Dropbox.',
          routeAppend: 'dropboxNoVaults',
        );
      }
      return;
    }

    setState(() {
      _isSyncingDropbox = true;
      _dropboxSyncStatus = 'Synchronizing with Dropbox...';
    });

    try {
      for (final opened in openedList) {
        final result = await KeyNestCloudSyncManager.instance.syncVault(
          provider: dropbox,
          source: opened.fileSource,
          openedFile: opened,
          kdbxBloc: kdbxBloc,
        );

        setState(() {
          _dropboxSyncStatus = result.message;
        });

        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(result.message ?? 'Sync completed.'),
                duration: const Duration(seconds: 3),
              ),
            );
        }
      }
    } catch (e) {
      setState(() {
        _dropboxSyncStatus = 'Sync error: $e';
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('Sync failed: $e'),
              backgroundColor: Colors.redAccent,
            ),
          );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncingDropbox = false;
        });
      }
    }
  }

  Future<void> _showDropboxBackupsSheet(
    BuildContext context,
    DropboxProvider dropbox,
  ) async {
    final kdbxBloc = _kdbxBloc ?? context.read<KdbxBloc>();
    final openedList = kdbxBloc.openedFiles.values.toList();
    final backups = <DropboxBackupInfo>[];
    for (final opened in openedList) {
      final vBackups = await dropbox.stateStore.listBackups(opened.fileSource.uuid);
      backups.addAll(vBackups);
    }
    if (backups.isEmpty && openedList.isNotEmpty) {
      backups.addAll(await dropbox.stateStore.listBackups('default'));
    }
    backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (!context.mounted) {
      return;
    }

    if (backups.isEmpty) {
      await DialogUtils.showSimpleAlertDialog(
        context,
        'No Backups Available',
        'No local backups have been created yet. Backups are created automatically before every Dropbox sync (keeping the last 5).',
        routeAppend: 'dropboxBackupsEmpty',
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (modalCtx) {
        final isDark = Theme.of(modalCtx).brightness == Brightness.dark;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.history_rounded, color: Color(0xFF0061FF)),
                    const SizedBox(width: 8),
                    const Text(
                      'Local Backups (Last 5)',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(modalCtx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'These snapshots are saved automatically before each sync operation.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: backups.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final b = backups[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const CircleAvatar(
                          backgroundColor: Color(0x1A0061FF),
                          child: Icon(
                            Icons.restore_page_rounded,
                            color: Color(0xFF0061FF),
                            size: 20,
                          ),
                        ),
                        title: Text(
                          b.displayName,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          b.filePath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary,
                            foregroundColor: isDark
                                ? const Color(0xFF00315D)
                                : Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () async {
                            Navigator.of(modalCtx).pop();
                            final confirm = await DialogUtils.showConfirmDialog(
                              context: context,
                              params: ConfirmDialogParams(
                                title: 'Restore Backup',
                                content:
                                    'Are you sure you want to restore this backup? A snapshot of the current state will be taken first.',
                                positiveButtonText: 'Restore',
                              ),
                            );
                            if (confirm == true && openedList.isNotEmpty) {
                              final backupFile = File(b.filePath);
                              final bytes = await backupFile.readAsBytes();
                              final target = openedList.firstWhereOrNull(
                                    (of) => of.fileSource.uuid == b.vaultId,
                                  ) ??
                                  openedList.first;
                              await target.fileSource.contentWrite(
                                bytes,
                                metadata: null,
                              );
                              await for (final _ in kdbxBloc.reload(target)) {}
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Vault restored from backup successfully!',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text(
                            'Restore',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _syncOpenVaults() async {
    if (_isSyncingVaults) {
      return;
    }
    final kdbxBloc = _kdbxBloc ?? context.read<KdbxBloc>();
    final openedList = kdbxBloc.openedFiles.values.toList();

    if (openedList.isEmpty) {
      if (context.mounted) {
        await DialogUtils.showSimpleAlertDialog(
          context,
          'No Open Vaults',
          'There are no vaults currently unlocked or open to synchronize. Please open or unlock your database first, then use this option to sync.',
          routeAppend: 'syncNoVaults',
        );
      }
      return;
    }

    setState(() {
      _isSyncingVaults = true;
    });

    final results = <String>[];
    var successCount = 0;
    var errorCount = 0;

    try {
      for (final initialFile in openedList) {
        var openedFile = kdbxBloc.fileForKdbxFile(initialFile.kdbxFile);
        final vaultName = KeyNestVaultScope.cleanVaultName(
          kdbxBloc,
          openedFile.kdbxFile,
        );
        try {
          // 1. If file has uncommitted local modifications, commit them.
          if (openedFile.kdbxFile.isDirty) {
            await kdbxBloc.saveFile(openedFile.kdbxFile);
            openedFile = kdbxBloc.fileForKdbxFile(openedFile.kdbxFile);
          }

          // 2. Perform reload/pull from remote storage.
          var reloadStatus = ReloadStatus.didNotChange;
          await for (final status in kdbxBloc.reload(openedFile)) {
            reloadStatus = status;
          }

          // 3. If remote had changes that were merged, commit merged state.
          if (reloadStatus == ReloadStatus.merged) {
            await kdbxBloc.saveFile(openedFile.kdbxFile);
            results.add('$vaultName: Merged updates from storage');
          } else {
            results.add('$vaultName: Up to date');
          }
          successCount++;
        } catch (e, stackTrace) {
          _logger.warning('Error syncing vault $vaultName', e, stackTrace);
          results.add('$vaultName: Error ($e)');
          errorCount++;
        }
      }

      kdbxBloc.clearEntryByUuidLookup();
    } finally {
      if (mounted) {
        setState(() {
          _isSyncingVaults = false;
        });

        if (context.mounted) {
          if (errorCount == 0) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final accent = isDark
                ? KeyNestTokens.primaryAccent
                : KeyNestPalette.primary;
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        color: accent,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'All open vaults ($successCount) synchronized successfully!\n${results.join('\n')}',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                  duration: const Duration(milliseconds: 2500),
                ),
              );
          } else {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                SnackBar(
                  content: Text(
                    'Sync completed with issues:\n${results.join('\n')}',
                  ),
                  backgroundColor: KeyNestPalette.warning,
                  duration: const Duration(milliseconds: 3000),
                ),
              );
          }
        }
      }
    }
  }

  Future<void> _showAutofillDiagnostics(BuildContext context) async {
    final diag = await AutofillService().getDiagnostics();
    final browsers = await AutofillService().getBrowserAutofillStatus();
    final openFiles = _kdbxBloc?.openedFilesKdbx ?? [];
    if (!context.mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final isKeyNestDefault = diag['isKeyNestDefault'] == true;
        final isEnabled = diag['hasEnabledAutofillServices'] == true;
        final sdkInt = diag['sdkInt'] ?? 'Android';

        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? KeyNestPalette.cardDark : KeyNestPalette.cardLight,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                              .withValues(alpha: isDark ? 0.20 : 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.troubleshoot_rounded,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Autofill Diagnostics',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildDiagRow(
                'Android API Level',
                'API $sdkInt',
                Icons.android_rounded,
                isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
              ),
              _buildDiagRow(
                'Autofill Framework Status',
                isEnabled ? 'Active & Enabled' : 'Not Enabled in Settings',
                isEnabled
                    ? Icons.check_circle_rounded
                    : Icons.warning_amber_rounded,
                isEnabled
                    ? (isDark
                          ? KeyNestPalette.successDark
                          : KeyNestPalette.success)
                    : KeyNestPalette.warning,
              ),
              _buildDiagRow(
                'Default Provider',
                isKeyNestDefault
                    ? 'KeyNest is Active Provider'
                    : 'Another app is default',
                isKeyNestDefault
                    ? Icons.verified_user_rounded
                    : Icons.info_outline_rounded,
                isKeyNestDefault
                    ? (isDark
                          ? KeyNestPalette.successDark
                          : KeyNestPalette.success)
                    : KeyNestPalette.warning,
              ),
              _buildDiagRow(
                'Open Vaults',
                '${openFiles.length} vault(s) unlocked for autofill',
                Icons.lock_open_rounded,
                openFiles.isNotEmpty
                    ? (isDark
                          ? KeyNestPalette.successDark
                          : KeyNestPalette.success)
                    : KeyNestPalette.warning,
              ),
              if (browsers.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Browser Integration',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                ...browsers.map(
                  (b) => _buildDiagRow(
                    b.label,
                    b.thirdPartyModeEnabled
                        ? '3rd-party autofill enabled'
                        : 'Requires toggle in browser settings',
                    b.thirdPartyModeEnabled
                        ? Icons.check_rounded
                        : Icons.browser_not_supported_rounded,
                    b.thirdPartyModeEnabled
                        ? (isDark
                              ? KeyNestPalette.successDark
                              : KeyNestPalette.success)
                        : KeyNestPalette.warning,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await AutofillService().requestSetAutofillService();
                    await _doInit();
                  },
                  icon: const Icon(Icons.settings_rounded, size: 18),
                  label: const Text('Open System Autofill Settings'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                    foregroundColor: isDark
                        ? const Color(0xFF00315D)
                        : Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDiagRow(String label, String value, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
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
}

class ValueSelectorTile extends StatelessWidget {
  const ValueSelectorTile({
    super.key,
    required this.value,
    required this.minValue,
    required this.maxValue,
    required this.steps,
    required this.onChanged,
    this.icon,
    this.title,
    this.valueForNull = 0,
  });

  final Widget? icon;
  final Widget? title;
  final double? value;
  final double valueForNull;
  final double minValue;
  final double maxValue;
  final int steps;
  final void Function(double? value) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = theme.visualDensity;
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              icon!,
              SizedBox(width: 32 + density.horizontal * 2),
              Expanded(
                child: DefaultTextStyle(
                  style: theme.textTheme.titleMedium!,
                  child: title!,
                ),
              ),
              Text(
                value == null
                    ? loc.preferenceDefault
                    : value!.toStringAsFixed(2),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              IconButton(
                icon: FaIcon(
                  FontAwesomeIcons.squareMinus,
                  semanticLabel: loc.decreaseValue,
                ),
                onPressed: () => _updateValue(-1),
              ),
              IconButton(
                icon: FaIcon(
                  FontAwesomeIcons.squarePlus,
                  semanticLabel: loc.increaseValue,
                ),
                onPressed: () => _updateValue(1),
              ),
              IconButton(
                icon: FaIcon(
                  FontAwesomeIcons.xmark,
                  semanticLabel: loc.resetValue,
                ),
                onPressed: () => onChanged(null),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _updateValue(int stepDirection) {
    final v = value ?? valueForNull;
    final valueStep = (maxValue - minValue) / steps;
    final newValue = (v + valueStep * stepDirection)
        .clamp(minValue, maxValue)
        .toDouble();
    if (value != newValue) {
      onChanged(newValue);
    }
  }
}

class SliderSelector extends StatefulWidget {
  const SliderSelector({
    super.key,
    required this.initialValue,
    required this.minValue,
    required this.maxValue,
    required this.steps,
    required this.onChanged,
  });

  final double initialValue;
  final double minValue;
  final double maxValue;
  final int steps;
  final void Function(double value) onChanged;

  @override
  _SliderSelectorState createState() => _SliderSelectorState();
}

class _SliderSelectorState extends State<SliderSelector> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: _value,
      min: widget.minValue,
      max: widget.maxValue,
      divisions: widget.steps,
      onChanged: (value) {
        setState(() {
          _value = value;
          widget.onChanged(value);
        });
      },
    );
  }
}

class PreferencesOverflowMenuAction extends HookWidget {
  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final kdbxBloc = context.read<KdbxBloc>();
    final supportsBiometricKeystore = useFuture(
      kdbxBloc.quickUnlockStorage.supportsBiometricKeyStore(),
      initialData: kdbxBloc.quickUnlockStorage.supportsBiometricKeystoreAlready,
    );
    return KeyNestPopupMenuButton<VoidCallback>(
      itemBuilder: (context) {
        return [
          if (supportsBiometricKeystore.data == true) ...[
            PopupMenuItem(
              value: () async {
                await kdbxBloc.closeAllFiles(clearQuickUnlock: true);
                // ignore: use_build_context_synchronously
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(loc.clearQuickUnlockSuccess)),
                );
                // ignore: use_build_context_synchronously
                await SelectFileScreen.navigate(context);
              },
              child: ListTile(
                leading: const FaIcon(FontAwesomeIcons.bug),
                title: Text(loc.clearQuickUnlock),
                subtitle: Text(loc.clearQuickUnlockSubtitle),
              ),
            ),
          ],
          if (kdbxBloc.openedFilesWithSources.isNotEmpty) ...[
            PopupMenuItem(
              value: () async {
                await kdbxBloc.closeAllFiles(clearQuickUnlock: false);
                if (!context.mounted) {
                  return;
                }
                await Navigator.of(
                  context,
                  rootNavigator: true,
                ).pushAndRemoveUntil(LockedScreen.route(), (_) => false);
              },
              child: ListTile(
                leading: const FaIcon(FontAwesomeIcons.rightFromBracket),
                title: Text(loc.lockAllFiles),
              ),
            ),
          ],
        ];
      },
      onSelected: (value) => value(),
    );
  }
}
