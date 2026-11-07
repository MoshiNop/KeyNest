import 'dart:io';
import 'dart:math' as math;

import 'package:autofill_shared/credential_matcher.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:kdbx/kdbx.dart';

/// Channel the native credential provider talks to. Same name on iOS and
/// macOS.
const _channelName = 'com.moshinop.keynest/autofill';

/// Entry point for the headless engine the credential provider extension
/// boots. There is no [runApp] — the native side renders everything, this only
/// answers questions about the vault.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AutofillVaultService().attach(const MethodChannel(_channelName));
}

/// Errors reported back over the channel. The native side maps these to user
/// facing screens, so keep them stable.
class AutofillErrors {
  static const noVault = 'NO_VAULT';
  static const staleKey = 'STALE_KEY';
  static const invalidKey = 'INVALID_KEY';
  static const notOpen = 'NOT_OPEN';
  static const failed = 'FAILED';
}

/// Holds the vaults the extension is currently working with.
///
/// [openVaults] takes every vault the user enabled, keyed by file uuid, so a
/// lookup can span them. The single-vault `openVault` remains for the memory
/// spike, which measures one file at a time.
class AutofillVaultService {
  /// The spike's single file. Kept separate from [_files] so the two entry
  /// points cannot interfere with each other's measurements.
  KdbxFile? _file;

  /// Vaults opened by [_openVaults], keyed by the manifest's file uuid.
  final Map<String, _OpenVault> _files = {};

  final _format = KdbxFormat();

  /// Parsing the suffix list costs a few milliseconds, so it happens once.
  final _matcher = CredentialMatcher.instance;

  void attach(MethodChannel channel) {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'ping':
          return 'pong';
        case 'openVault':
          return await _openVault(_args(call));
        case 'listEntries':
          return _listEntries();
        case 'openVaults':
          return await _openVaults(_args(call));
        case 'matchEntries':
          return _matchEntries(_args(call));
        case 'credentialFor':
          final args = _args(call);
          final fileUuid = args['fileUuid'] as String?;
          return fileUuid == null
              // Single-vault instance maintained for backward compatibility.
              ? _credentialFor(args['uuid']! as String)
              : _credentialForIn(fileUuid, args['uuid']! as String);
        case 'close':
          _file = null;
          _files.clear();
          return null;
        default:
          throw MissingPluginException('unknown method ${call.method}');
      }
    });
  }

  Map<String, Object?> _args(MethodCall call) =>
      (call.arguments as Map<Object?, Object?>).cast<String, Object?>();

  /// Opens the mirrored vault with a key the app already derived.
  ///
  /// Argon2 never runs here; if [kdfFingerprint] no longer matches the file the
  /// app has to refresh the cached key.
  Future<Map<String, Object?>> _openVault(Map<String, Object?> args) async {
    final path = args['path']! as String;
    final transformedKey = args['transformedKey']! as Uint8List;
    final kdfFingerprint = args['kdfFingerprint']! as String;

    final file = File(path);
    if (!file.existsSync()) {
      throw PlatformException(
        code: AutofillErrors.noVault,
        message: 'no vault at $path',
      );
    }

    final stopwatch = Stopwatch()..start();
    try {
      _file = await _format.read(
        await file.readAsBytes(),
        TransformedKeyCredentials(
          transformedKey: transformedKey,
          kdfFingerprint: kdfFingerprint,
        ),
      );
    } on KdbxTransformedKeyStaleException catch (e) {
      throw PlatformException(
        code: AutofillErrors.staleKey,
        message: 'vault was saved elsewhere',
        details: e.toString(),
      );
    } on KdbxInvalidKeyException {
      throw PlatformException(
        code: AutofillErrors.invalidKey,
        message: 'cached key does not open this vault',
      );
    } catch (e) {
      throw PlatformException(
        code: AutofillErrors.failed,
        message: e.toString(),
      );
    }
    stopwatch.stop();

    return {
      'entryCount': _requireFile().body.rootGroup.getAllEntries().length,
      'elapsedMs': stopwatch.elapsedMilliseconds,
    };
  }

  /// Metadata only — no secrets cross the channel until one is picked.
  List<Map<String, Object?>> _listEntries() {
    return _requireFile().body.rootGroup
        .getAllEntries()
        .map(
          (entry) => {
            'uuid': entry.uuid.uuid,
            'label': entry.label,
            'username': entry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            'url': entry.getString(KdbxKeyCommon.URL)?.getText(),
          },
        )
        .toList();
  }

  Map<String, Object?> _credentialFor(String uuid) {
    final entry = _requireFile().body.rootGroup.getAllEntries().firstWhere(
      (entry) => entry.uuid.uuid == uuid,
      orElse: () => throw PlatformException(
        code: AutofillErrors.failed,
        message: 'no entry $uuid',
      ),
    );
    final otp = _totpFor(entry);
    return {
      'username': entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '',
      'password': entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '',
      if (otp != null && otp.isNotEmpty) 'otp': otp,
    };
  }

  String? _totpFor(KdbxEntry entry) {
    final raw = entry.getString(KdbxKeyCommon.OTP)?.getText()?.trim() ??
        entry.getString(KdbxKey('otp'))?.getText()?.trim() ??
        entry.getString(KdbxKey('TimeOtp-Secret-Base32'))?.getText()?.trim() ??
        entry.getString(KdbxKey('TOTP Seed'))?.getText()?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final settings = entry.getString(KdbxKey('TOTP Settings'))?.getText()?.trim();
    return _computeRfc6238Totp(raw, totpSettings: settings);
  }

  static String? _computeRfc6238Totp(
    String rawSecretOrUri, {
    String? totpSettings,
  }) {
    try {
      String secretBase32 = rawSecretOrUri.trim();
      int digits = 6;
      int period = 30;
      String algorithm = 'SHA1';

      if (secretBase32.toLowerCase().startsWith('otpauth://')) {
        final uri = Uri.tryParse(secretBase32);
        if (uri == null || uri.host.toLowerCase() == 'hotp') {
          return null;
        }
        final secretParam = uri.queryParameters['secret'];
        if (secretParam == null || secretParam.trim().isEmpty) {
          return null;
        }
        secretBase32 = secretParam.trim();
        final parsedDigits = int.tryParse(uri.queryParameters['digits'] ?? '');
        if (parsedDigits != null && parsedDigits >= 6 && parsedDigits <= 10) {
          digits = parsedDigits;
        }
        final parsedPeriod = int.tryParse(uri.queryParameters['period'] ?? '');
        if (parsedPeriod != null && parsedPeriod > 0) {
          period = parsedPeriod;
        }
        final parsedAlgo = uri.queryParameters['algorithm']?.toUpperCase();
        if (parsedAlgo == 'SHA1' ||
            parsedAlgo == 'SHA256' ||
            parsedAlgo == 'SHA512') {
          algorithm = parsedAlgo!;
        }
      } else if (totpSettings != null && totpSettings.isNotEmpty) {
        final parts = totpSettings.split(';');
        if (parts.isNotEmpty) {
          final p = int.tryParse(parts[0].trim());
          if (p != null && p > 0) {
            period = p;
          }
        }
        if (parts.length > 1) {
          final d = int.tryParse(parts[1].trim());
          if (d != null && d >= 6 && d <= 10) {
            digits = d;
          }
        }
      }

      final secretBytes = _decodeBase32(secretBase32);
      if (secretBytes == null || secretBytes.isEmpty) {
        return null;
      }

      final counter =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) ~/ period;
      final counterBytes = Uint8List(8);
      var c = counter;
      for (var i = 7; i >= 0; i--) {
        counterBytes[i] = c & 0xff;
        c >>= 8;
      }

      final Hash hashAlgo = switch (algorithm) {
        'SHA256' => sha256,
        'SHA512' => sha512,
        _ => sha1,
      };
      final mac = Hmac(hashAlgo, secretBytes).convert(counterBytes).bytes;
      secretBytes.fillRange(0, secretBytes.length, 0);

      final offset = mac.last & 0x0f;
      final binary = ((mac[offset] & 0x7f) << 24) |
          ((mac[offset + 1] & 0xff) << 16) |
          ((mac[offset + 2] & 0xff) << 8) |
          (mac[offset + 3] & 0xff);
      final mod = math.pow(10, digits).toInt();
      return (binary % mod).toString().padLeft(digits, '0');
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _decodeBase32(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final cleaned = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-=]'), '');
    if (cleaned.isEmpty) {
      return null;
    }
    var buffer = 0;
    var bitsLeft = 0;
    final out = <int>[];
    for (var i = 0; i < cleaned.length; i++) {
      final idx = alphabet.indexOf(cleaned[i]);
      if (idx < 0) {
        return null;
      }
      buffer = (buffer << 5) | idx;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        out.add((buffer >> bitsLeft) & 0xff);
      }
    }
    return Uint8List.fromList(out);
  }

  KdbxFile _requireFile() {
    final file = _file;
    if (file == null) {
      throw PlatformException(
        code: AutofillErrors.notOpen,
        message: 'no vault open',
      );
    }
    return file;
  }

  // Multi-vault lookup implementation.

  /// Opens every vault it is given, and reports on each one separately.
  ///
  /// One unopenable vault must not sink the others: a user with three
  /// databases, one of them saved on another device since the app last cached
  /// its key, should still be offered credentials from the other two. So a
  /// failure becomes a `status` on that vault rather than an exception.
  Future<List<Map<String, Object?>>> _openVaults(
    Map<String, Object?> args,
  ) async {
    final vaults = (args['vaults']! as List<Object?>)
        .map((v) => (v! as Map<Object?, Object?>).cast<String, Object?>())
        .toList();
    _files.clear();
    final results = <Map<String, Object?>>[];
    for (final vault in vaults) {
      final fileUuid = vault['fileUuid']! as String;
      final name = vault['name'] as String? ?? '';
      try {
        final file = await _read(vault);
        _files[fileUuid] = _OpenVault(name: name, file: file);
        results.add({
          'fileUuid': fileUuid,
          'status': 'open', // NON-NLS
          'entryCount': file.body.rootGroup.getAllEntries().length,
        });
      } on PlatformException catch (e) {
        results.add({
          'fileUuid': fileUuid,
          'status': e.code,
          'message': e.message,
        });
      }
    }
    return results;
  }

  Future<KdbxFile> _read(Map<String, Object?> vault) async {
    final path = vault['path']! as String;
    final file = File(path);
    if (!file.existsSync()) {
      throw PlatformException(
        code: AutofillErrors.noVault,
        message: 'no vault at $path',
      );
    }
    try {
      return await _format.read(
        await file.readAsBytes(),
        TransformedKeyCredentials(
          transformedKey: vault['transformedKey']! as Uint8List,
          kdfFingerprint: vault['kdfFingerprint']! as String,
        ),
      );
    } on KdbxTransformedKeyStaleException catch (e) {
      throw PlatformException(
        code: AutofillErrors.staleKey,
        message: 'vault was saved elsewhere',
        details: e.toString(),
      );
    } on KdbxInvalidKeyException {
      throw PlatformException(
        code: AutofillErrors.invalidKey,
        message: 'cached key does not open this vault',
      );
    }
  }

  /// The entries worth offering for [args.identifiers], best match first.
  ///
  /// Filtering occurs in Dart rather than native code to minimize IPC overhead:
  /// transmitting thousands of entries over the platform channel would incur
  /// high memory and serialization costs. Only matching entry metadata crosses
  /// the channel, and sensitive credentials are only transferred upon selection.
  List<Map<String, Object?>> _matchEntries(Map<String, Object?> args) {
    final identifiers = (args['identifiers'] as List<Object?>? ?? [])
        .whereType<String>();
    final limit = args['limit'] as int? ?? 50;

    final requests = [
      for (final identifier in identifiers)
        // iOS hands over domains and urls; an android package name arrives
        // through the same door on the other platform.
        if (identifier.contains('://') || identifier.contains('.'))
          CredentialRequest.web(identifier)
        else
          CredentialRequest.application(identifier),
    ].where((request) => !request.isEmpty).toList();
    if (requests.isEmpty) {
      return const [];
    }

    // Ranked across every vault at once. Ranking per vault and concatenating
    // would put a weak match from the first database above an exact one from
    // the second.
    // Deleted entries are skipped here as well as in the app's identity
    // publishing, and both are needed: the QuickType bar is built from what the
    // app registered, but opening the picker directly goes through this path
    // and never consults it. Filtering only there left the bin reachable by the
    // keyboard's key icon.
    final candidates = [
      for (final vault in _files.entries)
        for (final entry in vault.value.file.body.rootGroup.getAllEntries())
          if (!entry.isInRecycleBin()) ...[
            _Candidate(vault.key, vault.value.name, entry),
          ],
    ];

    final ranked = _matcher.rank(
      requests,
      candidates,
      (candidate) => candidate.entry.autofillUrls,
    );

    return [
      for (final candidate in ranked.take(limit))
        {
          'fileUuid': candidate.fileUuid,
          'fileName': candidate.fileName,
          'uuid': candidate.entry.uuid.uuid,
          'label': candidate.entry.label,
          'username': candidate.entry
              .getString(KdbxKeyCommon.USER_NAME)
              ?.getText(),
          'quality': _matcher
              .matchBest(requests, candidate.entry.autofillUrls)
              ?.name,
        },
    ];
  }

  Map<String, Object?> _credentialForIn(String fileUuid, String entryUuid) {
    final vault = _files[fileUuid];
    if (vault == null) {
      throw PlatformException(
        code: AutofillErrors.notOpen,
        message: 'vault $fileUuid is not open',
      );
    }
    final entry = vault.file.body.rootGroup.getAllEntries().firstWhere(
      (entry) => entry.uuid.uuid == entryUuid,
      orElse: () => throw PlatformException(
        code: AutofillErrors.failed,
        message: 'no entry $entryUuid',
      ),
    );
    final otp = _totpFor(entry);
    return {
      'username': entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '',
      'password': entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '',
      if (otp != null && otp.isNotEmpty) 'otp': otp,
    };
  }
}

class _OpenVault {
  _OpenVault({required this.name, required this.file});

  final String name;
  final KdbxFile file;
}

class _Candidate {
  _Candidate(this.fileUuid, this.fileName, this.entry);

  final String fileUuid;
  final String fileName;
  final KdbxEntry entry;
}
