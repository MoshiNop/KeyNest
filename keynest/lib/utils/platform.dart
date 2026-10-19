import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:logging/logging.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('platform');

const bool _kIsWeb = kIsWeb;

class KeyNestPlatform {
  static final Map<String, String> environment = _kIsWeb
      ? const {}
      : Platform.environment;

  @NonNls
  static String get version => _kIsWeb ? '0.0' : Platform.version;

  static bool get isWeb => _kIsWeb;
  static bool get isLinux => !_kIsWeb && Platform.isLinux;
  static bool get isWindows => !_kIsWeb && Platform.isWindows;
  @NonNls
  static final bool isWindowsWinAutoUpdate =
      isWindows &&
      const bool.fromEnvironment('KEYNEST_WIN_AUTOUPDATE', defaultValue: true);

  /// Whether this is a "portable" build -
  /// ie. no files will be written outside the application directory.
  /// (application directory is in this case the
  /// parent directory of the executable)
  @NonNls
  static bool get isPortable =>
      !_kIsWeb &&
      const bool.fromEnvironment('KEYNEST_PORTABLE', defaultValue: false);
  static bool get isMacOS => !_kIsWeb && Platform.isMacOS;
  static bool? debugOverrideIsIOS;
  static bool get isIOS => debugOverrideIsIOS ?? (!_kIsWeb && Platform.isIOS);
  static bool? debugOverrideIsAndroid;
  static bool get isAndroid =>
      debugOverrideIsAndroid ?? (!_kIsWeb && Platform.isAndroid);

  @NonNls
  static String get operatingSystem =>
      _kIsWeb ? 'web' : Platform.operatingSystem;
  @NonNls
  static String get operatingSystemVersion =>
      _kIsWeb ? 'web' : Platform.operatingSystemVersion;

  static String? get localeName => _kIsWeb ? null : Platform.localeName;

  static Map<String, String> debugInfo() {
    if (_kIsWeb) {
      return nonNls({
        'platform': 'web',
      });
    }
    String handle(String Function() info) {
      try {
        return info();
      } catch (e) {
        // https://github.com/flutter/flutter/issues/83921
        _logger.finest('error fetching info. ');
        return 'throws: $e'; // NON-NLS
      }
    }

    return nonNls({
      'script': handle(() => Platform.script.toFilePath()),
      'executable': handle(() => Platform.executable),
      'resolvedExecutable': handle(() => Platform.resolvedExecutable),
      'executableArguments': handle(
        () => Platform.executableArguments.toString(),
      ),
    });
  }
}
