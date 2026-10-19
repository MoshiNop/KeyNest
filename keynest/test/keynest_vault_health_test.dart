import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/ui/screens/keynest_vault_health_screen.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'util/test_util.dart';
import 'util/test_util.mocks.dart';

KdbxEntry _createEntry(KdbxFile file, KdbxGroup group) {
  final entry = KdbxEntry.create(file, group);
  group.addEntry(entry);
  return entry;
}

void main() {
  group('KeyNestVaultHealthScanner Unit Tests', () {
    test('isCardExpired correctly parses and identifies expired cards', () {
      final fixedNow = DateTime(2026, 10, 15);

      // Expired dates relative to Oct 2026
      expect(
        KeyNestVaultHealthScanner.isCardExpired('05/20', now: fixedNow),
        isTrue,
      );
      expect(
        KeyNestVaultHealthScanner.isCardExpired('05/2020', now: fixedNow),
        isTrue,
      );
      expect(
        KeyNestVaultHealthScanner.isCardExpired('01/26', now: fixedNow),
        isTrue,
      );
      expect(
        KeyNestVaultHealthScanner.isCardExpired('09/26', now: fixedNow),
        isTrue,
      );
      expect(
        KeyNestVaultHealthScanner.isCardExpired('2020-05', now: fixedNow),
        isTrue,
      );
      expect(
        KeyNestVaultHealthScanner.isCardExpired('2026-09', now: fixedNow),
        isTrue,
      );

      // Valid future dates
      expect(
        KeyNestVaultHealthScanner.isCardExpired('10/26', now: fixedNow),
        isFalse,
      ); // Current month
      expect(
        KeyNestVaultHealthScanner.isCardExpired('11/26', now: fixedNow),
        isFalse,
      );
      expect(
        KeyNestVaultHealthScanner.isCardExpired('12/28', now: fixedNow),
        isFalse,
      );
      expect(
        KeyNestVaultHealthScanner.isCardExpired('12/2030', now: fixedNow),
        isFalse,
      );
      expect(
        KeyNestVaultHealthScanner.isCardExpired('2028-12', now: fixedNow),
        isFalse,
      );

      // Invalid or empty
      expect(
        KeyNestVaultHealthScanner.isCardExpired('', now: fixedNow),
        isFalse,
      );
      expect(
        KeyNestVaultHealthScanner.isCardExpired('invalid', now: fixedNow),
        isFalse,
      );
    });

    test(
      'scanVaultAsync on empty vault returns 100% score and 0 issues',
      () async {
        final credentials = Credentials(
          ProtectedValue.fromString('masterPass'),
        );
        final emptyFile = KdbxFormat().create(credentials, 'EmptyVault');

        final report = await KeyNestVaultHealthScanner.scanVaultAsync(
          emptyFile,
        );

        expect(report.totalEntries, 0);
        expect(report.totalIssues, 0);
        expect(report.healthScore, 100);
        expect(report.weakPasswords, isEmpty);
        expect(report.reusedPasswordClusters, isEmpty);
        expect(report.missing2FaEntries, isEmpty);
        expect(report.expiredCardEntries, isEmpty);
      },
    );

    test(
      'scanVaultAsync detects weak passwords, reused passwords, missing 2FA, and expired cards without caching secrets',
      () async {
        final credentials = Credentials(
          ProtectedValue.fromString('masterPass'),
        );
        final file = KdbxFormat().create(credentials, 'TestVault');
        final root = file.body.rootGroup;

        final testNow = DateTime(2026, 10, 15);

        // 1. Weak password login
        final entryWeak = _createEntry(file, root);
        entryWeak.setString(KdbxKeyCommon.TITLE, PlainValue('Weak Service'));
        entryWeak.setString(KdbxKeyCommon.USER_NAME, PlainValue('user1'));
        entryWeak.setString(KdbxKeyCommon.PASSWORD, PlainValue('123456'));
        KeyNestItemTypeHelper.setItemType(entryWeak, KeyNestItemType.login);

        // 2. Empty password login
        final entryEmpty = _createEntry(file, root);
        entryEmpty.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Empty Password Service'),
        );
        entryEmpty.setString(KdbxKeyCommon.USER_NAME, PlainValue('user2'));
        entryEmpty.setString(KdbxKeyCommon.PASSWORD, PlainValue(''));
        KeyNestItemTypeHelper.setItemType(entryEmpty, KeyNestItemType.login);

        // 3. Strong login with 2FA
        final entryStrong = _createEntry(file, root);
        entryStrong.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Strong Service'),
        );
        entryStrong.setString(KdbxKeyCommon.USER_NAME, PlainValue('user3'));
        entryStrong.setString(
          KdbxKeyCommon.PASSWORD,
          PlainValue('kX9#m\$L2!vP0@qW8*'),
        );
        entryStrong.setString(
          KdbxKey('OTPAuth'),
          PlainValue(
            'otpauth://totp/Test:user3?secret=JBSWY3DPEHPK3PXP&issuer=Test',
          ),
        );
        KeyNestItemTypeHelper.setItemType(entryStrong, KeyNestItemType.login);

        // 4 & 5. Reused passwords
        final reusedPass = 'SharedPassphrase2026!';
        final entryReuse1 = _createEntry(file, root);
        entryReuse1.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Reuse Service A'),
        );
        entryReuse1.setString(KdbxKeyCommon.USER_NAME, PlainValue('alice'));
        entryReuse1.setString(KdbxKeyCommon.PASSWORD, PlainValue(reusedPass));
        KeyNestItemTypeHelper.setItemType(entryReuse1, KeyNestItemType.login);

        final entryReuse2 = _createEntry(file, root);
        entryReuse2.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Reuse Service B'),
        );
        entryReuse2.setString(KdbxKeyCommon.USER_NAME, PlainValue('bob'));
        entryReuse2.setString(KdbxKeyCommon.PASSWORD, PlainValue(reusedPass));
        KeyNestItemTypeHelper.setItemType(entryReuse2, KeyNestItemType.login);

        // 6. Expired payment card
        final entryExpiredCard = _createEntry(file, root);
        entryExpiredCard.setString(KdbxKeyCommon.TITLE, PlainValue('Old Visa'));
        entryExpiredCard.setString(
          KdbxKey('Cardholder'),
          PlainValue('John Doe'),
        );
        entryExpiredCard.setString(KdbxKey('Expiry'), PlainValue('05/20'));
        KeyNestItemTypeHelper.setItemType(
          entryExpiredCard,
          KeyNestItemType.card,
        );

        // 7. Active valid payment card
        final entryValidCard = _createEntry(file, root);
        entryValidCard.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Active Mastercard'),
        );
        entryValidCard.setString(KdbxKey('Cardholder'), PlainValue('John Doe'));
        entryValidCard.setString(KdbxKey('Expiry'), PlainValue('12/35'));
        KeyNestItemTypeHelper.setItemType(entryValidCard, KeyNestItemType.card);

        final report = await KeyNestVaultHealthScanner.scanVaultAsync(
          file,
          currentTime: testNow,
        );

        expect(report.totalEntries, 7);
        expect(report.totalLogins, 5);
        expect(report.totalCards, 2);

        // Weak passwords: 2 (123456, empty)
        expect(report.weakPasswords.length, 2);
        expect(
          report.weakPasswords.any((w) => w.entry.uuid == entryWeak.uuid),
          isTrue,
        );
        expect(
          report.weakPasswords.any((w) => w.entry.uuid == entryEmpty.uuid),
          isTrue,
        );
        expect(
          report.weakPasswords.any((w) => w.entry.uuid == entryStrong.uuid),
          isFalse,
        );

        // Reused passwords: 1 cluster with 2 entries
        expect(report.reusedPasswordClusters.length, 1);
        expect(report.reusedPasswordClusters.first.count, 2);
        final reusedUuids = report.reusedPasswordClusters.first.entries
            .map((e) => e.uuid)
            .toSet();
        expect(reusedUuids.contains(entryReuse1.uuid), isTrue);
        expect(reusedUuids.contains(entryReuse2.uuid), isTrue);

        // Missing 2FA: 4 logins without 2FA (entryWeak, entryEmpty, entryReuse1, entryReuse2)
        // entryStrong has OTPAuth so it must not be in missing2FaEntries
        expect(report.missing2FaEntries.length, 4);
        expect(
          report.missing2FaEntries.any((e) => e.uuid == entryStrong.uuid),
          isFalse,
        );

        // Expired cards: 1
        expect(report.expiredCardEntries.length, 1);
        expect(
          report.expiredCardEntries.first.entry.uuid,
          entryExpiredCard.uuid,
        );
        expect(report.expiredCardEntries.first.expiryString, '05/20');

        // Health score penalized
        expect(report.healthScore, lessThan(100));

        // Security check: Verify report objects never cache or hold plaintext password strings
        final reportString = report.toString();
        expect(reportString.contains('123456'), isFalse);
        expect(reportString.contains(reusedPass), isFalse);
        expect(reportString.contains('kX9#m\$L2!vP0@qW8*'), isFalse);
        expect(reportString.contains('JBSWY3DPEHPK3PXP'), isFalse);
      },
    );
  });

  group('KeyNestVaultHealthScreen Widget Tests', () {
    late KdbxFile file;
    late MockKdbxBloc mockKdbxBloc;

    setUp(() {
      final credentials = Credentials(ProtectedValue.fromString('masterPass'));
      file = KdbxFormat().create(credentials, 'TestHealthVault');
      final root = file.body.rootGroup;

      final loginWeak = _createEntry(file, root);
      loginWeak.setString(KdbxKeyCommon.TITLE, PlainValue('GitHub Account'));
      loginWeak.setString(
        KdbxKeyCommon.USER_NAME,
        PlainValue('developer@test.com'),
      );
      loginWeak.setString(KdbxKeyCommon.PASSWORD, PlainValue('password123'));
      KeyNestItemTypeHelper.setItemType(loginWeak, KeyNestItemType.login);

      final cardExpired = _createEntry(file, root);
      cardExpired.setString(KdbxKeyCommon.TITLE, PlainValue('Work Visa'));
      cardExpired.setString(KdbxKey('Cardholder'), PlainValue('Alex Morgan'));
      cardExpired.setString(KdbxKey('Expiry'), PlainValue('01/21'));
      KeyNestItemTypeHelper.setItemType(cardExpired, KeyNestItemType.card);

      mockKdbxBloc = MockKdbxBloc();
      when(mockKdbxBloc.openedFilesKdbx).thenReturn([file]);
    });

    Widget createTestApp(Widget child) {
      return MultiProvider(
        providers: [
          Provider<KdbxBloc>.value(value: mockKdbxBloc),
          Provider<Analytics>.value(value: MockAnalytics()),
          Provider<Env>.value(value: TestEnv(EnvSecretsFake(''))),
          Provider<AppData>.value(value: AppData()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales:
              const [Locale('en')] + AppLocalizations.supportedLocales,
          home: child,
        ),
      );
    }

    testWidgets(
      'Renders vault health summary, cards, counts, and expands entries on tap',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          createTestApp(const KeyNestVaultHealthScreen()),
        );

        // Wait for initial async scan to complete
        await tester.pumpAndSettle();

        // Verify Screen Title
        expect(find.text('Vault Health Overview'), findsOneWidget);

        // Verify Category Headers exist
        expect(find.text('Weak Passwords'), findsOneWidget);
        expect(find.text('Reused Passwords'), findsOneWidget);
        expect(find.text('Missing Two-Factor (2FA)'), findsOneWidget);
        expect(find.text('Expired Payment Cards'), findsOneWidget);

        // Tap on Weak Passwords to expand its items
        await tester.tap(find.text('Weak Passwords'));
        await tester.pumpAndSettle();

        // Verify the weak entry is revealed
        expect(find.text('GitHub Account'), findsOneWidget);
        expect(find.text('developer@test.com'), findsOneWidget);

        // Tap on Expired Payment Cards to expand its items
        await tester.tap(find.text('Expired Payment Cards'));
        await tester.pumpAndSettle();

        // Verify the expired card is revealed
        expect(find.text('Work Visa'), findsOneWidget);
        expect(find.textContaining('Exp: 01/21'), findsOneWidget);
      },
    );
  });
}
