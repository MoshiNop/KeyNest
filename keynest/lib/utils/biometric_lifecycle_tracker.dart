import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _logger = Logger('biometric_tracker');

/// Timing instrumentation for tracing biometric workflows and entry latencies.
/// Strictly measures elapsed durations and stage milestones without ever logging
/// passwords, master keys, biometric secrets, tokens, or vault contents.
class BiometricLifecycleTracker {
  BiometricLifecycleTracker._();

  static final BiometricLifecycleTracker instance =
      BiometricLifecycleTracker._();

  final Map<String, Stopwatch> _watches = {};

  void start(String operation) {
    if (kReleaseMode) {
      return;
    }
    final sw = Stopwatch()..start();
    _watches[operation] = sw;
    _logger.info('[TIMING] [$operation] Started');
  }

  void mark(String operation, String stage) {
    if (kReleaseMode) {
      return;
    }
    final sw = _watches[operation];
    if (sw != null) {
      _logger.info(
        '[TIMING] [$operation] -> Stage "$stage" reached at ${sw.elapsedMilliseconds}ms',
      );
    }
  }

  int stop(String operation, [String? finalStage]) {
    final sw = _watches.remove(operation);
    if (sw != null) {
      sw.stop();
      if (!kReleaseMode) {
        final stageStr = finalStage != null ? ' -> $finalStage' : '';
        _logger.info(
          '[TIMING] [$operation] Completed$stageStr: total ${sw.elapsedMilliseconds}ms',
        );
      }
      return sw.elapsedMilliseconds;
    }
    return 0;
  }
}
