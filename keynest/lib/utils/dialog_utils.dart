import 'dart:async';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:keynest/utils/logging_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

final _logger = Logger('keynest.dialog_utils');

/// Displays a smooth Material dialog with optimized GPU layer caching and cubic transitions.
Future<T?> showKeyNestDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor = Colors.black54,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
}) {
  final CapturedThemes themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(
      context,
      rootNavigator: useRootNavigator,
    ).context,
  );

  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    RawDialogRoute<T>(
      pageBuilder: (buildContext, animation, secondaryAnimation) {
        final Widget page = RepaintBoundary(child: Builder(builder: builder));
        Widget content = themes.wrap(page);
        if (useSafeArea) {
          content = SafeArea(child: content);
        }
        return content;
      },
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel:
          barrierLabel ??
          MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 200),
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
            child: child,
          ),
        );
      },
      settings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior: traversalEdgeBehavior,
    ),
  );
}

class DialogUtils {
  static bool _errorDialogShown = false;

  static Future<dynamic> showSimpleAlertDialog(
    BuildContext context,
    String? title,
    String? content, {
    List<Widget>? moreActions,
    @NonNls String routeName = '/dialog/alert/',
    @NonNls required String routeAppend,
  }) {
    final materialLoc = MaterialLocalizations.of(context);
    return showKeyNestDialog<dynamic>(
      context: context,
      routeSettings: RouteSettings(name: routeName + routeAppend),
      builder: (context) {
        return AlertDialog(
          title: title == null ? null : Text(title),
          content: Text(content!),
          actions: <Widget>[
            ...?moreActions,
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(materialLoc.okButtonLabel),
            ),
          ],
        );
      },
    );
  }

  static Future<dynamic> showErrorDialog(
    BuildContext context,
    String? title,
    String? content, {
    @NonNls String? routeAppend,
  }) async {
    if (_errorDialogShown) {
      _logger.warning(
        'We already show an error dialog. do NOT show another one right away.'
        '\ntitle $title\ncontent:$content',
      );
      return;
    }
    final loc = AppLocalizations.of(context);
    try {
      _errorDialogShown = true;
      return await showSimpleAlertDialog(
        context,
        title,
        content,
        routeAppend: 'error${routeAppend?.prepend('/') ?? ''}',
        moreActions: [
          if (sendLogsSupported()) ...[
            TextButton(
              onPressed: () {
                sendLogs(
                  context,
                  errorDescription: 'title: $title\ncontent: $content',
                );
              },
              child: Text(loc.dialogSendErrorReport),
            ),
          ],
          TextButton(
            onPressed: () async {
              context.read<Analytics>().events.trackActionPressed(
                action: 'reportToForum',
              );
              final env = context.read<Env>();
              final forumUrl = env.forumUrlNewTopic(
                title: nonNls('Error Dialog: ${title ?? content}'),
                body: nonNls(
                  '\n\n\n'
                  'title:$title\n'
                  'content: $content\n'
                  'OS: ${KeyNestPlatform.operatingSystem} '
                  '${KeyNestPlatform.operatingSystemVersion}\n'
                  'App Info: ${(await env.getAppInfo()).longString}\n'
                  'Device: ${await LoggingUtils.getDebugDeviceInfo()}',
                ),
                category: 11,
                tags: [nonNls('fromapp')],
              );
              _logger.finer('Opening forum url (${forumUrl.length}) $forumUrl');
              await DialogUtils.openUrl(forumUrl);
            },
            child: Text(loc.dialogReportErrorForum),
          ),
        ],
      );
    } finally {
      _errorDialogShown = false;
    }
  }

  /// Normalizes a URL string by ensuring a scheme is present.
  /// If the URL lacks an explicit scheme (e.g. 'google.com' or 'www.google.com'),
  /// 'https://' is prepended by default. Explicit schemes such as 'http://' or 'https://'
  /// are preserved.
  static String normalizeUrl(@NonNls String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme && uri.scheme.isNotEmpty) {
      return trimmed;
    }
    return 'https://$trimmed';
  }

  static Future<bool> openUrl(@NonNls String url) async {
    final normalized = normalizeUrl(url);
    try {
      final uri = Uri.tryParse(normalized);
      if (uri == null || !uri.hasScheme) {
        return false;
      }
      return await launchUrlString(
        normalized,
        mode: LaunchMode.externalApplication,
      );
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to launch URL: $url (normalized: $normalized)',
        e,
        stackTrace,
      );
      return false;
    }
  }

  static Future<bool> openUri(@NonNls Uri uri) async {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static Future<bool> showConfirmDialog({
    required BuildContext context,
    required ConfirmDialogParams params,
  }) async {
    return (await showKeyNestDialog<bool>(
          context: context,
          routeSettings: const RouteSettings(name: '/dialog/confirm'),
          builder: (context) => ConfirmDialog(params: params),
        )) ==
        true;
  }

  static bool sendLogsSupported() =>
      KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid;

  @NonNls
  static Future<void> sendLogs(
    BuildContext context, {
    @NonNls String errorDescription = '',
  }) async {
    final env = Provider.of<Env>(context, listen: false);
    final loggingUtil = LoggingUtils();
    final logFiles = loggingUtil.rotatingFileLoggerFiles;
    final logFileDebug = logFiles
        .map((file) => '${file.absolute.path}: ${file.statSync()}')
        .join('\n\n');
    final details = errorDescription.isEmpty
        ? ''
        : '===================\n$errorDescription';
    final email = Email(
      subject:
          'Log file for '
          '${await env.getAppInfo()} (${KeyNestPlatform.operatingSystem})',
      body:
          '\n\n\n\n$details\n'
          '====================Available Log Files:\n$logFileDebug',
      recipients: ['moshiiur@proton.me'],
      // for now just take the current one.
      attachmentPaths: [logFiles.first.absolute.path],
    );
    await FlutterEmailSender.send(email);
  }
}

class LogViewerDialog extends StatelessWidget {
  const LogViewerDialog({super.key, this.title, this.log});

  final String? title;
  final StringBufferWrapper? log;

  @override
  Widget build(BuildContext context) {
    final matLoc = MaterialLocalizations.of(context);
    return AlertDialog(
      title: title == null ? null : Text(title!),
      insetPadding: const EdgeInsets.all(4),
      contentPadding: const EdgeInsets.all(4),
      content: Scrollbar(
        child: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: log!,
            builder: (context, snapshot) {
              return Text(
                log.toString(),
                textScaler: const TextScaler.linear(0.5),
              );
            },
          ),
        ),
      ),
      actions: <Widget>[
        // ...?moreActions,
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text(matLoc.okButtonLabel),
        ),
      ],
    );
  }

  Future<void> open(BuildContext context) => showKeyNestDialog<void>(
    context: context,
    builder: (context) => this,
    routeSettings: const RouteSettings(name: '/dialog/log'),
  );
}

extension BuildContextError on BuildContext {
  Future<T> handleErrors<T>(String message, Future<T> Function() cb) async {
    try {
      return await cb();
    } catch (error, stackTrace) {
      _logger.severe('Error during action', error, stackTrace);
      final loc = AppLocalizations.of(this);
      await DialogUtils.showErrorDialog(
        this,
        loc.genericErrorDialogTitle,
        loc.genericErrorDialogBody(error),
      );
      rethrow;
    }
  }
}

class ConfirmDialogParams {
  ConfirmDialogParams({
    this.title,
    required this.content,
    this.positiveButtonText,
    this.negativeButtonText,
  });

  final String? title;
  final String content;
  final String? positiveButtonText;
  final String? negativeButtonText;
}

class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({super.key, required this.params});
  final ConfirmDialogParams params;

  @override
  Widget build(BuildContext context) {
    final matLoc = MaterialLocalizations.of(context);
    return RepaintBoundary(
      child: AlertDialog(
        title: params.title?.let((it) => Text(it)),
        content: Text(params.content),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(params.negativeButtonText ?? matLoc.cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(params.positiveButtonText ?? matLoc.okButtonLabel),
          ),
        ],
      ),
    );
  }
}

mixin DialogMixin<T> on Widget {
  String get name;

  Future<T?> show(BuildContext context) => showKeyNestDialog<T>(
    context: context,
    routeSettings: RouteSettings(name: name),
    builder: (context) => this,
  );
}

class SimpleAuthCodePromptDialog extends StatefulWidget
    with DialogMixin<String> {
  const SimpleAuthCodePromptDialog({
    super.key,
    this.title,
    this.labelText,
    this.helperText,
    this.initialValue = CharConstants.empty,
  });

  final String? title;
  final String? labelText;
  final String? helperText;
  final String initialValue;

  @override
  _SimpleAuthCodePromptDialogState createState() =>
      _SimpleAuthCodePromptDialogState();

  @NonNls
  @override
  String get name => '/dialog/authCode';
}

class _SimpleAuthCodePromptDialogState
    extends State<SimpleAuthCodePromptDialog> {
  FilePickerState? _fps;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fps == null) {
      _fps = Provider.of<FilePickerState>(context);
      _fps?.registerUriHandler(_handleUri);
      if (_fps == null) {
        _logger.warning(
          'No url handler declared. User will have to manually enter code.',
        );
      }
    }
  }

  bool _handleUri(Uri uri) {
    _logger.fine('Handling uri: $uri');
    final code = uri.queryParameters[nonNls('code')];
    if (code != null && code.isNotEmpty) {
      Navigator.of(context).pop(code);
    }
    return true;
  }

  @override
  void dispose() {
    super.dispose();
    _fps?.removeUriHandler(_handleUri);
  }

  @override
  Widget build(BuildContext context) {
    return SimplePromptDialog(
      title: widget.title,
      labelText: widget.labelText,
      helperText: widget.helperText,
      initialValue: widget.initialValue,
    );
  }
}

class SimplePromptDialog extends StatefulWidget with DialogMixin<String> {
  const SimplePromptDialog({
    super.key,
    this.title,
    this.labelText,
    this.initialValue = CharConstants.empty,
    this.helperText,
  });
  final String? title;
  final String? labelText;
  final String? helperText;
  final String initialValue;

  @Deprecated('Use [dialog.show] instead.')
  static Future<String?> showPrompt(
    BuildContext context,
    SimplePromptDialog dialog,
  ) => dialog.show(context);

  @override
  _SimplePromptDialogState createState() => _SimplePromptDialogState();

  @NonNls
  @override
  String get name => '/dialog/prompt/simple';
}

class _SimplePromptDialogState extends State<SimplePromptDialog>
    with WidgetsBindingObserver {
  TextEditingController? _controller;
  AppLifecycleState? _previousState;
  String? _previousClipboard;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _readClipboard();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _readClipboard({bool setIfChanged = false}) async {
    final text = await getClipboardText();
    if (setIfChanged && text != _previousClipboard && text != null) {
      _controller!.text = text;
      _controller!.selection = TextSelection(
        baseOffset: 0,
        extentOffset: text.length,
      );
    }
    _previousClipboard = text;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _logger.fine('lifecycle state changed to $state (was: $_previousState)');
    if (state == AppLifecycleState.resumed) {
      _readClipboard(setIfChanged: true);
    }
    _previousState = state;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final matLoc = MaterialLocalizations.of(context);
    return AlertDialog(
      title: widget.title == null ? null : Text(widget.title!),
      content: Container(
        constraints: const BoxConstraints(minWidth: 400.0),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: loc.promptDialogPasteActionTooltip,
              icon: const FaIcon(FontAwesomeIcons.paste),
              onPressed: () async {
                _controller!.text =
                    await getClipboardText() ?? CharConstants.empty;
              },
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(
                  labelText: widget.labelText,
                  helperText: widget.helperText ?? loc.promptDialogPasteHint,
                  helperMaxLines: 2,
                ),
                autofocus: true,
                onEditingComplete: () {
                  Navigator.of(context).pop(_controller!.text);
                },
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
            Navigator.of(context).pop(_controller!.text);
          },
          child: Text(matLoc.okButtonLabel),
        ),
      ],
    );
  }
}

Future<String?> getClipboardText() async {
  return (await Clipboard.getData(AppConstants.contentTypeTextPlain))?.text;
}

extension BuildContextSnackBar on BuildContext {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) {
    final messenger = ScaffoldMessenger.of(this);
    messenger.clearSnackBars();
    return messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration:
            duration ??
            (action != null
                ? const Duration(milliseconds: 2500)
                : const Duration(milliseconds: 1500)),
        action: action,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
