import 'package:keynest/env/_base.dart';
import 'package:logging/logging.dart';
import 'package:winsparkle_flutter/winsparkle_flutter.dart';

final _logger = Logger('winsparkle_init');
bool _winSparkleInitialized = false;

Future<void> initWinSparkle(Env env) async {
  // Disabled proprietary update checker
  _winSparkleInitialized = false;
  _logger.fine('WinSparkle updater disabled.');
}

void cleanupWinSparkle() {
  if (!_winSparkleInitialized) {
    return;
  }
  try {
    win_sparkle_cleanup();
    _winSparkleInitialized = false;
  } catch (e, stackTrace) {
    _logger.warning(
      'Error while calling cleanup for WinSparkle',
      e,
      stackTrace,
    );
  }
}

void winSparkleCheckUpdate() {
  if (!_winSparkleInitialized) {
    _logger.fine('Skipping WinSparkle update check: updater is disabled.');
    return;
  }
  win_sparkle_check_update_with_ui();
}
