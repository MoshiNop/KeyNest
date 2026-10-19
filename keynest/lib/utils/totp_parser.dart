class TotpQrData {
  const TotpQrData({
    required this.secret,
    this.issuer,
    this.accountName,
    required this.title,
    this.algorithm = 'SHA1',
    this.digits = 6,
    this.period = 30,
    this.rawUri,
  });

  final String secret;
  final String? issuer;
  final String? accountName;
  final String title;
  final String algorithm;
  final int digits;
  final int period;
  final String? rawUri;

  /// Parses a QR code string or URI into structured TOTP parameters.
  ///
  /// Supports:
  /// - Standard otpauth URIs: `otpauth://totp/[issuer:]account?secret=...&issuer=...`
  /// - KeeOTP parameters: `key=...&size=...&step=...`
  /// - Plain Base32 secrets: `JBSWY3DPEHPK3PXP`
  static TotpQrData? parse(String input) {
    final raw = input.trim();
    if (raw.isEmpty) {
      return null;
    }

    // 1. Check if standard otpauth URI
    if (raw.toLowerCase().startsWith('otpauth://')) {
      return _parseOtpAuthUri(raw);
    }

    // 2. KeeOTP format (e.g. key={base32Key}&size=6&step=30)
    if (raw.contains('key=')) {
      try {
        final data = Uri.splitQueryString(raw);
        final rawKey = data['key'];
        if (rawKey != null && rawKey.trim().isNotEmpty) {
          final cleanKey = cleanSecret(rawKey);
          if (isValidBase32(cleanKey)) {
            final step = int.tryParse(data['step'] ?? '') ?? 30;
            final size = int.tryParse(data['size'] ?? '') ?? 6;
            return TotpQrData(
              secret: cleanKey,
              title: '2FA Account',
              period: step,
              digits: size,
              rawUri: raw,
            );
          }
        }
      } catch (_) {}
    }

    // 3. Raw Base32 secret string (length >= 8, only base32 chars)
    final cleaned = cleanSecret(raw);
    if (cleaned.length >= 8 && isValidBase32(cleaned)) {
      return TotpQrData(
        secret: cleaned,
        title: '2FA Account',
        period: 30,
        digits: 6,
        rawUri: 'otpauth://totp/2FA%20Account?secret=$cleaned',
      );
    }

    return null;
  }

  static TotpQrData? _parseOtpAuthUri(String uriString) {
    try {
      final uri = Uri.parse(uriString);
      final query = uri.queryParameters;

      // Extract secret
      var rawSecret = query['secret'] ?? '';
      if (rawSecret.isEmpty) {
        for (final entry in query.entries) {
          if (entry.key.toLowerCase() == 'secret') {
            rawSecret = entry.value;
            break;
          }
        }
      }
      final cleanedSecret = cleanSecret(rawSecret);
      if (cleanedSecret.isEmpty || !isValidBase32(cleanedSecret)) {
        return null;
      }

      // Extract path / label (e.g. "/GitHub:alice" or "/alice@gmail.com")
      var rawPath = uri.path;
      if (rawPath.startsWith('/')) {
        rawPath = rawPath.substring(1);
      }
      final decodedPath = Uri.decodeComponent(rawPath).trim();

      String? pathIssuer;
      String? pathAccount;

      if (decodedPath.isNotEmpty) {
        if (decodedPath.contains(':')) {
          final colonIdx = decodedPath.indexOf(':');
          pathIssuer = decodedPath.substring(0, colonIdx).trim();
          pathAccount = decodedPath.substring(colonIdx + 1).trim();
        } else {
          pathAccount = decodedPath;
        }
      }

      // Query issuer
      final queryIssuer = query['issuer']?.trim();

      // Effective issuer
      final effectiveIssuer = (queryIssuer != null && queryIssuer.isNotEmpty)
          ? queryIssuer
          : ((pathIssuer != null && pathIssuer.isNotEmpty) ? pathIssuer : null);

      // Effective account name
      final effectiveAccount = (pathAccount != null && pathAccount.isNotEmpty)
          ? pathAccount
          : null;

      // Automatic Title Population:
      // Uses issuer and account name, or fallbacks
      final String title = computeAutomaticTitle(
        issuer: effectiveIssuer,
        accountName: effectiveAccount,
        fallbackLabel: decodedPath,
      );

      // Algorithm
      final rawAlgo = query['algorithm']?.toUpperCase() ?? 'SHA1';
      final algo = (rawAlgo == 'SHA256' || rawAlgo == 'SHA512')
          ? rawAlgo
          : 'SHA1';

      // Digits & Period
      final digits = int.tryParse(query['digits'] ?? '') ?? 6;
      final period = int.tryParse(query['period'] ?? '') ?? 30;

      return TotpQrData(
        secret: cleanedSecret,
        issuer: effectiveIssuer,
        accountName: effectiveAccount,
        title: title,
        algorithm: algo,
        digits: digits,
        period: period,
        rawUri: uriString,
      );
    } catch (_) {
      return null;
    }
  }

  /// Automatically computes a clean title from issuer and account name.
  static String computeAutomaticTitle({
    String? issuer,
    String? accountName,
    String? fallbackLabel,
  }) {
    final cleanIssuer = issuer?.trim() ?? '';
    final cleanAccount = accountName?.trim() ?? '';
    final cleanFallback = fallbackLabel?.trim() ?? '';

    if (cleanIssuer.isNotEmpty && cleanAccount.isNotEmpty) {
      if (cleanIssuer.toLowerCase() == cleanAccount.toLowerCase()) {
        return cleanIssuer;
      }
      return '$cleanIssuer ($cleanAccount)';
    } else if (cleanIssuer.isNotEmpty) {
      return cleanIssuer;
    } else if (cleanAccount.isNotEmpty) {
      return cleanAccount;
    } else if (cleanFallback.isNotEmpty) {
      return cleanFallback;
    } else {
      return '2FA Account';
    }
  }

  /// Cleans whitespace, hyphens, and standardizes to uppercase.
  static String cleanSecret(String secret) {
    return secret.replaceAll(RegExp(r'[\s\-_]'), '').toUpperCase();
  }

  /// Checks if a string is valid Base32 characters (A-Z, 2-7, optional = padding).
  static bool isValidBase32(String secret) {
    if (secret.isEmpty) {
      return false;
    }
    return RegExp(r'^[A-Z2-7=]+$').hasMatch(secret);
  }

  /// Serializes into a standard-compliant `otpauth://totp/...` URI.
  String toOtpAuthUri() {
    final effectiveTitle = title.trim().isNotEmpty
        ? title.trim()
        : '2FA Account';
    final encIssuer = issuer != null && issuer!.trim().isNotEmpty
        ? issuer!.trim()
        : null;
    final encAccount = accountName != null && accountName!.trim().isNotEmpty
        ? accountName!.trim()
        : null;

    final String label;
    if (encIssuer != null && encAccount != null) {
      label =
          '${Uri.encodeComponent(encIssuer)}:${Uri.encodeComponent(encAccount)}';
    } else if (encIssuer != null) {
      label = Uri.encodeComponent(encIssuer);
    } else if (encAccount != null) {
      label = Uri.encodeComponent(encAccount);
    } else {
      label = Uri.encodeComponent(effectiveTitle);
    }

    final query = <String, String>{
      'secret': secret,
      'algorithm': algorithm,
      'digits': '$digits',
      'period': '$period',
    };
    if (encIssuer != null) {
      query['issuer'] = encIssuer;
    }

    return Uri(
      scheme: 'otpauth',
      host: 'totp',
      path: '/$label',
      queryParameters: query,
    ).toString();
  }
}
