import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:keynest/bloc/deps.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/ui/screens/about.dart';
import 'package:keynest/ui/screens/preferences.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:provider/provider.dart';

class PlatformMenuBarWrapper extends StatelessWidget {
  const PlatformMenuBarWrapper({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    final deps = context.read<Deps>();
    final loc = AppLocalizations.of(context);
    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: loc.aboutAppName,
          menus: [
            PlatformMenuItemGroup(
              members: <PlatformMenuItem>[
                PlatformMenuItem(
                  label: loc.menuItemAbout,
                  onSelected: () {
                    KeyNestAboutDialog.openDialog(
                      navigatorKey.currentContext!,
                    );
                  },
                ),
              ],
            ),
            PlatformMenuItemGroup(
              members: <PlatformMenuItem>[
                PlatformMenuItem(
                  label: loc.menuItemPreferences,
                  onSelected: () {
                    navigatorKey.currentState?.push(PreferencesScreen.route());
                  },
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.comma,
                    meta: true,
                  ),
                ),
              ],
            ),
            if (PlatformProvidedMenuItem.hasMenu(
              PlatformProvidedMenuItemType.quit,
            )) ...[
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.quit,
              ),
            ],
          ],
        ),
        PlatformMenu(
          label: loc.menuItemHelp,
          menus: [
            PlatformMenuItemGroup(
              members: <PlatformMenuItem>[
                PlatformMenuItem(
                  label: loc.menuItemForum,
                  onSelected: () {
                    DialogUtils.openUrl(deps.env.forumUrl);
                  },
                ),
              ],
            ),
          ],
        ),
      ],
      child: child,
    );
  }
}
