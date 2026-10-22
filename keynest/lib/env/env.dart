import 'package:flutter/services.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/main.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('env');

const _DEFAULT_APP_NAME = AppConstants.keyNest;
@NonNls
const _DEFAULT_VERSION = String.fromEnvironment(
  'KEYNEST_VERSION',
  defaultValue: '1.0.1',
);
@NonNls
const _DEFAULT_BUILD_NUMBER = int.fromEnvironment(
  'KEYNEST_BUILD_NUMBER',
  defaultValue: 2,
);
@NonNls
const _DEFAULT_PACKAGE_NAME = String.fromEnvironment(
  'KEYNEST_PACKAGE_NAME',
  defaultValue: 'com.moshinop.keynest.dev',
);

abstract class EnvAppBase extends Env {
  EnvAppBase(super.type);

  @NonNls
  static const _ENV_STORAGE_NAMESPACE = 'KEYNEST_STORAGE_NAMESPACE';

  @override
  EnvSecrets? get secrets;

  @NonNls
  @override
  String? get oauthRedirectUri => null;
  @override
  bool get oauthRedirectUriSupported =>
      KeyNestPlatform.isIOS ||
      KeyNestPlatform.isAndroid ||
      KeyNestPlatform.isMacOS;

  @override
  String? get storageNamespaceFromEnvironment =>
      KeyNestPlatform.environment[_ENV_STORAGE_NAMESPACE];

  Future<void> start() async {
    await startApp(this);
  }

  @override
  Future<AppInfo> getAppInfo() async {
    final pi = await _getPackageInfo();
    return AppInfo(
      (b) => b
        ..appName = pi?.appName.nullIfBlank() ?? _DEFAULT_APP_NAME
        ..version = pi?.version.nullIfBlank() ?? _DEFAULT_VERSION
        ..buildNumber =
            int.tryParse(
              pi?.buildNumber.nullIfBlank() ?? _DEFAULT_BUILD_NUMBER.toString(),
            ) ??
            _DEFAULT_BUILD_NUMBER
        ..packageName = pi?.packageName.nullIfBlank() ?? _DEFAULT_PACKAGE_NAME,
    );
  }

  Future<PackageInfo?> _getPackageInfo() async {
    try {
      // linux and windows don't support this right now.
      if (KeyNestPlatform.isWeb ||
          KeyNestPlatform.isLinux ||
          KeyNestPlatform.isWindows) {
        return null;
      }
      return await PackageInfo.fromPlatform();
    } on PlatformException catch (e, stackTrace) {
      _logger.severe('Error getting package info', e, stackTrace);
      return null;
    }
  }
}
