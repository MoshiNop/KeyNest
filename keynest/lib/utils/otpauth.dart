import 'dart:typed_data';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:keynest/utils/base32utils.dart';
import 'package:keynest/utils/constants.dart';
import 'package:logging/logging.dart';
import 'package:otp/otp.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('otpauth');

/// loosely based on format from
/// https://github.com/google/google-authenticator/wiki/Key-Uri-Format
class OtpAuth {
  const OtpAuth({
    required this.secret,
    this.algorithm = DEFAULT_ALGORITHM,
    this.digits = DEFAULT_DIGITS,
    this.period = DEFAULT_PERIOD,
    this.label = CharConstants.empty,
  });

  factory OtpAuth.fromUri(Uri uri) {
    final p = uri.queryParameters;
    var rawSecret = p[PARAM_SECRET] ?? '';
    if (rawSecret.isEmpty) {
      for (final e in p.entries) {
        if (e.key.toLowerCase() == PARAM_SECRET) {
          rawSecret = e.value;
          break;
        }
      }
    }

    final rawAlgo = p[PARAM_ALGORITHM]?.toUpperCase();
    final rawDigits = int.tryParse(p[PARAM_DIGITS] ?? '');
    final rawPeriod = int.tryParse(p[PARAM_PERIOD] ?? '');

    return OtpAuth(
      label: uri.pathSegments.isNotEmpty
          ? uri.pathSegments.first
          : CharConstants.empty,
      secret: base32Decode(rawSecret),
      algorithm: algorithmForString(rawAlgo) ?? DEFAULT_ALGORITHM,
      digits: (rawDigits != null && rawDigits >= 4 && rawDigits <= 10)
          ? rawDigits
          : DEFAULT_DIGITS,
      period: (rawPeriod != null && rawPeriod > 0) ? rawPeriod : DEFAULT_PERIOD,
    );
  }

  @NonNls
  static OtpAuth? fromQueryString(String value) {
    if (value.contains('key=')) {
      _logger.finer('value contains "key=": $value');
      // KeeOTP format:key={base32Key}&size=12&step=33&type=Totp&counter=3
      final data = Uri.splitQueryString(value);
      try {
        final rawKey = data['key'];
        if (rawKey == null || rawKey.isEmpty) {
          return null;
        }
        final p = int.tryParse(data['step'] ?? '');
        final d = int.tryParse(data['size'] ?? '');
        return OtpAuth(
          secret: base32Decode(rawKey),
          period: (p != null && p > 0) ? p : OtpAuth.DEFAULT_PERIOD,
          digits: (d != null && d >= 4 && d <= 10) ? d : OtpAuth.DEFAULT_DIGITS,
        );
      } on FormatException catch (e, stackTrace) {
        _logger.fine('Error parsing $data', e, stackTrace);
        rethrow;
      }
    }
    return null;
  }

  @NonNls
  static const SCHEME = 'otpauth';
  @NonNls
  static const URI_PREFIX = '$SCHEME:';

  @NonNls
  static const MIGRATION_SCHEME = 'otpauth-migration';
  @NonNls
  static const MIGRATION_URI_PREFIX = '$MIGRATION_SCHEME:';

  /// we only support time based tokens anyway.
  static const TYPE_TOTP = 'totp'; // NON-NLS
  static const PARAM_SECRET = 'secret'; // NON-NLS
  static const PARAM_ALGORITHM = 'algorithm'; // NON-NLS
  static const PARAM_DIGITS = 'digits'; // NON-NLS
  static const PARAM_PERIOD = 'period'; // NON-NLS

  static const QUERY_PARAM_KEY = 'key'; // NON-NLS
  static const QUERY_PARAM_STEP = 'step'; // NON-NLS
  static const QUERY_PARAM_SIZE = 'size'; // NON-NLS

  static const DEFAULT_ALGORITHM = Algorithm.SHA1;
  static const DEFAULT_DIGITS = 6;
  static const DEFAULT_PERIOD = 30;

  @NonNls
  static Map<Algorithm, String> algorithms = {
    Algorithm.SHA1: 'SHA1',
    Algorithm.SHA256: 'SHA256',
    Algorithm.SHA512: 'SHA512',
  };

  static Algorithm? algorithmForString(String? key) =>
      algorithms.entries.firstWhereOrNull((entry) => entry.value == key)?.key;

  final String label;
  final Algorithm algorithm;
  final Uint8List secret;
  final int digits;
  final int period;

  Uri toUri() => Uri(
    scheme: SCHEME,
    host: TYPE_TOTP,
    pathSegments: [label],
    queryParameters: <String, String?>{
      PARAM_SECRET: base32Encode(secret),
      PARAM_ALGORITHM: algorithms[algorithm],
      PARAM_DIGITS: digits.toString(),
      PARAM_PERIOD: period.toString(),
    },
  );

  @NonNls
  @override
  String toString() {
    return 'OtpAuth{label: $label, algorithm: $algorithm, digits: $digits, period: $period}';
  }
}
