import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/l10n-generated/app_localizations_en.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/widgets/keynest_custom_field_sheet.dart';
import 'package:keynest/ui/widgets/keynest_totp_tile.dart';
import 'package:keynest/utils/entry_totp_helper.dart';

void main() {
  group('TOTP Immediate Detection & Updates', () {
    test(
      'Entry without TOTP returns false, immediately returns true after adding TOTP without caching stale false',
      () {
        final file = KdbxFormat().create(
          Credentials.composite(ProtectedValue.fromString('pass'), null),
          'test',
        );
        final entry = KdbxEntry.create(file, file.body.rootGroup);
        entry.setString(KdbxKeyCommon.TITLE, PlainValue('Test Login'));

        // Initially no TOTP
        expect(EntryTotpHelper.hasTotp(entry), isFalse);

        // Add TOTP field
        entry.setString(
          KdbxKeyCommon.OTP,
          ProtectedValue.fromString(
            'otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP',
          ),
        );
        EntryTotpHelper.invalidateCache(entry);

        // Must be immediately true without restart or navigation
        expect(EntryTotpHelper.hasTotp(entry), isTrue);
        final info = EntryTotpHelper.getTotpInfo(entry);
        expect(info, isNotNull);
        expect(info!.code.length, 6);
      },
    );

    test(
      'Updating TOTP secret produces updated live TOTP code immediately',
      () {
        final file = KdbxFormat().create(
          Credentials.composite(ProtectedValue.fromString('pass'), null),
          'test',
        );
        final entry = KdbxEntry.create(file, file.body.rootGroup);
        const secret1 = 'JBSWY3DPEHPK3PXP';
        const secret2 = 'GU4LSY3EI5ORJOXORU7LFYZR4HOWSBMD';

        final fixedTime = DateTime.utc(2026, 1, 1, 12, 0, 0);

        withClock(Clock(() => fixedTime), () {
          entry.setString(
            KdbxKeyCommon.OTP,
            ProtectedValue.fromString(secret1),
          );
          EntryTotpHelper.invalidateCache(entry);
          final code1 = EntryTotpHelper.getLiveTotpCode(entry);

          entry.setString(
            KdbxKeyCommon.OTP,
            ProtectedValue.fromString(secret2),
          );
          EntryTotpHelper.invalidateCache(entry);
          final code2 = EntryTotpHelper.getLiveTotpCode(entry);

          expect(code1, isNotNull);
          expect(code2, isNotNull);
          expect(code1, isNot(equals(code2)));
        });
      },
    );
  });

  group('Custom Field TOTP Rendering for Cards and Notes', () {
    testWidgets(
      'KeyNestTotpTile generates and displays live 6-digit TOTP code for Card/Note custom secret',
      (WidgetTester tester) async {
        final file = KdbxFormat().create(
          Credentials.composite(ProtectedValue.fromString('pass'), null),
          'test',
        );
        final entry = KdbxEntry.create(file, file.body.rootGroup);
        const customKey = 'Authe';
        const customSecret = 'GU4LSY3EI5ORJOXORU7LFYZR4HOWSBMD';

        entry.setString(
          KdbxKey(customKey),
          ProtectedValue.fromString(customSecret),
        );
        entry.customData['FieldType_$customKey'] = 'authenticator';

        final fixedTime = DateTime.utc(2026, 1, 1, 12, 0, 0);

        await withClock(Clock(() => fixedTime), () async {
          final expectedInfo = EntryTotpHelper.getTotpInfoForSecret(
            customSecret,
            entry: entry,
            timestampMs: fixedTime.millisecondsSinceEpoch,
          );
          expect(expectedInfo, isNotNull);
          final expectedCode = expectedInfo!.code;
          expect(expectedCode.length, 6);

          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: KeyNestTotpTile(
                  entry: entry,
                  secret: customSecret,
                  label: '$customKey (Authenticator (2FA))',
                  isMasked: false,
                ),
              ),
            ),
          );
          await tester.pump();

          // Must display the label as heading
          expect(find.text('$customKey (Authenticator (2FA))'), findsOneWidget);
          // Must display the 6-digit code, NOT the raw secret or the field key as code
          expect(find.text(expectedCode), findsOneWidget);
          expect(find.text(customSecret), findsNothing);
          // Must display timer countdown
          expect(find.textContaining('s'), findsOneWidget);
        });
      },
    );

    testWidgets(
      'Note entry with custom TOTP key shahjajs displays computed code in KeyNestTotpTile',
      (WidgetTester tester) async {
        final file = KdbxFormat().create(
          Credentials.composite(ProtectedValue.fromString('pass'), null),
          'test',
        );
        final entry = KdbxEntry.create(file, file.body.rootGroup);
        const customKey = 'shahjajsj';
        const customSecret = 'GU4LSY3EI5ORJOXORU7LFYZR4HOWSBMD';

        entry.setString(
          KdbxKey(customKey),
          ProtectedValue.fromString(customSecret),
        );
        entry.customData['FieldType_$customKey'] = 'authenticator';

        final fixedTime = DateTime.utc(2026, 1, 1, 12, 0, 0);

        await withClock(Clock(() => fixedTime), () async {
          final expectedInfo = EntryTotpHelper.getTotpInfoForSecret(
            customSecret,
            entry: entry,
            timestampMs: fixedTime.millisecondsSinceEpoch,
          );
          expect(expectedInfo, isNotNull);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: KeyNestTotpTile(
                  entry: entry,
                  secret: customSecret,
                  label: '$customKey (Authenticator (2FA))',
                  isMasked: false,
                ),
              ),
            ),
          );
          await tester.pump();

          expect(find.text('$customKey (Authenticator (2FA))'), findsOneWidget);
          expect(find.text(expectedInfo!.code), findsOneWidget);
          expect(find.text(customSecret), findsNothing);
        });
      },
    );
  });

  group('Optional Field and Custom Field Deletion', () {
    test(
      'Notes field showByDefault is false so optional notes do not reappear automatically',
      () {
        final commonFields = CommonFields(AppLocalizationsEn());
        expect(commonFields.notes.showByDefault, isFalse);
      },
    );

    test(
      'Deleting custom field removes it from entry and marks customData empty',
      () {
        final file = KdbxFormat().create(
          Credentials.composite(ProtectedValue.fromString('pass'), null),
          'test',
        );
        final entry = KdbxEntry.create(file, file.body.rootGroup);
        const key = 'CustomNote';
        entry.setString(KdbxKey(key), PlainValue('Some content'));
        entry.customData['FieldType_$key'] = 'text';

        expect(entry.getString(KdbxKey(key)), isNotNull);

        // Perform deletion
        entry.removeString(KdbxKey(key));
        entry.customData['FieldType_$key'] = '';

        expect(entry.getString(KdbxKey(key)), isNull);
        final kind = KeyNestCustomFieldSheet.resolveFieldKind(entry, key);
        expect(kind, equals(CustomFieldKind.text));
      },
    );

    test('Deleting optional Notes field leaves entry without Notes', () {
      final file = KdbxFormat().create(
        Credentials.composite(ProtectedValue.fromString('pass'), null),
        'test',
      );
      final entry = KdbxEntry.create(file, file.body.rootGroup);
      entry.setString(KdbxKey('Notes'), PlainValue('Optional note text'));
      expect(entry.getString(KdbxKey('Notes')), isNotNull);

      entry.removeString(KdbxKey('Notes'));
      expect(entry.getString(KdbxKey('Notes')), isNull);
    });
  });
}
