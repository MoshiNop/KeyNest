import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('desktop_credential_cipher');

final class _Win32DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptProtectDataNative = Int32 Function(
  Pointer<_Win32DataBlob> pDataIn,
  Pointer<Uint16> szDataDescr,
  Pointer<_Win32DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_Win32DataBlob> pDataOut,
);

typedef _CryptProtectDataDart = int Function(
  Pointer<_Win32DataBlob> pDataIn,
  Pointer<Uint16> szDataDescr,
  Pointer<_Win32DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<_Win32DataBlob> pDataOut,
);

typedef _CryptUnprotectDataNative = Int32 Function(
  Pointer<_Win32DataBlob> pDataIn,
  Pointer<Pointer<Uint16>> ppszDataDescr,
  Pointer<_Win32DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_Win32DataBlob> pDataOut,
);

typedef _CryptUnprotectDataDart = int Function(
  Pointer<_Win32DataBlob> pDataIn,
  Pointer<Pointer<Uint16>> ppszDataDescr,
  Pointer<_Win32DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<_Win32DataBlob> pDataOut,
);

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> hMem);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> hMem);

/// Encrypts and decrypts desktop cloud credential maps at rest using
/// Windows DPAPI (`CryptProtectData` / `CryptUnprotectData`) on Windows,
/// and AES-256-GCM with `0600` owner-only permissions on Linux/POSIX.
class DesktopCredentialCipher {
  DesktopCredentialCipher._();

  @NonNls
  static const String _schemeWin32Dpapi = 'win32_dpapi';
  @NonNls
  static const String _schemeAes256Gcm = 'aes256_gcm';
  @NonNls
  static const String _dpapiEntropyText = 'KeyNest.DesktopCloudCredentials.v1';

  static const int _cryptProtectUiForbidden = 0x01;

  static DynamicLibrary? _crypt32;
  static DynamicLibrary? _kernel32;
  static _CryptProtectDataDart? _cryptProtectData;
  static _CryptUnprotectDataDart? _cryptUnprotectData;
  static _LocalFreeDart? _localFree;

  static void _ensureWin32Loaded() {
    if (_cryptProtectData != null &&
        _cryptUnprotectData != null &&
        _localFree != null) {
      return;
    }
    final crypt32 = _crypt32 ??= DynamicLibrary.open(nonNls('crypt32.dll'));
    final kernel32 = _kernel32 ??= DynamicLibrary.open(nonNls('kernel32.dll'));
    _cryptProtectData = crypt32
        .lookupFunction<_CryptProtectDataNative, _CryptProtectDataDart>(
          nonNls('CryptProtectData'),
        );
    _cryptUnprotectData = crypt32
        .lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectDataDart>(
          nonNls('CryptUnprotectData'),
        );
    _localFree = kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>(
      nonNls('LocalFree'),
    );
  }

  /// Encrypts [plaintextJson] into a JSON envelope string suitable for disk storage.
  static Future<String> encryptPayload(
    String plaintextJson, {
    required Directory appDataDir,
  }) async {
    final plainBytes = Uint8List.fromList(utf8.encode(plaintextJson));
    try {
      if (Platform.isWindows) {
        final cipherBytes = _dpapiProtect(plainBytes);
        return json.encode(
          nonNls(<String, Object>{
            'version': 1,
            'scheme': _schemeWin32Dpapi,
            'ciphertext': base64.encode(cipherBytes),
          }),
        );
      }

      final key = await _getOrCreatePosixKey(appDataDir);
      try {
        final rand = Random.secure();
        final iv = Uint8List.fromList(
          List<int>.generate(12, (_) => rand.nextInt(256)),
        );
        final cipher = GCMBlockCipher(AESEngine())
          ..init(
            true,
            AEADParameters(
              KeyParameter(key),
              128,
              iv,
              Uint8List.fromList(utf8.encode(_dpapiEntropyText)),
            ),
          );
        final cipherBytes = cipher.process(plainBytes);
        return json.encode(
          nonNls(<String, Object>{
            'version': 1,
            'scheme': _schemeAes256Gcm,
            'iv': base64.encode(iv),
            'ciphertext': base64.encode(cipherBytes),
          }),
        );
      } finally {
        key.fillRange(0, key.length, 0);
      }
    } finally {
      plainBytes.fillRange(0, plainBytes.length, 0);
    }
  }

  /// Decrypts an envelope produced by [encryptPayload], or transparently parses
  /// legacy plaintext JSON maps so existing files can be upgraded cleanly.
  static Future<Map<String, dynamic>> decryptPayload(
    String rawContent, {
    required Directory appDataDir,
  }) async {
    final trimmed = rawContent.trim();
    if (trimmed.isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = json.decode(trimmed);
    if (decoded is! Map<String, dynamic>) {
      return <String, dynamic>{};
    }

    final scheme = decoded[nonNls('scheme')] as String?;
    final ciphertextB64 = decoded[nonNls('ciphertext')] as String?;
    if (scheme == null || ciphertextB64 == null) {
      // Legacy unencrypted JSON map; caller can re-encrypt on next write.
      return decoded;
    }

    final cipherBytes = base64.decode(ciphertextB64);
    Uint8List? plainBytes;
    try {
      if (scheme == _schemeWin32Dpapi) {
        if (!Platform.isWindows) {
          throw UnsupportedError(
            'Cannot decrypt win32_dpapi payload on ${Platform.operatingSystem}',
          );
        }
        plainBytes = _dpapiUnprotect(cipherBytes);
      } else if (scheme == _schemeAes256Gcm) {
        final ivB64 = decoded[nonNls('iv')] as String?;
        if (ivB64 == null) {
          throw const FormatException('Missing IV in aes256_gcm envelope.');
        }
        final iv = base64.decode(ivB64);
        final key = await _getOrCreatePosixKey(appDataDir);
        try {
          final cipher = GCMBlockCipher(AESEngine())
            ..init(
              false,
              AEADParameters(
                KeyParameter(key),
                128,
                iv,
                Uint8List.fromList(utf8.encode(_dpapiEntropyText)),
              ),
            );
          plainBytes = cipher.process(cipherBytes);
        } finally {
          key.fillRange(0, key.length, 0);
        }
      } else {
        throw UnsupportedError('Unknown credential cipher scheme: $scheme');
      }

      final inner = json.decode(utf8.decode(plainBytes));
      if (inner is Map<String, dynamic>) {
        return inner;
      }
      return <String, dynamic>{};
    } finally {
      if (plainBytes != null) {
        plainBytes.fillRange(0, plainBytes.length, 0);
      }
    }
  }

  static Uint8List _dpapiProtect(Uint8List plainBytes) {
    _ensureWin32Loaded();
    final entropyBytes = utf8.encode(_dpapiEntropyText);

    final pDataIn = calloc<_Win32DataBlob>();
    final pEntropy = calloc<_Win32DataBlob>();
    final pDataOut = calloc<_Win32DataBlob>();
    final inBuf = calloc<Uint8>(plainBytes.isEmpty ? 1 : plainBytes.length);
    final entropyBuf = calloc<Uint8>(entropyBytes.length);

    try {
      if (plainBytes.isNotEmpty) {
        inBuf.asTypedList(plainBytes.length).setAll(0, plainBytes);
      }
      entropyBuf.asTypedList(entropyBytes.length).setAll(0, entropyBytes);

      pDataIn.ref
        ..cbData = plainBytes.length
        ..pbData = inBuf;
      pEntropy.ref
        ..cbData = entropyBytes.length
        ..pbData = entropyBuf;

      final ok = _cryptProtectData!(
        pDataIn,
        nullptr,
        pEntropy,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        pDataOut,
      );
      if (ok == 0) {
        throw StateError('Win32 CryptProtectData failed.');
      }

      final outLen = pDataOut.ref.cbData;
      final outPtr = pDataOut.ref.pbData;
      final result = Uint8List.fromList(outPtr.asTypedList(outLen));
      _localFree!(outPtr.cast<Void>());
      return result;
    } finally {
      if (plainBytes.isNotEmpty) {
        inBuf.asTypedList(plainBytes.length).fillRange(0, plainBytes.length, 0);
      }
      calloc.free(inBuf);
      calloc.free(entropyBuf);
      calloc.free(pDataIn);
      calloc.free(pEntropy);
      calloc.free(pDataOut);
    }
  }

  static Uint8List _dpapiUnprotect(Uint8List cipherBytes) {
    _ensureWin32Loaded();
    final entropyBytes = utf8.encode(_dpapiEntropyText);

    final pDataIn = calloc<_Win32DataBlob>();
    final pEntropy = calloc<_Win32DataBlob>();
    final pDataOut = calloc<_Win32DataBlob>();
    final inBuf = calloc<Uint8>(cipherBytes.isEmpty ? 1 : cipherBytes.length);
    final entropyBuf = calloc<Uint8>(entropyBytes.length);

    try {
      if (cipherBytes.isNotEmpty) {
        inBuf.asTypedList(cipherBytes.length).setAll(0, cipherBytes);
      }
      entropyBuf.asTypedList(entropyBytes.length).setAll(0, entropyBytes);

      pDataIn.ref
        ..cbData = cipherBytes.length
        ..pbData = inBuf;
      pEntropy.ref
        ..cbData = entropyBytes.length
        ..pbData = entropyBuf;

      final ok = _cryptUnprotectData!(
        pDataIn,
        nullptr,
        pEntropy,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        pDataOut,
      );
      if (ok == 0) {
        throw StateError('Win32 CryptUnprotectData failed.');
      }

      final outLen = pDataOut.ref.cbData;
      final outPtr = pDataOut.ref.pbData;
      try {
        return Uint8List.fromList(outPtr.asTypedList(outLen));
      } finally {
        if (outLen > 0 && outPtr != nullptr) {
          outPtr.asTypedList(outLen).fillRange(0, outLen, 0);
        }
        _localFree!(outPtr.cast<Void>());
      }
    } finally {
      calloc.free(inBuf);
      calloc.free(entropyBuf);
      calloc.free(pDataIn);
      calloc.free(pEntropy);
      calloc.free(pDataOut);
    }
  }

  static Future<Uint8List> _getOrCreatePosixKey(Directory appDataDir) async {
    if (!appDataDir.existsSync()) {
      await appDataDir.create(recursive: true);
    }
    final keyFile = File(nonNls('${appDataDir.path}/.cloud_credentials.key'));
    if (keyFile.existsSync()) {
      final b64 = (await keyFile.readAsString()).trim();
      final decoded = base64.decode(b64);
      if (decoded.length == 32) {
        return Uint8List.fromList(decoded);
      }
    }
    final rand = Random.secure();
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => rand.nextInt(256)),
    );
    await keyFile.writeAsString(base64.encode(key), flush: true);
    await restrictPosixPermissions(keyFile);
    return key;
  }

  static Future<void> restrictPosixPermissions(File file) async {
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        await Process.run(nonNls('chmod'), [nonNls('600'), file.path]);
      } catch (e) {
        _logger.fine('Could not chmod 600 ${file.path}: $e');
      }
    }
  }
}
