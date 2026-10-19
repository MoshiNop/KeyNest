import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:autofill_service/autofill_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/keynest_cloud_sync_manager.dart';
import 'package:keynest/services/keynest_pending_login_memory.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/ui/screens/locked_screen.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';

final _logger = Logger('security_service');

/// Persistent settings for Auto-Lock timeout and Clipboard auto-clear duration.
class SecuritySettingsStore {
  SecuritySettingsStore._();
  static final SecuritySettingsStore instance = SecuritySettingsStore._();

  // -1 = Never, 0 = Immediate, otherwise seconds
  int _autoLockSeconds = 300; // Default: 5 minutes
  int _clipboardClearSeconds = 30; // Default: 30 seconds
  bool _loaded = false;

  int get autoLockSeconds => _autoLockSeconds;
  int get clipboardClearSeconds => _clipboardClearSeconds;

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    try {
      final appDir = await PathUtils().getAppDataDirectory();
      final file = File('${appDir.path}/security_settings.json');
      if (file.existsSync()) {
        final content = await file.readAsString();
        final map = json.decode(content) as Map<String, dynamic>;
        _autoLockSeconds = map['autoLockSeconds'] as int? ?? 300;
        _clipboardClearSeconds = map['clipboardClearSeconds'] as int? ?? 30;
      }
    } catch (e, stack) {
      _logger.warning('Failed to load security settings: $e', e, stack);
    }
    if (KeyNestPlatform.isAndroid) {
      try {
        await AutofillService().setAutoLockDuration(_autoLockSeconds);
      } catch (_) {}
    }
    _loaded = true;
  }

  Future<void> save({int? autoLockSeconds, int? clipboardClearSeconds}) async {
    if (autoLockSeconds != null) {
      _autoLockSeconds = autoLockSeconds;
      if (KeyNestPlatform.isAndroid) {
        unawaited(AutofillService().setAutoLockDuration(autoLockSeconds));
      }
    }
    if (clipboardClearSeconds != null) {
      _clipboardClearSeconds = clipboardClearSeconds;
    }
    try {
      final appDir = await PathUtils().getAppDataDirectory();
      final file = File('${appDir.path}/security_settings.json');
      await file.writeAsString(
        json.encode({
          'autoLockSeconds': _autoLockSeconds,
          'clipboardClearSeconds': _clipboardClearSeconds,
        }),
      );
    } catch (e, stack) {
      _logger.warning('Failed to save security settings: $e', e, stack);
    }
  }
}

const MethodChannel _miscChannel = MethodChannel('app.keynest/misc');

/// Secure Clipboard helper that automatically clears sensitive secrets (passwords, TOTP, cards)
/// after a configured timeout (defaults to 30 seconds), matching 1Password and Bitwarden standards.
class KeyNestClipboard {
  static Timer? _clearTimer;
  static int _copyGeneration = 0;

  /// Central method to copy sensitive content (passwords, TOTP, cards, CVV, PIN).
  /// Marks the clipboard content with ClipDescription.EXTRA_IS_SENSITIVE on Android 13+,
  /// sets an auto-clear timer, and clears ONLY if the clipboard still holds the exact copied secret.
  static Future<void> copySensitive(
    BuildContext? context,
    String text, {
    String label = 'Item',
    int? customSeconds,
    bool showToast = true,
  }) async {
    if (text.isEmpty) {
      return;
    }

    _clearTimer?.cancel();
    final currentGen = ++_copyGeneration;

    bool nativeDone = false;
    if (KeyNestPlatform.isAndroid) {
      try {
        final res = await _miscChannel.invokeMethod<bool>(
          'setSensitiveClipboard',
          {'text': text, 'label': label},
        );
        nativeDone = res == true;
      } catch (e) {
        _logger.fine(
          'Native sensitive clipboard channel failed/unavailable: $e',
        );
      }
    }
    if (!nativeDone) {
      await Clipboard.setData(ClipboardData(text: text));
    }

    final clearSec =
        customSeconds ?? SecuritySettingsStore.instance.clipboardClearSeconds;

    if (context != null && showToast && context.mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                color: Theme.of(context).brightness == Brightness.dark
                    ? KeyNestTokens.primaryAccent
                    : KeyNestTokens.lightPrimary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  clearSec > 0
                      ? '$label copied. Auto-clearing in ${clearSec}s.'
                      : '$label copied to clipboard.',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          duration: Duration(
            seconds: clearSec > 0 && clearSec < 4 ? clearSec : 3,
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }

    if (clearSec > 0) {
      _clearTimer = Timer(Duration(seconds: clearSec), () async {
        try {
          if (_copyGeneration == currentGen) {
            final currentClip = await Clipboard.getData(Clipboard.kTextPlain);
            // Verify that the clipboard still holds the exact value we copied.
            // If the user copied something else in another app, do not wipe it!
            if (currentClip?.text == text) {
              if (KeyNestPlatform.isAndroid) {
                try {
                  await _miscChannel.invokeMethod('clearClipboardIfMatches', {
                    'text': text,
                  });
                } catch (_) {}
              }
              await Clipboard.setData(const ClipboardData(text: ''));
              _logger.info(
                'Auto-cleared sensitive secret from clipboard after ${clearSec}s',
              );
            } else {
              _logger.fine(
                'Clipboard contents changed since sensitive copy, skipping auto-clear',
              );
            }
          }
        } catch (e) {
          _logger.warning('Failed to auto-clear clipboard: $e');
        }
      });
    }
  }

  /// Copies non-sensitive content (usernames, URLs) without auto-clearing or sensitive flags.
  static Future<void> copyNonSensitive(
    BuildContext? context,
    String text, {
    String label = 'Item',
    bool showToast = true,
  }) async {
    if (text.isEmpty) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));

    if (context != null && showToast && context.mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                color: Theme.of(context).brightness == Brightness.dark
                    ? KeyNestTokens.primaryAccent
                    : KeyNestTokens.lightPrimary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$label copied to clipboard.',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  /// Default copy entry point preserving backwards compatibility.
  static Future<void> copy(
    BuildContext? context,
    String text, {
    String label = 'Item',
    int? customSeconds,
    bool showToast = true,
    bool isSensitive = true,
  }) {
    if (isSensitive) {
      return copySensitive(
        context,
        text,
        label: label,
        customSeconds: customSeconds,
        showToast: showToast,
      );
    } else {
      return copyNonSensitive(
        context,
        text,
        label: label,
        showToast: showToast,
      );
    }
  }

  static void clearNow() {
    _clearTimer?.cancel();
    _copyGeneration++;
    Clipboard.setData(const ClipboardData(text: ''));
  }
}

/// Central facade for application security services.
class SecurityService {
  SecurityService._();

  /// Central method for copying sensitive secrets (passwords, TOTP, card details, PIN, CVV)
  /// to the clipboard. On Android 13+, marks the clip with ClipDescription.EXTRA_IS_SENSITIVE,
  /// auto-clears after a default 30 seconds, and only clears if the clipboard still holds
  /// the copied secret.
  static Future<void> copySensitive(
    BuildContext? context,
    String text, {
    String label = 'Item',
    int? customSeconds,
    bool showToast = true,
  }) => KeyNestClipboard.copySensitive(
    context,
    text,
    label: label,
    customSeconds: customSeconds,
    showToast: showToast,
  );

  /// Central method for copying non-sensitive text (usernames, URLs) without auto-clear
  /// or sensitive flags.
  static Future<void> copyNonSensitive(
    BuildContext? context,
    String text, {
    String label = 'Item',
    bool showToast = true,
  }) => KeyNestClipboard.copyNonSensitive(
    context,
    text,
    label: label,
    showToast: showToast,
  );
}

/// Manages app lifecycle events (backgrounding, pausing) and enforces vault auto-lock.
class SecurityLifecycleManager with WidgetsBindingObserver {
  SecurityLifecycleManager._();
  static final SecurityLifecycleManager instance = SecurityLifecycleManager._();

  DateTime? _pausedAt;
  KdbxBloc? _kdbxBloc;
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _initialized = false;

  void init({
    required KdbxBloc kdbxBloc,
    required GlobalKey<NavigatorState> navigatorKey,
  }) {
    _kdbxBloc = kdbxBloc;
    _navigatorKey = navigatorKey;
    if (!_initialized) {
      WidgetsBinding.instance.addObserver(this);
      _initialized = true;
      SecuritySettingsStore.instance.load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _logger.finer('AppLifecycleState changed: $state');
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pausedAt = DateTime.now();
      QuickUnlockStorage.touchSession();
      if (_kdbxBloc != null) {
        unawaited(KeyNestCloudSyncManager.instance.flushPendingSync(_kdbxBloc!));
      }
      if (KeyNestPlatform.isAndroid) {
        unawaited(AutofillService().touchActive());
      }
    } else if (state == AppLifecycleState.resumed) {
      final paused = _pausedAt;
      _pausedAt = null;
      if (_kdbxBloc != null) {
        unawaited(
          KeyNestCloudSyncManager.instance.recoverPendingSync(_kdbxBloc!),
        );
      }
      if (paused != null) {
        final timeout = SecuritySettingsStore.instance.autoLockSeconds;
        if (timeout >= 0) {
          final diff = DateTime.now().difference(paused).inSeconds;
          if (timeout == 0 || diff >= timeout) {
            _logger.info(
              'Vault auto-lock timeout triggered ($diff s >= $timeout s)',
            );
            _lockVaultNow();
            return;
          }
        }
      }
      QuickUnlockStorage.touchSession();
      if (KeyNestPlatform.isAndroid) {
        unawaited(AutofillService().touchActive());
      }
    }
  }

  void _lockVaultNow() {
    final kdbxBloc = _kdbxBloc;
    final navKey = _navigatorKey;
    if (kdbxBloc == null || navKey == null) {
      return;
    }

    if (kdbxBloc.isSaving) {
      _logger.info(
        'Auto-lock deferred because a vault save is actively in progress.',
      );
      return;
    }

    if (kdbxBloc.openedFilesWithSources.isNotEmpty ||
        QuickUnlockStorage.isSessionValid()) {
      _logger.info('Auto-locking vault due to security policy.');
      KeyNestClipboard.clearNow();
      QuickUnlockStorage.clearSession();
      KeyNestPendingLoginMemory.instance.clear();
      if (KeyNestPlatform.isAndroid) {
        unawaited(AutofillService().clearCredentials());
        unawaited(AutofillService().clearPendingSaveRequest());
      }
      unawaited(kdbxBloc.closeAllFiles(clearQuickUnlock: false));
      navKey.currentState?.pushAndRemoveUntil(
        LockedScreen.route(),
        (_) => false,
      );
    }
  }
}
