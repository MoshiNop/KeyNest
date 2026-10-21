import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/deps.dart';
import 'package:keynest/bloc/kdbx/file_source_ui.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_support_service.dart';
import 'package:keynest/ui/screens/keynest_duplicates_screen.dart';
import 'package:keynest/ui/screens/keynest_import_export.dart';
import 'package:keynest/ui/screens/keynest_vault_health_screen.dart';
import 'package:keynest/ui/screens/manage_file.dart';
import 'package:keynest/ui/screens/password_generator.dart';
import 'package:keynest/ui/screens/preferences.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/ui/widgets/keynest_popup_menu.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/logging_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:keynest/utils/winsparkle_init_noop.dart'
    if (dart.library.io) 'package:keynest/utils/winsparkle_init.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('app_bar_menu');

class AppBarMenu {
  static Future<void> _showThemeSelectionDialog(BuildContext context) async {
    final deps = context.read<Deps>();
    final appData = await deps.appDataBloc.store.load();
    if (!context.mounted) {
      return;
    }
    final currentTheme = appData.theme;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text('Theme Selection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: const Icon(Icons.brightness_auto_rounded),
                title: const Text('System Default'),
                trailing: currentTheme == null
                    ? const Icon(Icons.check_circle_rounded, color: Colors.blue)
                    : null,
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await deps.appDataBloc.update((b, _) => b.theme = null);
                },
              ),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: const Icon(Icons.light_mode_rounded),
                title: const Text('Light Theme'),
                trailing: currentTheme == AppDataTheme.light
                    ? const Icon(Icons.check_circle_rounded, color: Colors.blue)
                    : null,
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await deps.appDataBloc.update(
                    (b, _) => b.theme = AppDataTheme.light,
                  );
                },
              ),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: const Icon(Icons.dark_mode_rounded),
                title: const Text('Dark Theme'),
                trailing: currentTheme == AppDataTheme.dark
                    ? const Icon(Icons.check_circle_rounded, color: Colors.blue)
                    : null,
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await deps.appDataBloc.update(
                    (b, _) => b.theme = AppDataTheme.dark,
                  );
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  static Iterable<PopupMenuEntry<VoidCallback>> createDefaultPopupMenuItems(
    BuildContext context,
    OpenedKdbxFiles openedKdbxFiles, {
    List<PopupMenuItem<VoidCallback>> Function(BuildContext context)?
    secondaryBuilder,
    bool isOnOpenFileScreen = false,
  }) {
    final deps = context.read<Deps>();
    final openedFiles = openedKdbxFiles.values;
    final analytics = Provider.of<Analytics>(context, listen: false);
    final loc = AppLocalizations.of(context);

    if (isOnOpenFileScreen) {
      return [
        PopupMenuItem(
          value: () async {
            analytics.events.trackActionPressed(action: 'themeSelection');
            await _showThemeSelectionDialog(context);
          },
          child: const ListTile(
            leading: Icon(Icons.palette_outlined),
            title: Text('Theme Selection'),
          ),
        ),
        PopupMenuItem(
          value: () {
            KeyNestSupportService.sendLogs(context);
          },
          child: const ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('Send Logs'),
          ),
        ),
        PopupMenuItem(
          value: () {
            KeyNestSupportService.openUserGuide(context);
          },
          child: const ListTile(
            leading: Icon(Icons.help_outline_rounded),
            title: Text('Help'),
          ),
        ),
        PopupMenuItem(
          value: () {
            KeyNestSupportService.openAbout(context);
          },
          child: const ListTile(
            leading: ImageIcon(AssetImage('assets/images/logo_icon.png')),
            title: Text('About'),
          ),
        ),
        PopupMenuItem(
          value: () {
            KeyNestSupportService.contactSupport(context);
          },
          child: const ListTile(
            leading: Icon(Icons.mail_outline_rounded),
            title: Text('Contact'),
          ),
        ),
      ];
    }
    return [
      PopupMenuItem(
        value: () {
          analytics.events.trackActionPressed(action: 'generatePassword');
          Navigator.of(context).push(
            PasswordGeneratorScreen.route(finishButton: FinishButtonStyle.save),
          );
        },
        child: ListTile(
          key: const ValueKey('openPasswordGenerator'),
          leading: const FaIcon(FontAwesomeIcons.shuffle),
          title: Text(loc.menuItemGeneratePassword),
        ),
      ),
      PopupMenuItem(
        value: () {
          analytics.events.trackActionPressed(action: 'preferences');
          Navigator.of(context).push(PreferencesScreen.route());
        },
        child: ListTile(
          leading: const FaIcon(FontAwesomeIcons.gears),
          title: Text(loc.menuItemPreferences),
        ),
      ),
      PopupMenuItem(
        value: () {
          analytics.events.trackActionPressed(action: 'importExport');
          Navigator.of(context).push(KeyNestImportExportScreen.route());
        },
        child: const ListTile(
          leading: Icon(Icons.swap_vert_rounded),
          title: Text('Import & Export'),
        ),
      ),
      PopupMenuItem(
        value: () {
          analytics.events.trackActionPressed(action: 'vaultHealth');
          Navigator.of(context).push(KeyNestVaultHealthScreen.route());
        },
        child: const ListTile(
          leading: Icon(Icons.health_and_safety_outlined),
          title: Text('Vault Health'),
        ),
      ),
      PopupMenuItem(
        value: () {
          analytics.events.trackActionPressed(action: 'findDuplicates');
          Navigator.of(context).push(KeyNestDuplicatesScreen.route());
        },
        child: const ListTile(
          leading: Icon(Icons.copy_all_rounded),
          title: Text('Find Duplicates'),
        ),
      ),
      if (openedFiles.isNotEmpty)
        PopupMenuItem(
          value: () async {
            final kdbxBloc = context.read<KdbxBloc>();
            final syncedNames = <String>[];
            for (final entry in kdbxBloc.openedFiles.entries) {
              await kdbxBloc.saveFile(entry.value.kdbxFile);
              syncedNames.add(entry.key.displayName);
            }
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(
                  SnackBar(
                    content: Text(
                      syncedNames.isEmpty
                          ? 'All open vaults synchronized'
                          : 'Synchronized: ${syncedNames.join(', ')}',
                    ),
                    duration: const Duration(milliseconds: 2500),
                  ),
                );
            }
          },
          child: const ListTile(
            leading: Icon(Icons.sync_rounded),
            title: Text('Sync Open Vaults'),
          ),
        ),
      ...?(openedFiles.isNotEmpty != true
          ? null
          : (<PopupMenuEntry<VoidCallback>>[
              const PopupMenuDivider(),
            ]).followedBy(
              openedFiles.map(
                (file) => PopupMenuItem(
                  value: () {
                    analytics.events.trackActionPressed(action: 'manageFile');
                    Navigator.of(
                      context,
                      rootNavigator: true,
                    ).push(ManageFileScreen.route(file.fileSource));
                  },
                  child: ListTile(
                    leading: file.fileSource.displayIcon.iconData.widget(
                      color: file.openedFile.color,
                    ),
                    title: Text(file.fileSource.displayName),
                    subtitle: Text(
                      file.fileSource.displayPath,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      maxLines: 1,
                    ),
                  ),
                ),
              ),
            )),
      if (!isOnOpenFileScreen) ...[
        PopupMenuItem(
          value: () {
            analytics.events.trackActionPressed(action: 'openFile');
            Navigator.of(
              context,
              rootNavigator: true,
            ).push(SelectFileScreen.route());
          },
          child: ListTile(
            key: const ValueKey('openAnotherFile'),
            leading: const FaIcon(FontAwesomeIcons.folderPlus),
            title: Text(loc.menuItemOpenAnotherFile),
          ),
        ),
      ],
      if (secondaryBuilder != null) ...secondaryBuilder(context),
      const PopupMenuDivider(),
      ...?!KeyNestPlatform.isWindowsWinAutoUpdate
          ? null
          : [
              PopupMenuItem(
                value: () {
                  winSparkleCheckUpdate();
                },
                child: ListTile(
                  leading: const Icon(Icons.update),
                  title: Text(loc.menuItemCheckForUpdates),
                ),
              ),
            ],
      PopupMenuItem(
        value: () {
          KeyNestSupportService.sendLogs(context);
        },
        child: ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(loc.menuItemSupport),
          subtitle: const Text('Share diagnostic logs'),
        ),
      ),
      PopupMenuItem(
        onTap: () async {
          analytics.events.trackActionPressed(action: 'forum');
          final url = deps.env.forumUrlNewTopic(
            body: nonNls(
              '\n\n\n'
              'OS: ${KeyNestPlatform.operatingSystem} '
              '${KeyNestPlatform.operatingSystemVersion}\n'
              'App: ${(await deps.env.getAppInfo()).longString}\n'
              '${await LoggingUtils.getDebugDeviceInfo()}',
            ),
            tags: [nonNls('fromapp')],
          );
          _logger.finer('opening url (${url.length}): $url');
          await DialogUtils.openUrl(url);
        },
        child: ListTile(
          leading: const Icon(Icons.support),
          title: Text(loc.menuItemForum),
          subtitle: Text(loc.menuItemForumSubtitle),
        ),
      ),
      PopupMenuItem(
        value: () {
          KeyNestSupportService.openUserGuide(context);
        },
        child: ListTile(
          leading: const Icon(Icons.help_outline_rounded),
          title: Text(loc.menuItemHelp),
          subtitle: Text(loc.menuItemHelpSubtitle),
        ),
      ),
      PopupMenuItem(
        value: () {
          KeyNestSupportService.openAbout(context);
        },
        child: ListTile(
          leading: const ImageIcon(AssetImage('assets/images/logo_icon.png')),
          title: Text(loc.menuItemAbout),
        ),
      ),
      PopupMenuItem(
        value: () {
          KeyNestSupportService.contactSupport(context);
        },
        child: const ListTile(
          leading: Icon(Icons.mail_outline_rounded),
          title: Text('Contact'),
          subtitle: Text('Email support team'),
        ),
      ),
    ];
  }

  static Widget createOverflowMenuButton(
    BuildContext context, {
    List<PopupMenuItem<VoidCallback>> Function(BuildContext context)? builder,
    List<PopupMenuItem<VoidCallback>> Function(BuildContext context)?
    secondaryBuilder,
    bool isOnOpenFileScreen = false,
  }) {
    final openedFiles = Provider.of<OpenedKdbxFiles>(context);
    return KeyNestPopupMenuButton<VoidCallback>(
      key: const ValueKey('appBarOverflowMenu'),
      onSelected: (val) => val(),
      itemBuilder: (context) => [
        ...?(builder == null ? null : builder(context)),
        ...AppBarMenu.createDefaultPopupMenuItems(
          context,
          openedFiles,
          secondaryBuilder: secondaryBuilder,
          isOnOpenFileScreen: isOnOpenFileScreen,
        ),
      ],
    );
  }
}
