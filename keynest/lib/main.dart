import 'dart:async';

import 'package:autofill_service/autofill_service.dart';
import 'package:file/local.dart';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:flutter_windowmanager/flutter_windowmanager.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/deps.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_bloc.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/env/development.dart';
import 'package:keynest/env/production.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/screens/keynest_autofill_sheet.dart';
import 'package:keynest/ui/screens/locked_screen.dart';
import 'package:keynest/ui/screens/main_app_scaffold.dart';
import 'package:keynest/ui/screens/onboarding/onboarding.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/ui/widgets/platform_menu_bar.dart';
import 'package:keynest/utils/cache_manager.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:keynest/utils/file_picker_writable_noop.dart';
import 'package:keynest/utils/format_utils.dart';
import 'package:keynest/utils/logging_utils.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:keynest/utils/winsparkle_init_noop.dart'
    if (dart.library.io) 'package:keynest/utils/winsparkle_init.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:simple_json_persistence/simple_json_persistence.dart';

final _logger = Logger('main');

void initIsolate({bool fromMain = false}) {
  LoggingUtils().setupLogging(fromMainIsolate: fromMain);
}

Future<void> main() async {
  if (kIsWeb || kReleaseMode) {
    await Production().start();
  } else {
    await Development().start();
  }
}

final startupStopwatch = Stopwatch();

Future<void> startApp(Env env) async {
  startupStopwatch
    ..start()
    ..reset();

  StoreBackend.defaultBaseDirectoryBuilder = () async =>
      (await PathUtils().getAppDataDirectory()).path;

  initIsolate(fromMain: true);
  _setTargetPlatformForDesktop();
  _logger.info(
    'Initialized logger. '
    '(${KeyNestPlatform.operatingSystem}, ${KeyNestPlatform.operatingSystemVersion}) ${startupStopwatch.elapsedMilliseconds}',
  );
  if (!KeyNestPlatform.isWeb) {
    _logger.info('${KeyNestPlatform.debugInfo()}');
    unawaited(
      Future<dynamic>.delayed(const Duration(seconds: 10)).then((
        dynamic value,
      ) async {
        _logger.info('DeviceInfo: ${await LoggingUtils.getDebugDeviceInfo()}');
      }),
    );
  }

  final navigatorKey = GlobalKey<NavigatorState>();

  if (env.overrideFlutterOnError) {
    FlutterError.onError = (errorDetails) {
      _logger.shout(
        'Unhandled Flutter framework (${errorDetails.library}) error.',
        errorDetails.exception,
        errorDetails.stack,
      );
      _logger.fine(errorDetails.summary.toString());
      Analytics.trackError(
        ErrorSource.flutter,
        errorDetails.summary.toString(),
        true,
      );
    };
  }

  FutureTaskStateMixin.defaultShowErrorDialog = (error) {
    navigatorKey.currentState?.overlay?.context.let((context) {
      DialogUtils.showErrorDialog(
        context,
        error.title,
        error.message,
      );
    });
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    _logger.shout('Unhandled error in app.', error, stackTrace);
    final errorString = error is Exception
        ? error.toStringWithCause()
        : error.toString();
    Analytics.trackError(ErrorSource.dart, error.toString(), true);
    navigatorKey.currentState?.overlay?.context.let((context) {
      String? message = 'Unexpected error: $errorString'; // NON-NLS
      try {
        message = AppLocalizations.of(context).unexpectedError(errorString);
      } catch (e, stackTrace) {
        _logger.fine('Error while localizing error message', e, stackTrace);
      }
      DialogUtils.showErrorDialog(context, null, message);
    });
    return true;
  };

  WidgetsFlutterBinding.ensureInitialized();
  await SecuritySettingsStore.instance.load();
  await KeyNestVaultScope.instance.init();
  final deps = Deps(env: env);
  deps.kdbxBloc.delegate = KdbxBlocDelegateHandler(navigatorKey);

  final appData = await deps.appDataBloc.store.load();
  final hasCompletedOnboarding =
      await KeyNestPreferencesService.hasCompletedOnboarding();
  final hasAvailable = await KdbxBloc.hasAvailableVault(
    appData,
    deps.cloudStorageBloc,
  );
  if (hasAvailable && !hasCompletedOnboarding) {
    await KeyNestPreferencesService.setCompletedOnboarding(true);
  }
  final onboardingDone = hasCompletedOnboarding || hasAvailable;

  if (KeyNestPlatform.isAndroid &&
      appData.previousFiles.isNotEmpty &&
      onboardingDone) {
    await deps.kdbxBloc.trySilentRestoreAndUnlock();
  }
  runApp(
    KeyNestApp(
      env: env,
      deps: deps,
      navigatorKey: navigatorKey,
      isFirstRun: !onboardingDone,
    ),
  );
}

class KdbxBlocDelegateHandler extends KdbxBlocDelegate {
  KdbxBlocDelegateHandler(this.navigatorKey);

  GlobalKey<NavigatorState> navigatorKey;

  @override
  void conflictMerged(
    FileSource fileSource,
    KdbxFile file,
    MergeContext merge,
  ) {
    final context = navigatorKey.currentContext;
    if (context == null) {
      return;
    }
    final loc = AppLocalizations.of(context);
    DialogUtils.showSimpleAlertDialog(
      context,
      loc.mergeSuccessDialogTitle,
      loc.mergeSuccessDialogMessage(
        fileSource.displayName,
        merge.debugSummary(),
      ),
      routeAppend: 'merged',
    );
  }
}

/// If the current platform is desktop, override the default platform to
/// a supported platform (iOS for macOS, Android for Linux and Windows).
/// Otherwise, do nothing.
void _setTargetPlatformForDesktop() {
  // Desktop platform targets are handled natively by Flutter.
}

class KeyNestApp extends StatefulWidget {
  const KeyNestApp({
    super.key,
    required this.env,
    required this.navigatorKey,
    required this.deps,
    required this.isFirstRun,
  });

  final Env env;
  final Deps deps;
  final GlobalKey<NavigatorState> navigatorKey;
  final bool isFirstRun;
  @visibleForTesting
  static GlobalKey<NavigatorState>? currentNavigatorKey;

  @override
  // ignore: no_logic_in_create_state
  _KeyNestAppState createState() {
    currentNavigatorKey = navigatorKey;
    return _KeyNestAppState();
  }
}

class _KeyNestAppState extends State<KeyNestApp> with StreamSubscriberMixin {
  late final Deps _deps = widget.deps;
  AppData? _appData;
  late final FilePickerState _filePickerState = _initFilePickerState();

  GlobalKey<NavigatorState>? get _navigatorKey => widget.navigatorKey;

  Locale? _cachedLocale;
  FormatUtils? _cachedFormatUtils;
  AppLocalizations? _cachedLocalizations;
  CommonFields? _cachedCommonFields;

  @override
  void initState() {
    super.initState();
    SecurityLifecycleManager.instance.init(
      kdbxBloc: _deps.kdbxBloc,
      navigatorKey: widget.navigatorKey,
    );
    PathUtils.runAppFinished.complete(true);
    _appData = _deps.appDataBloc.store.cachedValue;
    handleSubscription(
      _deps.appDataBloc.store.onValueChangedAndLoad.listen((appData) {
        final current = _appData;
        if (current == null ||
            current.theme != appData.theme ||
            current.themeFontSizeFactor != appData.themeFontSizeFactor ||
            current.localeOverride != appData.localeOverride) {
          setState(() {
            _appData = appData;
          });
        } else {
          _appData = appData;
        }
      }),
    );
    if (KeyNestPlatform.isAndroid) {
      handleSubscription(
        AutofillService().onAutofillRequest.listen((_) async {
          final nav = _navigatorKey?.currentState;
          if (nav == null) {
            return;
          }
          SecurityLifecycleManager.instance.checkAutoLock();
          // Remove any stale autofill sheets before presenting new request
          nav.popUntil((route) => route.isFirst);
          var isUnlocked = _deps.kdbxBloc.openedFilesKdbx.isNotEmpty;
          if (!isUnlocked) {
            final restored = await _deps.kdbxBloc.trySilentRestoreAndUnlock();
            isUnlocked = restored || _deps.kdbxBloc.openedFilesKdbx.isNotEmpty;
          }
          if (isUnlocked) {
            QuickUnlockStorage.touchSession();
            nav.pushAndRemoveUntil(
              MainAppScaffold.route(),
              (_) => false,
            );
            nav.push(KeyNestAutofillSheet.route(kdbxBloc: _deps.kdbxBloc));
          } else {
            final hasFiles =
                _deps.appDataBloc.store.cachedValue?.previousFiles.isNotEmpty ??
                false;
            if (hasFiles) {
              nav.push(LockedScreen.route(isAutofill: true));
            } else {
              nav.push(SelectFileScreen.route(skipQuickUnlock: true));
            }
          }
        }),
      );
      handleSubscription(
        AutofillService().onAutofillCancelled.listen((_) {
          final nav = _navigatorKey?.currentState;
          if (nav != null && nav.canPop()) {
            nav.pop();
          }
        }),
      );
      handleSubscription(
        AutofillService().onAutofillDismissed.listen((_) async {
          final nav = _navigatorKey?.currentState;
          if (nav != null) {
            nav.popUntil((route) => route.isFirst);
            var isUnlocked = _deps.kdbxBloc.openedFilesKdbx.isNotEmpty;
            if (!isUnlocked) {
              final restored = await _deps.kdbxBloc.trySilentRestoreAndUnlock();
              isUnlocked =
                  restored || _deps.kdbxBloc.openedFilesKdbx.isNotEmpty;
            }
            if (isUnlocked) {
              nav.pushAndRemoveUntil(
                MainAppScaffold.route(),
                (_) => false,
              );
            }
          }
        }),
      );
      handleSubscription(
        _deps.appDataBloc.store.onValueChangedAndLoad
            .map((event) => event.secureWindowOrDefault)
            .distinct()
            .listen((secureWindowOrDefault) {
              if (secureWindowOrDefault) {
                FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);
              } else {
                FlutterWindowManager.clearFlags(
                  FlutterWindowManager.FLAG_SECURE,
                );
              }
            }),
      );
    }
    if (KeyNestPlatform.isWindows) {
      if (KeyNestPlatform.isWindowsWinAutoUpdate) {
        _logger.info('Initializing winsparkle.');
        initWinSparkle(widget.env);
      } else {
        _logger.info('Disabled winsparkle.');
      }
    }
  }

  FilePickerState _initFilePickerState() {
    // file picker writable currently has only ios, android, macos support.
    if (KeyNestPlatform.isIOS ||
        KeyNestPlatform.isAndroid ||
        KeyNestPlatform.isMacOS) {
      _logger.fine('Register FilePickerWritable listeners.');
      return FilePickerWritable().init()
        ..registerUriHandler((uri) {
          _logger.fine('we have received uri: $uri');
          return false;
        })
        ..registerFileOpenHandler((fileInfo, file) async {
          _logger.fine('got a new fileInfo: $fileInfo');
          Future<void> openRoute() async {
            var i = 0;
            while (_navigatorKey?.currentState == null) {
              _logger.finest('No navigator yet. waiting. $i');
              await Future<void>.delayed(const Duration(milliseconds: 100));
              if (i++ > 100) {
                _logger.warning('Giving up $fileInfo');
                return;
              }
            }
            await _navigatorKey!.currentState!.push(
              CredentialsScreen.route(
                FileSourceLocal(
                  (const LocalFileSystem()).file(file.path),
                  uuid: AppDataBloc.createUuid(),
                  filePickerIdentifier: fileInfo.toJsonString(),
                  initialCachedContent: FileContent(await file.readAsBytes()),
                ),
              ),
            );
          }

          await openRoute();
          return true;
        })
        ..registerErrorEventHandler((errorEvent) async {
          _logger.severe('Error received from file picker. $errorEvent');
          Analytics.trackError(
            ErrorSource.app,
            'FilePickerWritable: $errorEvent',
            false,
          );
          return true;
        });
    } else {
      return FilePickerStateNoop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = View.maybeOf(context);
    _logger.fine(
      'Building KeyNest App state. route: '
      '${view?.platformDispatcher.defaultRouteName}',
    );
    return MultiProvider(
      providers: [
        Provider<FilePickerState>.value(value: _filePickerState),
        Provider<Env>.value(value: _deps.env),
        Provider<Deps>.value(value: _deps),
        Provider<Analytics>.value(value: _deps.analytics),
        ChangeNotifierProvider<CloudStorageBloc>.value(
          value: _deps.cloudStorageBloc,
        ),
        Provider<AppDataBloc>.value(value: _deps.appDataBloc),
        Provider<KeyNestCacheManager>(
          create: (context) => KeyNestCacheManager(
            pathUtils: PathUtils(),
            env: _deps.env,
          ),
          dispose: (context, obj) => obj.store.dispose(),
        ),
        StreamProvider<AppData>(
          create: (context) => _deps.appDataBloc.store.onValueChangedAndLoad,
          initialData: _deps.appDataBloc.store.cachedValue ?? AppData(),
        ),
        StreamProvider<KdbxBloc>(
          create: (context) => _deps.kdbxBloc.openedFilesChanged
              .distinct((prev, curr) {
                if (prev.length != curr.length) {
                  return false;
                }
                for (final entry in prev.entries) {
                  if (!curr.containsKey(entry.key)) {
                    return false;
                  }
                }
                return true;
              })
              .map((_) => _deps.kdbxBloc)
              .doOnData((data) {
                _logger.info('KdbxBloc updated.');
              }),
          updateShouldNotify: (a, b) => true,
          initialData: _deps.kdbxBloc,
        ),
        StreamProvider<OpenedKdbxFiles>.value(
          value: _deps.kdbxBloc.openedFilesChanged,
          initialData: _deps.kdbxBloc.openedFilesChanged.value,
        ),
      ],
      child: MaterialApp(
        navigatorObservers: [AnalyticsNavigatorObserver(_deps.analytics)],
        title: AppConstants.keyNest,
        navigatorKey: widget.navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        theme: _customizeTheme(keyNestLightTheme, _appData),
        darkTheme: _customizeTheme(keyNestDarkTheme, _appData),
        themeMode: _toThemeMode(_appData?.theme),
        locale: _parseLocale(_appData?.localeOverride),
        //        themeMode: ThemeMode.light,
        builder: (context, child) {
          final mq = MediaQuery.of(context);
          final physicalSize = view?.physicalSize;
          _deps.analytics.updateSizes(
            viewportSizeWidth: mq.size.width,
            viewportSizeHeight: mq.size.height,
            displaySizeWidth: physicalSize?.width,
            displaySizeHeight: physicalSize?.height,
            devicePixelRatio: view?.devicePixelRatio,
          );
          final locale = Localizations.localeOf(context);
          final localizations = AppLocalizations.of(context);
          if (_cachedLocale != locale || _cachedFormatUtils == null) {
            _cachedLocale = locale;
            _cachedFormatUtils = FormatUtils(locale: locale.toString());
          }
          if (_cachedLocalizations != localizations ||
              _cachedCommonFields == null) {
            _cachedLocalizations = localizations;
            _cachedCommonFields = CommonFields(localizations);
          }
          final Widget ret = MultiProvider(
            providers: [
              Provider.value(value: _cachedFormatUtils!),
              Provider<CommonFields>.value(value: _cachedCommonFields!),
            ],
            child: PlatformMenuBarWrapper(
              navigatorKey: _navigatorKey!,
              child: child ?? Container(),
            ),
          );
          if (_appData?.themeFontSizeFactor != null) {
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(
                begin: _appData!.themeFontSizeFactor,
                end: _appData!.themeFontSizeFactor,
              ),
              duration: const Duration(milliseconds: 100),
              builder: (context, value, child) {
                return MediaQuery(
                  data: mq.copyWith(textScaler: TextScaler.linear(value)),
                  child: ret,
                );
              },
            );
          }
          return ret;
        },
        onGenerateInitialRoutes: (initialRoute) {
          _logger.fine('initialRoute: $initialRoute');
          _deps.analytics.trackScreen(initialRoute);
          _deps.analytics.events.trackLaunch(
            systemBrightness: view?.platformDispatcher.platformBrightness,
          );
          if (startupStopwatch.isRunning) {
            startupStopwatch.stop();
            _deps.analytics.trackTiming(
              'startup',
              startupStopwatch.elapsedMilliseconds,
              category: 'startup',
              label: widget.isFirstRun ? 'startup firstRun' : 'startup run',
            );
          }
          final appData = _deps.appDataBloc.store.cachedValue;
          final hasPreviousFiles =
              appData != null && appData.previousFiles.isNotEmpty;
          final isUnlocked =
              _deps.kdbxBloc.openedFilesKdbx.isNotEmpty ||
              _deps.kdbxBloc.canSilentQuickUnlock();
          final isFirstRun = widget.isFirstRun;

          final baseRoute =
              (isFirstRun && widget.env.featureOnboarding
                      ? OnboardingScreen.route()
                      : (isUnlocked
                            ? MainAppScaffold.route()
                            : (hasPreviousFiles
                                  ? LockedScreen.route()
                                  : SelectFileScreen.route(
                                      skipQuickUnlock: true,
                                    ))))
                  as Route<dynamic>;

          if (initialRoute == '/autofill') {
            final autofillRoute =
                (isUnlocked
                        ? KeyNestAutofillSheet.route(kdbxBloc: _deps.kdbxBloc)
                        : (hasPreviousFiles
                              ? LockedScreen.route(isAutofill: true)
                              : SelectFileScreen.route(skipQuickUnlock: true)))
                    as Route<dynamic>;
            final safeBaseRoute =
                (isUnlocked
                        ? MainAppScaffold.route()
                        : (hasPreviousFiles
                              ? MainAppScaffold.route()
                              : (isFirstRun && widget.env.featureOnboarding
                                    ? OnboardingScreen.route()
                                    : SelectFileScreen.route(
                                        skipQuickUnlock: true,
                                      ))))
                    as Route<dynamic>;
            return [
              safeBaseRoute,
              autofillRoute,
            ];
          }
          if (initialRoute.startsWith(AppConstants.routeOpenFile)) {
            final uri = Uri.parse(initialRoute);

            final file =
                uri.queryParameters[AppConstants.routeOpenFileParamFile];
            _logger.finer('uri: $uri /// file: $file');
            return [
              //              MaterialPageRoute<void>(
              //                  builder: (context) => const SelectFileScreen()),
              CredentialsScreen.route(
                FileSourceLocal(
                  (const LocalFileSystem().file(file)),
                  uuid: AppDataBloc.createUuid(),
                ),
              ),
            ];
          }
          return [
            baseRoute,
          ];
        },
        // this is actually never used. But i still have to define it,
        // because of https://github.com/flutter/flutter/blob/f64f6e2b6bf5802f23d6a0e3896541b213be490a/packages/flutter/lib/src/widgets/app.dart#L226-L243
        // (defining a navigatorKey requires defining a `routes`)
        routes: {
          AppConstants.routeOpen: (context) => const SelectFileScreen(),
        },
      ),
    );
  }

  // TODO maybe support more than language code?
  Locale? _parseLocale(String? localeString) {
    if (localeString == null) {
      return null;
    }
    final parts = localeString.split(CharConstants.underScore);
    if (parts.length == 1) {
      return Locale(parts[0]);
    }
    return Locale(parts[0], parts[1]);
  }

  ThemeMode? _toThemeMode(AppDataTheme? theme) {
    if (theme == null) {
      return null;
    }
    switch (theme) {
      case AppDataTheme.light:
        return ThemeMode.light;
      case AppDataTheme.dark:
        return ThemeMode.dark;
    }
  }

  ThemeData _customizeTheme(ThemeData theme, AppData? appData) {
    if (appData == null) {
      return theme;
    }

    final visualDensity = appData.themeVisualDensity != null
        ? VisualDensity(
            horizontal: appData.themeVisualDensity!,
            vertical: appData.themeVisualDensity!,
          )
        : theme.visualDensity;
    _logger.fine('appData.themeFontSizeFactor: ${appData.themeFontSizeFactor}');
    return theme.copyWith(
      visualDensity: visualDensity,
    );
  }
}

class AnalyticsNavigatorObserver extends NavigatorObserver {
  AnalyticsNavigatorObserver(this.analytics);

  final Analytics analytics;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _logger.finest('didPush');
    _sendScreenView(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _sendScreenView(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _sendScreenView(previousRoute);
  }

  String _screenNameFor(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null) {
      return name;
    }
    assert(
      (() {
        if (route is PopupRoute) {
          return true;
        }
        _logger.severe(
          'Route does not have a named RouteSettings! $route',
          null,
          StackTrace.current,
        );
        return true;
      })(),
    );
    return (route?.runtimeType).toString(); // NON-NLS
  }

  void _sendScreenView(Route<dynamic>? route) {
    final screenName = _screenNameFor(route);
    analytics.trackScreen(screenName);
  }
}
