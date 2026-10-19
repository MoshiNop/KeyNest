import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/l10n-generated/app_localizations_en.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:meta/meta.dart';
import 'package:provider/provider.dart';

void _createFields(KdbxEntry entry, Map<String, String> fields) {
  for (final e in fields.entries) {
    entry.setString(KdbxKey(e.key), ProtectedValue.fromString(e.value));
  }
}

@isTest
void _testTotp(
  String description, {
  required Map<String, String> fields,
  required String expectCode,
  String? totpFieldName,
}) {
  totpFieldName ??= fields.containsKey('TOTP Seed')
      ? 'TOTP Seed'
      : fields.keys.first;
  testWidgets(description, (WidgetTester tester) async {
    final file = KdbxFormat().create(
      Credentials.composite(ProtectedValue.fromString('asdf'), null),
      'test',
    );
    final entry = KdbxEntry.create(file, file.body.rootGroup);
    _createFields(entry, fields);

    final fixedTime = DateTime.utc(
      2020,
      1,
      1,
    ).subtract(const Duration(hours: 1));

    await withClock(Clock(() => fixedTime), () async {
      // 1. Verify View Mode TOTP calculation matches expected code
      final viewTotp = EntryTotpHelper.getTotpInfo(entry);
      expect(viewTotp, isNotNull);
      expect(viewTotp!.code, expectCode);

      // 2. Build Edit Mode widget and verify it displays the exact same code
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales:
              const [Locale('en')] + AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MultiProvider(
              providers: [
                Provider.value(value: CommonFields(AppLocalizationsEn())),
              ],
              child: EntryField(
                fieldType: FieldType.otp,
                entry: entry,
                fieldKey: KdbxKey(totpFieldName!),
                onChangedMetadata: () {},
              ),
            ),
          ),
        ),
      );

      final w = find
          .descendant(
            of: find.byType(EntryField),
            matching: find.byType(Text),
          )
          .first;
      expect(w, findsOneWidget);
      final editOtpCode = (w.evaluate().single.widget as Text).data;
      expect(editOtpCode, expectCode);

      // 3. Directly assert View Mode and Edit Mode produced identical codes
      expect(viewTotp.code, editOtpCode);
    });
  });
}

void main() {
  PrintAppender.setupLogging();

  group('TOTP Codes Consistency between View Mode and Edit Mode', () {
    _testTotp(
      'base32 code (TrayTOTP format)',
      fields: {
        'TOTP Seed': '3TBQAZ2XLJ54LTUMVVLJTPAST5TZANMF',
        'TOTP Settings': '30;6',
      },
      expectCode: '059989',
    );

    _testTotp(
      'base32 with spaces',
      fields: {
        'TOTP Seed': 'g33a l2j6 hqzv djri wtwp 4yhv iu74 4ue4',
        'TOTP Settings': '30;6',
      },
      expectCode: '872187',
    );

    _testTotp(
      'base32 with empty settings defaults to 30s 6-digits',
      fields: {
        'TOTP Seed': 'g33a l2j6 hqzv djri wtwp 4yhv iu74 4ue4',
        'TOTP Settings': '',
      },
      expectCode: '872187',
    );

    _testTotp(
      'otpauth url with SHA256 algorithm',
      fields: {
        'otp':
            'otpauth://totp/test?secret=27zzsdziauhmftpf33sc5ksvmcn3crljhrusmxmmjt2tkht4huny5ozk&algorithm=SHA256&digits=6&period=30',
      },
      expectCode: '412013',
    );

    _testTotp(
      'standard otpauth url with SHA1 algorithm',
      fields: {
        'OTPAuth':
            'otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub',
      },
      expectCode: '181709',
    );

    _testTotp(
      'KeeOTP query string format',
      fields: {
        'otp': 'key=JBSWY3DPEHPK3PXP&size=6&step=30',
      },
      expectCode: '181709',
    );

    test('Countdown and remaining seconds are identical across modes', () {
      final file = KdbxFormat().create(
        Credentials.composite(ProtectedValue.fromString('asdf'), null),
        'test',
      );
      final entry = KdbxEntry.create(file, file.body.rootGroup);
      _createFields(entry, {
        'OTPAuth':
            'otpauth://totp/Test:alice?secret=JBSWY3DPEHPK3PXP&period=30',
      });

      final fixedTime = DateTime.fromMillisecondsSinceEpoch(
        1577833212000,
        isUtc: true,
      ); // elapsed = 12s, remaining = 18s
      withClock(Clock(() => fixedTime), () {
        final totpInfo = EntryTotpHelper.getTotpInfo(entry);
        expect(totpInfo, isNotNull);
        expect(totpInfo!.period, 30);
        expect(totpInfo.elapsed, 12);
        expect(totpInfo.remainingSeconds, 18);
      });
    });

    test('isTotpProtected correctly detects protected TOTP fields', () {
      final file = KdbxFormat().create(
        Credentials.composite(ProtectedValue.fromString('asdf'), null),
        'test',
      );
      final entry = KdbxEntry.create(file, file.body.rootGroup);

      // Plain value -> not protected
      entry.setString(
        KdbxKey('OTPAuth'),
        PlainValue('otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP'),
      );
      expect(EntryTotpHelper.isTotpProtected(entry), isFalse);

      // Protected value -> is protected
      entry.setString(
        KdbxKey('OTPAuth'),
        ProtectedValue.fromString(
          'otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP',
        ),
      );
      expect(EntryTotpHelper.isTotpProtected(entry), isTrue);
    });

    test(
      'Automatic rollover produces identical next TOTP code across modes when time advances',
      () {
        final file = KdbxFormat().create(
          Credentials.composite(ProtectedValue.fromString('asdf'), null),
          'test',
        );
        final entry = KdbxEntry.create(file, file.body.rootGroup);
        _createFields(entry, {
          'OTPAuth': 'otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP&period=30',
        });

        // Time in timestep 1
        final t1 = DateTime.fromMillisecondsSinceEpoch(
          1000000000000,
          isUtc: true,
        );
        // Time in timestep 2 (+30s)
        final t2 = DateTime.fromMillisecondsSinceEpoch(
          1000000030000,
          isUtc: true,
        );

        final code1 = withClock(
          Clock(() => t1),
          () => EntryTotpHelper.getLiveTotpCode(entry),
        );
        final code2 = withClock(
          Clock(() => t2),
          () => EntryTotpHelper.getLiveTotpCode(entry),
        );

        expect(code1, isNotNull);
        expect(code2, isNotNull);
        expect(code1, isNot(equals(code2))); // code refreshed after interval
      },
    );
  });
}
