import 'package:autofill_service/autofill_service.dart';
import 'package:autofill_shared/credential_matcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/utils/entry_totp_helper.dart';

void main() {
  group('KeyNest Autofill Smart Credential Matcher', () {
    final matcher = CredentialMatcher.instance;

    test('exact host matches with highest quality', () {
      final req = [CredentialRequest.web('https://login.example.com/auth')];
      final urls = ['https://login.example.com'];

      final match = matcher.matchBest(req, urls);
      expect(match, CredentialMatchQuality.host);
    });

    test('registrable domain matches across subdomains', () {
      final req = [CredentialRequest.web('https://app.example.com')];
      final urls = ['https://auth.example.com'];

      final match = matcher.matchBest(req, urls);
      expect(match, CredentialMatchQuality.registrableDomain);
    });

    test(
      'associated application matches well-known Android packages to web domains',
      () {
        final req = [CredentialRequest.application('com.spotify.music')];
        final urls = ['https://spotify.com'];

        final match = matcher.matchBest(req, urls);
        expect(match, CredentialMatchQuality.associatedApplication);
      },
    );

    test('associated application matches github package to github.com', () {
      final req = [CredentialRequest.application('com.github.android')];
      final urls = ['https://github.com'];

      final match = matcher.matchBest(req, urls);
      expect(match, CredentialMatchQuality.associatedApplication);
    });

    test(
      'associated application matches twitter/x package to x.com and twitter.com',
      () {
        final req = [CredentialRequest.application('com.twitter.android')];
        final urls = ['https://twitter.com'];

        final match = matcher.matchBest(req, urls);
        expect(match, CredentialMatchQuality.associatedApplication);
      },
    );

    test('unsafe substring matches are rejected', () {
      final req = [CredentialRequest.web('https://notexample.com')];
      final urls = ['https://example.com'];

      final match = matcher.matchBest(req, urls);
      expect(match, isNull);
    });

    test('ranks exact host above associated application', () {
      final req = [
        CredentialRequest.application('com.spotify.music'),
        CredentialRequest.web('https://spotify.com'),
      ];

      final ranked = matcher.rank<List<String>>(
        req,
        [
          ['https://accounts.spotify.com'],
          ['https://spotify.com'],
        ],
        (item) => item,
      );

      expect(ranked.first, ['https://spotify.com']);
    });
  });

  group('EntryTotpHelper', () {
    test('extracts OTP from standard OTP field', () {
      final file = KdbxFormat().create(
        Credentials(ProtectedValue.fromString('password')),
        'Test Vault',
      );
      final entry = KdbxEntry.create(file, file.body.rootGroup);
      entry.setString(
        KdbxKeyCommon.OTP,
        ProtectedValue.fromString(
          'otpauth://totp/KeyNest:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=KeyNest',
        ),
      );

      expect(EntryTotpHelper.hasTotp(entry), isTrue);
      final code = EntryTotpHelper.getLiveTotpCode(entry);
      expect(code, isNotNull);
      expect(code!.length, 6);
    });

    test('extracts OTP from custom string fields', () {
      final file = KdbxFormat().create(
        Credentials(ProtectedValue.fromString('password')),
        'Test Vault',
      );
      final entry = KdbxEntry.create(file, file.body.rootGroup);
      entry.setString(
        KdbxKey('2FA'),
        PlainValue(
          'otpauth://totp/Example:bob?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ',
        ),
      );

      expect(EntryTotpHelper.hasTotp(entry), isTrue);
      final code = EntryTotpHelper.getLiveTotpCode(entry);
      expect(code, isNotNull);
      expect(code!.length, 6);
    });

    test('returns null when no TOTP is present', () {
      final file = KdbxFormat().create(
        Credentials(ProtectedValue.fromString('password')),
        'Test Vault',
      );
      final entry = KdbxEntry.create(file, file.body.rootGroup);
      expect(EntryTotpHelper.hasTotp(entry), isFalse);
      expect(EntryTotpHelper.getLiveTotpCode(entry), isNull);
    });
  });

  group('PendingSaveRequest Model', () {
    test('parses correctly from map', () {
      final req = PendingSaveRequest.fromMap({
        'username': 'alice@keynest.app',
        'password': 'super-secure-pass',
        'packageName': 'com.example.app',
        'webDomain': 'login.example.com',
      });

      expect(req.username, 'alice@keynest.app');
      expect(req.password, 'super-secure-pass');
      expect(req.packageName, 'com.example.app');
      expect(req.webDomain, 'login.example.com');
    });

    test('handles empty or missing map values safely', () {
      final req = PendingSaveRequest.fromMap({});
      expect(req.username, '');
      expect(req.password, '');
      expect(req.packageName, '');
      expect(req.webDomain, '');
    });
  });
}
