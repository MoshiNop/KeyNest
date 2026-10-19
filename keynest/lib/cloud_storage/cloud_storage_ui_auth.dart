import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/cloud_storage_ui_adapt.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/ui/widgets/link_button.dart';
import 'package:keynest/ui/widgets/primary_button.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:logging/logging.dart';
import 'package:simple_form_field_validator/simple_form_field_validator.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('cloud_storage_ui_auth');

class CloudStorageAuthentication extends StatelessWidget {
  const CloudStorageAuthentication({
    super.key,
    required this.provider,
    required this.onSuccess,
  });

  final CloudStorageProvider provider;
  final void Function() onSuccess;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final provider = this.provider;
    final defaultLoginWidget = PrimaryButton(
      icon: const FaIcon(FontAwesomeIcons.rightToBracket),
      onPressed: () async {
        await _startLoginFlow(context);
      },
      child: Text(loc.cloudStorageLogInActionLabel(provider.displayName)),
    );
    final loginWidget = provider is CloudStorageCustomLoginButtonAdapter
        ? provider.getCustomLoginWidget(
            onSuccess: onSuccess,
            defaultWidget: defaultLoginWidget,
          )
        : defaultLoginWidget;
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          loginWidget,
          const SizedBox(height: 16),
          Text(
            loc.cloudStorageLogInCaption,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          LinkButton(
            onPressed: () async {
              await _startLoginFlow(context, forceNoOpenUrl: true);
            },
            child: Text(
              loc.cloudStorageLogInCode,
              textScaler: const TextScaler.linear(0.75),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startLoginFlow(
    BuildContext context, {
    bool forceNoOpenUrl = false,
  }) async {
    final loc = AppLocalizations.of(context);
    try {
      final auth = await provider.startAuth((final prompt) async {
        if (prompt
            is UserAuthenticationPrompt<
              OAuthTokenResult,
              OAuthTokenFlowPromptData
            >) {
          final promptData = prompt.data;
          final uri = promptData.openUri;
          _logger.fine('Launching authentication url $uri');

          if (!forceNoOpenUrl) {
            if (!await DialogUtils.openUrl(uri)) {
              if (!context.mounted) {
                _logger.severe('Widget no longer mounted, not showing dialog.');
                return;
              }
              await DialogUtils.showSimpleAlertDialog(
                context,
                null,
                loc.launchUrlError(uri),
                routeAppend: 'cloudStorageAuthError',
              );
              prompt.result(null);
              return;
            }
          }
          if (!context.mounted) {
            return;
          }
          final code = await SimpleAuthCodePromptDialog(
            title: loc.cloudStorageAuthCodeDialogTitle(provider.displayName),
            labelText: loc.cloudStorageAuthCodeLabel,
          ).show(context);
          prompt.result(OAuthTokenResult(code));
        } else if (prompt
            is UserAuthenticationPrompt<
              UrlUsernamePasswordResult,
              UrlUsernamePasswordPromptData
            >) {
          final result = await UrlUsernamePasswordDialog().show(context);
          prompt.result(result);
        } else {
          throw StateError('Unsupported prompt: $prompt');
        }
      });
      _logger.fine('finished launching. $auth');
      onSuccess();
    } catch (e, stackTrace) {
      _logger.severe('Error while authenticating.', e, stackTrace);
      if (!context.mounted) {
        return;
      }
      await DialogUtils.showErrorDialog(
        context,
        loc.cloudStorageAuthErrorTitle,
        loc.cloudStorageAuthErrorMessage(provider.displayName, e),
      );
    }
  }
}

class UrlUsernamePasswordDialog extends StatefulWidget {
  Future<UrlUsernamePasswordResult?> show(BuildContext context) =>
      showDialog<UrlUsernamePasswordResult>(
        context: context,
        builder: (_) => this,
      );

  @override
  _UrlUsernamePasswordDialogState createState() =>
      _UrlUsernamePasswordDialogState();
}

final _urlRegex = RegExp(r'^https?://');

class _UrlUsernamePasswordDialogState extends State<UrlUsernamePasswordDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final matLoc = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(loc.webDavSettings),
      scrollable: true,
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: loc.webDavUrlLabel,
                helperText: loc.webDavUrlHelperText,
                hintText: nonNls('https://my.nextcloud.com/webdav'),
              ),
              autocorrect: false,
              validator:
                  (SValidator.notEmpty(msg: loc.webDavUrlValidatorError) +
                          SValidator.isTrue(
                            (str) => _urlRegex.hasMatch(str!),
                            loc.webDavUrlValidatorInvalidUrlError,
                          ))
                      .call,
            ),
            TextFormField(
              controller: _username,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: loc.webDavAuthUser,
              ),
            ),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: loc.webDavPassword,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text(matLoc.cancelButtonLabel),
        ),
        TextButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.of(context).pop(
                UrlUsernamePasswordResult(
                  _url.text,
                  _username.text,
                  _password.text,
                ),
              );
            }
          },
          child: Text(matLoc.okButtonLabel),
        ),
      ],
    );
  }
}
