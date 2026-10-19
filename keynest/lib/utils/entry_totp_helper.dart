import 'package:clock/clock.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/utils/base32utils.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:keynest/utils/otpauth.dart';
import 'package:keynest/utils/totp_parser.dart';
import 'package:logging/logging.dart';
import 'package:otp/otp.dart';

final _logger = Logger('entry_totp_helper');

/// Structured representation of calculated TOTP values and configuration.
class EntryTotpInfo {
  const EntryTotpInfo({
    required this.code,
    required this.remainingSeconds,
    required this.period,
    required this.elapsed,
    required this.otpAuth,
  });

  final String code;
  final int remainingSeconds;
  final int period;
  final int elapsed;
  final OtpAuth otpAuth;
}

/// Utility to safely extract, parse, and generate live TOTP codes from a [KdbxEntry].
class EntryTotpHelper {
  /// Returns the current live TOTP code for the entry, or null if no TOTP secret is configured.
  static String? getLiveTotpCode(KdbxEntry entry, {int? timestampMs}) {
    return getTotpInfo(entry, timestampMs: timestampMs)?.code;
  }

  /// Calculates the TOTP code and countdown info for [entry] at the given timestamp (or now).
  static EntryTotpInfo? getTotpInfo(KdbxEntry entry, {int? timestampMs}) {
    try {
      final otpAuth = getOtpAuth(entry);
      if (otpAuth == null) {
        return null;
      }
      final now = timestampMs ?? clock.now().millisecondsSinceEpoch;
      final secretBase32 = base32Encode(otpAuth.secret);
      final code = OTP.generateTOTPCodeString(
        secretBase32,
        now,
        algorithm: otpAuth.algorithm,
        interval: otpAuth.period,
        length: otpAuth.digits,
        isGoogle: true,
      );
      final period = otpAuth.period;
      final elapsed = (now ~/ 1000) % period;
      final remaining = period - elapsed;
      return EntryTotpInfo(
        code: code,
        remainingSeconds: remaining,
        period: period,
        elapsed: elapsed,
        otpAuth: otpAuth,
      );
    } catch (e, stack) {
      _logger.warning('Failed to generate live TOTP info', e, stack);
      return null;
    }
  }

  /// Checks whether this entry has a TOTP secret configured.
  static bool hasTotp(KdbxEntry entry) {
    return getOtpAuth(entry) != null;
  }

  /// Determines if the field providing the TOTP secret is stored as a [ProtectedValue].
  static bool isTotpProtected(KdbxEntry entry) {
    for (final keyName in [
      'OTPAuth',
      'otp',
      'totp',
      'TOTP Seed',
      '2fa',
      'hmacseed',
    ]) {
      final val = entry.getString(KdbxKey(keyName));
      if (val is ProtectedValue && val.getText().trim().isNotEmpty) {
        return true;
      }
    }
    for (final stringEntry in entry.stringEntries) {
      final rawKey = stringEntry.key.key;
      final key = rawKey.toLowerCase();
      final kind = entry.customData['FieldType_$rawKey']?.trim().toLowerCase();
      if (kind == 'authenticator' ||
          key.contains('otp') ||
          key.contains('totp') ||
          key.contains('2fa') ||
          key.contains('authenticator')) {
        final text = stringEntry.value?.getText();
        if (stringEntry.value is ProtectedValue &&
            text != null &&
            text.trim().isNotEmpty) {
          return true;
        }
      }
    }
    return false;
  }

  /// Parses an [OtpAuth] configuration from the entry's fields or notes across all entry types.
  static OtpAuth? getOtpAuth(KdbxEntry entry) {
    // 1. Check standard OTP field (KdbxKeyCommon.OTP / OTPAuth)
    final otpValue = entry.getString(KdbxKeyCommon.OTP)?.getText()?.trim();
    if (otpValue != null && otpValue.isNotEmpty) {
      final parsed = parseOtpAuth(otpValue, entry: entry);
      if (parsed != null) {
        return parsed;
      }
    }

    // 2. Check standard alternate keys
    final standardKeys = [
      KdbxKey('otp'),
      KdbxKey('totp'),
      KdbxKey('TOTP Seed'),
      KdbxKey('2fa'),
      KdbxKey('OTPAuth'),
      KdbxKey('hmacseed'),
    ];
    for (final k in standardKeys) {
      final val = entry.getString(k)?.getText()?.trim();
      if (val != null && val.isNotEmpty) {
        final parsed = parseOtpAuth(val, entry: entry);
        if (parsed != null) {
          return parsed;
        }
      }
    }

    // 3. Check custom fields commonly used for OTP, authenticator custom fields, or otpauth:// URIs
    for (final stringEntry in entry.stringEntries) {
      final rawKey = stringEntry.key.key;
      final key = rawKey.trim().toLowerCase();
      final kind = entry.customData['FieldType_$rawKey']?.trim().toLowerCase();
      final isAuthKind = kind == 'authenticator';
      final isAuthKey =
          key == 'otp' ||
          key == 'totp' ||
          key == 'otpauth' ||
          key == '2fa' ||
          key == 'totp seed' ||
          key == 'hmacseed' ||
          key.contains('authenticator') ||
          key.contains('2fa') ||
          key.contains('totp') ||
          key.contains('otp');

      final val = stringEntry.value?.getText()?.trim();
      if (val != null && val.isNotEmpty) {
        if (isAuthKind ||
            isAuthKey ||
            val.toLowerCase().startsWith('otpauth://')) {
          final parsed = parseOtpAuth(val, entry: entry);
          if (parsed != null) {
            return parsed;
          }
        }
      }
    }

    // 4. Check notes for embedded otpauth:// URI
    final notes = entry.getString(KdbxKey('Notes'))?.getText()?.trim();
    if (notes != null && notes.isNotEmpty) {
      for (final line in notes.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.toLowerCase().startsWith('otpauth://')) {
          final parsed = parseOtpAuth(trimmed, entry: entry);
          if (parsed != null) {
            return parsed;
          }
        }
      }
    }

    return null;
  }

  /// Parses raw OTP data into an [OtpAuth] object.
  /// Supports:
  /// - `otpauth://` URIs
  /// - KeeOTP query strings (`key=...`)
  /// - KeePass TrayTOTP (`TOTP Seed` + `TOTP Settings`)
  /// - Raw Base32 secrets
  static OtpAuth? parseOtpAuth(String raw, {KdbxEntry? entry}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    try {
      // 1. otpauth:// URI
      if (trimmed.toLowerCase().startsWith('otpauth://')) {
        final uri = Uri.tryParse(trimmed);
        if (uri != null) {
          final p = uri.queryParameters;
          var rawSecret = p['secret'] ?? '';
          if (rawSecret.isEmpty) {
            for (final e in p.entries) {
              if (e.key.toLowerCase() == 'secret') {
                rawSecret = e.value;
                break;
              }
            }
          }
          if (rawSecret.isNotEmpty) {
            final binarySecret = base32Decode(rawSecret);
            if (binarySecret.isNotEmpty) {
              final rawAlgo = p['algorithm']?.toUpperCase();
              final algo =
                  OtpAuth.algorithmForString(rawAlgo) ??
                  OtpAuth.DEFAULT_ALGORITHM;
              final rawDigits = int.tryParse(p['digits'] ?? '');
              final digits =
                  (rawDigits != null && rawDigits >= 4 && rawDigits <= 10)
                  ? rawDigits
                  : OtpAuth.DEFAULT_DIGITS;
              final rawPeriod = int.tryParse(p['period'] ?? '');
              final period = (rawPeriod != null && rawPeriod > 0)
                  ? rawPeriod
                  : OtpAuth.DEFAULT_PERIOD;
              final label = uri.pathSegments.isNotEmpty
                  ? uri.pathSegments.first
                  : '';
              return OtpAuth(
                label: label,
                secret: binarySecret,
                algorithm: algo,
                digits: digits,
                period: period,
              );
            }
          }
        }
      }

      // 2. Check KeeOTP query string format (e.g. key=...&size=6&step=30)
      if (trimmed.contains('key=')) {
        final data = Uri.splitQueryString(trimmed);
        final rawKey = data['key'];
        if (rawKey != null && rawKey.trim().isNotEmpty) {
          final binarySecret = base32Decode(rawKey);
          if (binarySecret.isNotEmpty) {
            final p = int.tryParse(data['step'] ?? '');
            final period = (p != null && p > 0) ? p : OtpAuth.DEFAULT_PERIOD;
            final d = int.tryParse(data['size'] ?? '');
            final digits = (d != null && d >= 4 && d <= 10)
                ? d
                : OtpAuth.DEFAULT_DIGITS;
            return OtpAuth(
              secret: binarySecret,
              period: period,
              digits: digits,
            );
          }
        }
      }

      // 3. Check TrayTOTP format / Base32 secret with possible settings
      try {
        final binarySecret = base32Decode(trimmed);
        if (binarySecret.isNotEmpty) {
          int period = OtpAuth.DEFAULT_PERIOD;
          int digits = OtpAuth.DEFAULT_DIGITS;

          final settings =
              entry?.getString(KdbxKey('TOTP Settings'))?.getText()?.trim() ??
              '';
          if (settings.isNotEmpty) {
            final settingsOptions = settings.split(';');
            final p = settingsOptions.optGet(0)?.toInt();
            if (p != null && p > 0) {
              period = p;
            }
            final d = settingsOptions.optGet(1)?.toInt();
            if (d != null && d >= 4 && d <= 10) {
              digits = d;
            }
          }

          return OtpAuth(
            secret: binarySecret,
            period: period,
            digits: digits,
          );
        }
      } on FormatException {
        // Not valid raw base32, continue to TotpQrData fallback
      }

      // 4. Check TotpQrData parser fallback (preserving algorithm, digits, period)
      final parsed = TotpQrData.parse(trimmed);
      if (parsed != null) {
        final algo =
            OtpAuth.algorithmForString(parsed.algorithm) ??
            OtpAuth.DEFAULT_ALGORITHM;
        return OtpAuth(
          label: parsed.accountName ?? parsed.title,
          secret: base32Decode(parsed.secret),
          algorithm: algo,
          digits: parsed.digits,
          period: parsed.period,
        );
      }
    } catch (e) {
      _logger.fine('Unable to parse raw OTP string: $e');
    }
    return null;
  }
}
