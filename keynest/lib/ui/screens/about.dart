import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/deps.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/logging_utils.dart';
import 'package:provider/provider.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

@NonNls
const _contributorsUrl = 'https://raw.githubusercontent.com';

@NonNls
const _contributorsImageMapping = {
  'GH': FontAwesomeIcons.github,
  'TWTR': FontAwesomeIcons.twitter,
  'WebSite': Icons.open_in_browser,
};

class KeyNestAboutDialog extends StatelessWidget {
  const KeyNestAboutDialog({super.key, required this.env});

  final Env env;

  @override
  Widget build(BuildContext context) {
    final loggingUtil = LoggingUtils();
    final logFiles = loggingUtil.rotatingFileLoggerFiles;
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return FutureBuilder<AppInfo>(
      future: env.getAppInfo(),
      builder: (context, snapshot) {
        final appInfo = snapshot.data;
        return AboutDialog(
          applicationIcon: GestureDetector(
            onLongPress: () async {
              final deps = context.read<Deps>();
              final appData = await deps.appDataBloc.store.load();
              if (!context.mounted) {
                return;
              }
              final newData = await SimplePromptDialog(
                labelText: 'debug usertype', // NON-NLS
                initialValue: appData.manualUserType ?? '', // NON-NLS
              ).show(context);
              if (newData != null) {
                await deps.appDataBloc.update(
                  (b, _) => b..manualUserType = newData,
                );
                deps.analytics.events.trackUserType(userType: newData);
              }
            },
            child: ImageIcon(
              const AssetImage('assets/images/logo_icon.png'),
              color: Theme.of(context).primaryColor,
            ),
          ),
          applicationName: loc.aboutAppName,
          applicationVersion: appInfo?.versionLabel,
          applicationLegalese: '© KeyNest', // NON-NLS
          children: <Widget>[
            const SizedBox(height: 32),
            UrlLink(
              caption: loc.aboutLinkFeedback,
              url: 'mailto:contact@keynest.app',
            ),
            UrlLink(
              caption: loc.aboutLinkVisitWebsite,
              url: 'https://keynest.app/',
            ),
            UrlLink(
              caption: loc.aboutLinkGitHub,
              url: 'https://github.com/keynest/keynest/',
            ),
            const SizedBox(height: 32),
            FutureBuilder(
              future: http.read(Uri.parse(_contributorsUrl)),
              builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
                if (snapshot.hasData) {
                  return MarkdownBody(
                    data: snapshot.requireData,
                    imageBuilder: (uri, title, alt) {
                      final icon = _contributorsImageMapping[alt];
                      if (icon is FaIconData) {
                        return FaIcon(
                          icon,
                          size: 12,
                          color: theme.textTheme.bodyLarge!.color,
                        );
                      } else if (icon is IconData) {
                        return Icon(
                          icon,
                          size: 12,
                          color: theme.textTheme.bodyLarge!.color,
                        );
                      }
                      if (alt != null) {
                        return Text(alt);
                      }
                      return const SizedBox.shrink(); // Remove images
                    },
                    listItemCrossAxisAlignment:
                        MarkdownListItemCrossAxisAlignment.start,
                    onTapLink: (text, url, title) {
                      if (url != null) {
                        DialogUtils.openUrl(url);
                      }
                    },
                  );
                } else if (snapshot.hasError) {
                  return UrlLink(
                    caption: loc.aboutLinkContributors,
                    url: _contributorsUrl,
                  );
                }

                return const Center(
                  child: CircularProgressIndicator(),
                );
              },
            ),
            const SizedBox(height: 32),
            TextField(
              readOnly: true,
              decoration: const InputDecoration.collapsed(
                hintText: CharConstants.empty,
              ),
              controller: TextEditingController(
                text: loc.aboutLogFile(
                  logFiles.isEmpty
                      ? 'No Log File?!' // NON-NLS
                      : logFiles.first.absolute.path,
                ),
              ),
              style: Theme.of(context).textTheme.bodySmall!,
            ),
          ],
        );
      },
    );
  }

  static void openDialog(BuildContext context) {
    final env = Provider.of<Env>(context, listen: false);
    showDialog<void>(
      context: context,
      builder: (context) => KeyNestAboutDialog(env: env),
      routeSettings: const RouteSettings(name: '/about'),
    );
  }

  static PopupMenuItem<VoidCallback> createAboutMenuItem(BuildContext context) {
    final analytics = Provider.of<Analytics>(context, listen: false);
    final loc = AppLocalizations.of(context);
    return PopupMenuItem<VoidCallback>(
      value: () {
        analytics.events.trackActionPressed(action: 'about');
        KeyNestAboutDialog.openDialog(context);
      },
      child: ListTile(
        leading: const ImageIcon(AssetImage('assets/images/logo_icon.png')),
        title: Text(loc.menuItemAbout),
      ),
    );
  }
}

class UrlLink extends StatelessWidget {
  const UrlLink({super.key, required this.caption, @NonNls required this.url});

  final String caption;
  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: Divider.createBorderSide(context)),
      ),
      child: InkWell(
        onTap: () {
          DialogUtils.openUrl(url);
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                caption,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                url,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium!
                    .apply(color: theme.primaryColor, fontSizeFactor: 0.95)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
