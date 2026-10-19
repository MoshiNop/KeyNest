import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/utils/duplicate_detector.dart';

void main() {
  group('KeyNestDuplicateDetector Tests', () {
    test('normalizeUrl strips protocols, www, query params, and paths', () {
      expect(
        KeyNestDuplicateDetector.normalizeUrl(
          'https://www.github.com/login?ref=home',
        ),
        'github.com',
      );
      expect(
        KeyNestDuplicateDetector.normalizeUrl('http://keynest.app/'),
        'keynest.app',
      );
      expect(
        KeyNestDuplicateDetector.normalizeUrl('subdomain.example.com/path'),
        'subdomain.example.com',
      );
      expect(KeyNestDuplicateDetector.normalizeUrl(''), '');
      expect(KeyNestDuplicateDetector.normalizeUrl(null), '');
    });

    test(
      'findMatchesForCredential detects exact match and same credentials',
      () {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('Password123!'),
          null,
        );
        final file = KdbxFormat().create(credentials, 'Test Vault');
        final root = file.body.rootGroup;

        final entry1 = KdbxEntry.create(file, root);
        root.addEntry(entry1);
        entry1.setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'));
        entry1.setString(KdbxKeyCommon.USER_NAME, PlainValue('octocat'));
        entry1.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('Secret123!'),
        );
        entry1.setString(
          KdbxKeyCommon.URL,
          PlainValue('https://github.com/login'),
        );

        // 1. Exact match search
        final exactMatches = KeyNestDuplicateDetector.findMatchesForCredential(
          file: file,
          title: 'GitHub',
          username: 'octocat',
          url: 'https://www.github.com',
          password: 'Secret123!',
        );
        expect(exactMatches.length, 1);
        expect(exactMatches.first.matchType, DuplicateMatchType.exactMatch);

        // 2. Different password yields no match under complete duplicate rule
        final differentPasswordMatches =
            KeyNestDuplicateDetector.findMatchesForCredential(
              file: file,
              title: 'GitHub Work',
              username: 'octocat',
              url: 'https://github.com',
              password: 'DifferentPassword',
            );
        expect(differentPasswordMatches.isEmpty, isTrue);

        // 3. Different website and username yields no match
        final noMatches = KeyNestDuplicateDetector.findMatchesForCredential(
          file: file,
          title: 'GitLab',
          username: 'gitlabuser',
          url: 'https://gitlab.com',
        );
        expect(noMatches.isEmpty, isTrue);
      },
    );

    test(
      'findDuplicatesInVault identifies duplicate clusters and ignores trash',
      () {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('Password123!'),
          null,
        );
        final file = KdbxFormat().create(credentials, 'Test Vault');
        final root = file.body.rootGroup;

        // Primary entry
        final e1 = KdbxEntry.create(file, root);
        root.addEntry(e1);
        e1.setString(KdbxKeyCommon.TITLE, PlainValue('Netflix'));
        e1.setString(KdbxKeyCommon.USER_NAME, PlainValue('user@example.com'));
        e1.setString(KdbxKeyCommon.URL, PlainValue('netflix.com'));

        // Complete duplicate entry (all fields match)
        final e2 = KdbxEntry.create(file, root);
        root.addEntry(e2);
        e2.setString(KdbxKeyCommon.TITLE, PlainValue('Netflix'));
        e2.setString(KdbxKeyCommon.USER_NAME, PlainValue('user@example.com'));
        e2.setString(KdbxKeyCommon.URL, PlainValue('netflix.com'));

        // Unique entry (different service)
        final e3 = KdbxEntry.create(file, root);
        root.addEntry(e3);
        e3.setString(KdbxKeyCommon.TITLE, PlainValue('Spotify'));
        e3.setString(KdbxKeyCommon.USER_NAME, PlainValue('user@example.com'));
        e3.setString(KdbxKeyCommon.URL, PlainValue('spotify.com'));

        // Entry sharing only username/email must NOT be considered duplicate
        final e4 = KdbxEntry.create(file, root);
        root.addEntry(e4);
        e4.setString(KdbxKeyCommon.TITLE, PlainValue('Netflix Account'));
        e4.setString(KdbxKeyCommon.USER_NAME, PlainValue('user@example.com'));
        e4.setString(
          KdbxKeyCommon.URL,
          PlainValue('https://www.netflix.com/login'),
        );

        final clusters = KeyNestDuplicateDetector.findDuplicatesInVault(file);
        expect(clusters.length, 1);
        expect(clusters.first.primaryEntry.uuid, e1.uuid);
        expect(clusters.first.duplicates.length, 1);
        expect(clusters.first.duplicates.first.uuid, e2.uuid);
      },
    );

    test(
      'ignores system metadata (is_favorite, ItemCategory, FieldType) when matching duplicates',
      () {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('Password123!'),
          null,
        );
        final file = KdbxFormat().create(credentials, 'Test Vault');
        final root = file.body.rootGroup;

        final e1 = KdbxEntry.create(file, root);
        root.addEntry(e1);
        e1.setString(KdbxKeyCommon.TITLE, PlainValue('AWS Console'));
        e1.setString(KdbxKeyCommon.USER_NAME, PlainValue('admin@aws.com'));
        e1.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('P@ssword1!'),
        );
        e1.setString(KdbxKey('is_favorite'), PlainValue('true'));
        e1.setString(KdbxKey('ItemCategory'), PlainValue('Login'));

        final e2 = KdbxEntry.create(file, root);
        root.addEntry(e2);
        e2.setString(KdbxKeyCommon.TITLE, PlainValue('AWS Console - Copy'));
        e2.setString(KdbxKeyCommon.USER_NAME, PlainValue('admin@aws.com'));
        e2.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('P@ssword1!'),
        );
        // e2 is not favorited, and has different FieldType metadata
        e2.customData['FieldType_Pin'] = 'pin';

        expect(KeyNestDuplicateDetector.areCompleteDuplicates(e1, e2), isTrue);
      },
    );

    test(
      'distinguishes entries that merely share a title with different credentials or content',
      () {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('Password123!'),
          null,
        );
        final file = KdbxFormat().create(credentials, 'Test Vault');
        final root = file.body.rootGroup;

        // Two login entries with same title but different passwords
        final login1 = KdbxEntry.create(file, root);
        root.addEntry(login1);
        login1.setString(KdbxKeyCommon.TITLE, PlainValue('Google'));
        login1.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('alice@gmail.com'),
        );
        login1.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('PassA'),
        );

        final login2 = KdbxEntry.create(file, root);
        root.addEntry(login2);
        login2.setString(KdbxKeyCommon.TITLE, PlainValue('Google'));
        login2.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('alice@gmail.com'),
        );
        login2.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('PassB'),
        );

        expect(
          KeyNestDuplicateDetector.areCompleteDuplicates(login1, login2),
          isFalse,
        );

        // Two note entries with same title but different body
        final note1 = KdbxEntry.create(file, root);
        root.addEntry(note1);
        note1.setString(KdbxKeyCommon.TITLE, PlainValue('Meeting Notes'));
        note1.setString(KdbxKey('ItemCategory'), PlainValue('Note'));
        note1.setString(KdbxKey('Notes'), PlainValue('Q3 Goals'));

        final note2 = KdbxEntry.create(file, root);
        root.addEntry(note2);
        note2.setString(KdbxKeyCommon.TITLE, PlainValue('Meeting Notes'));
        note2.setString(KdbxKey('ItemCategory'), PlainValue('Note'));
        note2.setString(KdbxKey('Notes'), PlainValue('Sprint Retrospective'));

        expect(
          KeyNestDuplicateDetector.areCompleteDuplicates(note1, note2),
          isFalse,
        );
      },
    );

    test(
      'detects Note duplicates with CRLF vs LF line ending normalization',
      () {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('Password123!'),
          null,
        );
        final file = KdbxFormat().create(credentials, 'Test Vault');
        final root = file.body.rootGroup;

        final n1 = KdbxEntry.create(file, root);
        root.addEntry(n1);
        n1.setString(KdbxKeyCommon.TITLE, PlainValue('Server Instructions'));
        n1.setString(KdbxKey('ItemCategory'), PlainValue('Note'));
        n1.setString(
          KdbxKey('Notes'),
          PlainValue('Line 1\r\nLine 2\r\nLine 3'),
        );

        final n2 = KdbxEntry.create(file, root);
        root.addEntry(n2);
        n2.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Server Instructions (Copy)'),
        );
        n2.setString(KdbxKey('ItemCategory'), PlainValue('Note'));
        n2.setString(KdbxKey('Notes'), PlainValue('Line 1\nLine 2\nLine 3'));

        expect(KeyNestDuplicateDetector.areCompleteDuplicates(n1, n2), isTrue);
      },
    );

    test('detects Card duplicates with space and dash normalization', () {
      final credentials = Credentials.composite(
        ProtectedValue.fromString('Password123!'),
        null,
      );
      final file = KdbxFormat().create(credentials, 'Test Vault');
      final root = file.body.rootGroup;

      final c1 = KdbxEntry.create(file, root);
      root.addEntry(c1);
      c1.setString(KdbxKeyCommon.TITLE, PlainValue('Visa Platinum'));
      c1.setString(KdbxKey('ItemCategory'), PlainValue('Card'));
      c1.setString(KdbxKey('CardNumber'), PlainValue('4532 1234 5678 9010'));
      c1.setString(KdbxKey('Cardholder'), PlainValue('Alice Smith'));

      final c2 = KdbxEntry.create(file, root);
      root.addEntry(c2);
      c2.setString(KdbxKeyCommon.TITLE, PlainValue('Visa Platinum - Copy'));
      c2.setString(KdbxKey('ItemCategory'), PlainValue('Card'));
      c2.setString(KdbxKey('CardNumber'), PlainValue('4532-1234-5678-9010'));
      c2.setString(KdbxKey('Cardholder'), PlainValue('alice smith'));

      expect(KeyNestDuplicateDetector.areCompleteDuplicates(c1, c2), isTrue);
    });

    test(
      'detects 2FA duplicates with whitespace and casing normalization in TOTP secret',
      () {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('Password123!'),
          null,
        );
        final file = KdbxFormat().create(credentials, 'Test Vault');
        final root = file.body.rootGroup;

        final t1 = KdbxEntry.create(file, root);
        root.addEntry(t1);
        t1.setString(KdbxKeyCommon.TITLE, PlainValue('GitHub'));
        t1.setString(KdbxKey('ItemCategory'), PlainValue('2FA'));
        t1.setString(
          KdbxKey('OTPAuth'),
          PlainValue('otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP'),
        );

        final t2 = KdbxEntry.create(file, root);
        root.addEntry(t2);
        t2.setString(KdbxKeyCommon.TITLE, PlainValue('GitHub (Copy)'));
        t2.setString(KdbxKey('ItemCategory'), PlainValue('2FA'));
        t2.setString(
          KdbxKey('OTPAuth'),
          PlainValue(
            'otpauth://totp/GitHub:alice?secret=jbsw%20y3dp%20ehpk%203pxp',
          ),
        );

        expect(KeyNestDuplicateDetector.areCompleteDuplicates(t1, t2), isTrue);
      },
    );
  });
}
