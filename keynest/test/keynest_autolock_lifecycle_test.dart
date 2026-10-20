import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KeyNest Auto-Lock Lifecycle Test Suite', () {
    late SecurityLifecycleManager manager;
    final dummySource = FileSourceUrl(
      Uri.parse('https://example.com/test.kdbx'),
      uuid: 'vault-uuid-autolock',
      databaseName: 'Personal',
    );
    final creds = Credentials(ProtectedValue.fromString('master-pass'));

    setUp(() {
      manager = SecurityLifecycleManager.instance;
      manager.pausedAt = null;
      QuickUnlockStorage.clearSession();
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
    });

    tearDown(() {
      manager.pausedAt = null;
      QuickUnlockStorage.clearSession();
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
    });

    test('Initial backgrounding (inactive -> paused) records pausedAt timestamp', () {
      expect(manager.pausedAt, isNull);

      // 1. App transitions resumed -> inactive
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      final initialPausedAt = manager.pausedAt;
      expect(initialPausedAt, isNotNull);

      // 2. App transitions inactive -> paused
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      // pausedAt must NOT be changed to a new timestamp; it must retain the initial time
      expect(manager.pausedAt, equals(initialPausedAt));
    });

    test(
      'Returning from background (paused -> inactive -> resumed) does NOT overwrite pausedAt during inactive',
      () {
        // App backgrounded at T0 (5 minutes ago)
        final fiveMinutesAgo = DateTime.now().subtract(const Duration(minutes: 5, seconds: 2));
        manager.pausedAt = fiveMinutesAgo;

        // When returning to foreground, Flutter fires `inactive` before `resumed`
        manager.didChangeAppLifecycleState(AppLifecycleState.inactive);

        // pausedAt must NOT have been overwritten by inactive!
        expect(manager.pausedAt, equals(fiveMinutesAgo));
      },
    );

    test('Vault locks when background duration exceeds configured timeout (5 minutes)', () {
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});
      expect(QuickUnlockStorage.isSessionValid(), isTrue);
      expect(QuickUnlockStorage.hasSessionCredentials, isTrue);

      // Simulate 5 minutes and 5 seconds in background
      final elapsedTimestamp = DateTime.now().subtract(const Duration(minutes: 5, seconds: 5));
      manager.pausedAt = elapsedTimestamp;

      // Resuming app after timeout
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);

      // Session must be cleared due to auto-lock trigger
      expect(QuickUnlockStorage.isSessionValid(), isFalse);
      expect(QuickUnlockStorage.hasSessionCredentials, isFalse);
      expect(manager.pausedAt, isNull);
    });

    test('Vault remains unlocked when returning within configured timeout (< 5 minutes)', () {
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});
      expect(QuickUnlockStorage.isSessionValid(), isTrue);

      // Simulate 45 seconds in background
      final recentTimestamp = DateTime.now().subtract(const Duration(seconds: 45));
      manager.pausedAt = recentTimestamp;

      // Resuming app within timeout
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);

      // Session remains valid!
      expect(QuickUnlockStorage.isSessionValid(), isTrue);
      expect(QuickUnlockStorage.hasSessionCredentials, isTrue);
      expect(manager.pausedAt, isNull);
    });

    test('Immediate lock (0s) locks vault upon resumption regardless of duration', () {
      SecuritySettingsStore.instance.save(autoLockSeconds: 0);
      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});

      // App backgrounded 1 second ago
      manager.pausedAt = DateTime.now().subtract(const Duration(seconds: 1));

      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(QuickUnlockStorage.isSessionValid(), isFalse);
      expect(QuickUnlockStorage.hasSessionCredentials, isFalse);
    });

    test('Never lock (-1s) preserves session indefinitely upon resumption', () {
      SecuritySettingsStore.instance.save(autoLockSeconds: -1);
      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});

      // App backgrounded 2 hours ago
      manager.pausedAt = DateTime.now().subtract(const Duration(hours: 2));

      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(QuickUnlockStorage.isSessionValid(), isTrue);
      expect(QuickUnlockStorage.hasSessionCredentials, isTrue);
    });

    test('checkAutoLock() proactively enforces timeout before UI presents', () {
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});

      // Backgrounded 6 minutes ago
      manager.pausedAt = DateTime.now().subtract(const Duration(minutes: 6));

      final locked = manager.checkAutoLock();
      expect(locked, isTrue);
      expect(QuickUnlockStorage.isSessionValid(), isFalse);
      expect(manager.pausedAt, isNull);
    });

    test('Opening the app restarts timer from scratch for the next background period', () {
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});

      // 1. App backgrounded 2 minutes ago (within 5-min timeout)
      manager.pausedAt = DateTime.now().subtract(const Duration(minutes: 2));

      // 2. User opens the app
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);

      // Session remains valid, and pausedAt is cleared to null while app is open
      expect(QuickUnlockStorage.isSessionValid(), isTrue);
      expect(manager.pausedAt, isNull);

      // 3. User finishes and backgrounds the app again
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      final newPausedAt = manager.pausedAt;
      expect(newPausedAt, isNotNull);

      // The new pausedAt is fresh (around now, NOT 2 minutes ago)
      expect(DateTime.now().difference(newPausedAt!).inSeconds, lessThan(2));
    });

    test('Autofill activity during backgrounding restarts timer from scratch', () {
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});

      // App originally backgrounded 6 minutes ago
      manager.pausedAt = DateTime.now().subtract(const Duration(minutes: 6));

      // But an autofill activity occurred 1 minute ago!
      final autofillActivityTime = DateTime.now().subtract(const Duration(minutes: 1));

      // Evaluating timeout with the recent autofill activity timestamp
      final locked = manager.checkAutoLock(nativeActiveTime: autofillActivityTime);

      // Must NOT lock because autofill activity restarted the timer 1 minute ago (< 5 minutes)
      expect(locked, isFalse);
      expect(QuickUnlockStorage.isSessionValid(), isTrue);
    });

    test('Foreground inactivity exceeding timeout triggers auto-lock', () {
      SecuritySettingsStore.instance.save(autoLockSeconds: 300);
      QuickUnlockStorage.cacheSessionCredentials({dummySource: creds});

      // App is in foreground (pausedAt is null)
      manager.pausedAt = null;
      // Inactive for 6 minutes in foreground
      manager.lastInteractionAt = DateTime.now().subtract(const Duration(minutes: 6));

      // Trigger check
      manager.checkForegroundInactivityForTesting();

      // Session must be cleared due to auto-lock
      expect(QuickUnlockStorage.isSessionValid(), isFalse);
      expect(QuickUnlockStorage.hasSessionCredentials, isFalse);
    });
  });
}
