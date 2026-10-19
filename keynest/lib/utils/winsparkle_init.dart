import 'package:keynest/env/_base.dart';
import 'package:logging/logging.dart';
import 'package:winsparkle_flutter/winsparkle_flutter.dart';

final _logger = Logger('winsparkle_init');

Future<void> initWinSparkle(Env env) async {
  // Disabled proprietary update checker
  _logger.fine('WinSparkle updater disabled.');
}

void cleanupWinSparkle() {
  try {
    win_sparkle_cleanup();
  } catch (e, stackTrace) {
    _logger.warning(
      'Error while calling cleanup for WinSparkle',
      e,
      stackTrace,
    );
  }
}

void winSparkleCheckUpdate() {
  win_sparkle_check_update_with_ui();
}
