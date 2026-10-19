import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';

void main() {
  group('KeyNest Vault Compatibility & Cryptographic Round-Trip', () {
    test(
      'Create, encrypt, save, decrypt and verify all 5 entity types',
      () async {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('TestMasterPassword123!'),
          null,
        );
        final format = KdbxFormat();
        final file = format.create(credentials, 'KeyNest Test Vault');
        final root = file.body.rootGroup;

        // 1. Secrets Entry
        final secretEntry = KdbxEntry.create(file, root);
        root.addEntry(secretEntry);
        secretEntry.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Google Account'),
        );
        secretEntry.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('test@gmail.com'),
        );
        secretEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('SuperSecretPassword456!'),
        );
        secretEntry.setString(
          KdbxKeyCommon.URL,
          PlainValue('https://accounts.google.com'),
        );
        secretEntry.setString(KdbxKey('ItemCategory'), PlainValue('General'));
        secretEntry.setString(KdbxKey('is_favorite'), PlainValue('true'));

        // 2. Payment Card Entry
        final cardEntry = KdbxEntry.create(file, root);
        root.addEntry(cardEntry);
        cardEntry.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Alex Rivera Card'),
        );
        cardEntry.setString(KdbxKey('ItemCategory'), PlainValue('Card'));
        cardEntry.setString(KdbxKey('Cardholder'), PlainValue('Alex Rivera'));
        cardEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('4532 8901 2345 6789'),
        );
        cardEntry.setString(KdbxKey('Expiry'), PlainValue('08/28'));
        cardEntry.setString(
          KdbxKey('CVV'),
          ProtectedValue.fromString('742'),
        );
        cardEntry.setString(
          KdbxKey('PIN'),
          ProtectedValue.fromString('1234'),
        );
        cardEntry.setString(KdbxKey('Network'), PlainValue('Visa'));
        cardEntry.setString(KdbxKey('CardColorHex'), PlainValue('ff1e293b'));
        cardEntry.setString(KdbxKey('CardFinish'), PlainValue('matte'));

        // 3. Record Entry (Wi-Fi)
        final recordEntry = KdbxEntry.create(file, root);
        root.addEntry(recordEntry);
        recordEntry.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Home Studio Wi-Fi'),
        );
        recordEntry.setString(KdbxKey('ItemCategory'), PlainValue('Record'));
        recordEntry.setString(
          KdbxKey('RecordType'),
          PlainValue('Wi-Fi Password'),
        );
        recordEntry.setString(
          KdbxKey('Network Name (SSID)'),
          PlainValue('Studio_5G_Ultra'),
        );
        recordEntry.setString(
          KdbxKey('Password'),
          ProtectedValue.fromString('UltraSecureWifiKey998!'),
        );

        // 4. Secure Note Entry
        final noteEntry = KdbxEntry.create(file, root);
        root.addEntry(noteEntry);
        noteEntry.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Emergency Backup Codes'),
        );
        noteEntry.setString(KdbxKey('ItemCategory'), PlainValue('Note'));
        noteEntry.setString(
          KdbxKey('Notes'),
          ProtectedValue.fromString('1. 8923-4412\n2. 9931-0021\n3. 1120-7744'),
        );

        // 5. 2FA Entry
        final totpEntry = KdbxEntry.create(file, root);
        root.addEntry(totpEntry);
        totpEntry.setString(KdbxKeyCommon.TITLE, PlainValue('GitHub 2FA'));
        totpEntry.setString(KdbxKey('ItemCategory'), PlainValue('2FA'));
        totpEntry.setString(
          KdbxKey('OTPAuth'),
          PlainValue(
            'otpauth://totp/GitHub:user?secret=JBSWY3DPEHPK3PXP&issuer=GitHub',
          ),
        );

        // Save / Encrypt to KDBX binary format
        final vaultBytes = await file.save();
        expect(vaultBytes.length, greaterThan(100));

        // Reload / Decrypt from KDBX binary format
        final reloadedFile = await format.read(vaultBytes, credentials);
        final reloadedEntries = reloadedFile.body.rootGroup
            .getAllEntries()
            .toList();
        expect(reloadedEntries.length, 5);

        // Verify Secret
        final reloadedSecret = reloadedEntries.firstWhere(
          (e) =>
              e.getString(KdbxKeyCommon.TITLE)?.getText() == 'Google Account',
        );
        expect(
          reloadedSecret.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          'test@gmail.com',
        );
        final secretPass = reloadedSecret.getString(KdbxKeyCommon.PASSWORD);
        expect(secretPass is ProtectedValue, isTrue);
        expect(secretPass?.getText(), 'SuperSecretPassword456!');
        expect(
          reloadedSecret.getString(KdbxKey('is_favorite'))?.getText(),
          'true',
        );

        // Verify Card
        final reloadedCard = reloadedEntries.firstWhere(
          (e) =>
              e.getString(KdbxKeyCommon.TITLE)?.getText() == 'Alex Rivera Card',
        );
        expect(
          reloadedCard.getString(KdbxKey('Cardholder'))?.getText(),
          'Alex Rivera',
        );
        expect(
          reloadedCard.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          '4532 8901 2345 6789',
        );
        final cardCvv = reloadedCard.getString(KdbxKey('CVV'));
        expect(cardCvv is ProtectedValue, isTrue);
        expect(cardCvv?.getText(), '742');
        final cardPin = reloadedCard.getString(KdbxKey('PIN'));
        expect(cardPin is ProtectedValue, isTrue);
        expect(cardPin?.getText(), '1234');
        expect(reloadedCard.getString(KdbxKey('Network'))?.getText(), 'Visa');

        // Verify Record
        final reloadedRecord = reloadedEntries.firstWhere(
          (e) =>
              e.getString(KdbxKeyCommon.TITLE)?.getText() ==
              'Home Studio Wi-Fi',
        );
        expect(
          reloadedRecord.getString(KdbxKey('RecordType'))?.getText(),
          'Wi-Fi Password',
        );
        expect(
          reloadedRecord.getString(KdbxKey('Network Name (SSID)'))?.getText(),
          'Studio_5G_Ultra',
        );
        expect(
          reloadedRecord.getString(KdbxKey('Password'))?.getText(),
          'UltraSecureWifiKey998!',
        );

        // Verify Note
        final reloadedNote = reloadedEntries.firstWhere(
          (e) =>
              e.getString(KdbxKeyCommon.TITLE)?.getText() ==
              'Emergency Backup Codes',
        );
        expect(
          reloadedNote.getString(KdbxKey('Notes'))?.getText(),
          contains('8923-4412'),
        );

        // Verify 2FA
        final reloadedTotp = reloadedEntries.firstWhere(
          (e) => e.getString(KdbxKeyCommon.TITLE)?.getText() == 'GitHub 2FA',
        );
        expect(
          reloadedTotp.getString(KdbxKey('OTPAuth'))?.getText(),
          contains('JBSWY3DPEHPK3PXP'),
        );

        // Test Edit and Re-save cycle
        reloadedSecret.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('UpdatedPassword2026!'),
        );
        final reSavedBytes = await reloadedFile.save();
        final roundTripFile = await format.read(reSavedBytes, credentials);
        final finalSecret = roundTripFile.body.rootGroup
            .getAllEntries()
            .firstWhere(
              (e) =>
                  e.getString(KdbxKeyCommon.TITLE)?.getText() ==
                  'Google Account',
            );
        expect(
          finalSecret.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          'UpdatedPassword2026!',
        );
      },
    );
  });
}
