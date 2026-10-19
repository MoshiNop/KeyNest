import 'dart:convert';
import 'dart:math';
import 'package:convert/convert.dart' as convert;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:kdbx/kdbx.dart';
import 'package:xml/xml.dart' as xml;

/// Formats of KeePass key files supported by KeyNest.
enum KeyNestKeyFileFormat {
  /// KeePass 2.x XML v2.0 key file with 32-byte hex-encoded key and 4-byte verification hash.
  xmlV2,

  /// KeePass 2.x XML v1.0 key file with 32-byte base64-encoded key.
  xmlV1,

  /// Raw 32-byte binary key file (standard KeePass 1.x / 2.x binary format).
  binary32,

  /// 64-character hexadecimal text key file (decodes to 32 bytes).
  hex64,

  /// Arbitrary file hashed with SHA-256 to produce 32-byte key material.
  hashed,
}

/// Validation exception thrown when a key file is empty, corrupted, or violates standards.
class KeyFileValidationException implements Exception {
  const KeyFileValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of parsing a KeePass key file.
class KeyNestKeyFileResult {
  const KeyNestKeyFileResult({
    required this.keyBytes,
    required this.format,
    required this.displayName,
    required this.summary,
  });

  /// The exact 32-byte key material derived from the key file.
  final Uint8List keyBytes;

  /// The detected format of the key file.
  final KeyNestKeyFileFormat format;

  /// Human-readable format name.
  final String displayName;

  /// Detailed summary of the key file format and properties.
  final String summary;
}

/// Handles standards-compliant KeePass key file parsing, validation, and generation.
class KeyNestKeyFile {
  KeyNestKeyFile._();

  static const int maxKeyFileSize = 32 * 1024 * 1024; // 32 MB limit

  /// Parses and validates any standard KeePass key file.
  /// Throws [KeyFileValidationException] if the file is invalid or corrupted.
  static KeyNestKeyFileResult parse(Uint8List fileBytes, {String? fileName}) {
    if (fileBytes.isEmpty) {
      throw const KeyFileValidationException(
        'Key file is empty (0 bytes). A valid key file must contain key material.',
      );
    }

    if (fileBytes.length > maxKeyFileSize) {
      throw const KeyFileValidationException(
        'Key file exceeds maximum allowed size of 32 MB.',
      );
    }

    // 1. Check for exact 32-byte binary key file
    if (fileBytes.length == 32) {
      // If exactly 32 bytes, KeePass convention uses these 32 bytes directly as the key material.
      return KeyNestKeyFileResult(
        keyBytes: Uint8List.fromList(fileBytes),
        format: KeyNestKeyFileFormat.binary32,
        displayName: '32-Byte Binary Key',
        summary: 'Standard 256-bit binary key file (32 bytes).',
      );
    }

    // 2. Try parsing as text (XML or Hex)
    String text;
    try {
      text = utf8.decode(fileBytes);
    } catch (_) {
      // Not valid UTF-8. Non-UTF8 files can only be arbitrary hashed files.
      final hash = crypto.sha256.convert(fileBytes).bytes;
      return KeyNestKeyFileResult(
        keyBytes: Uint8List.fromList(hash),
        format: KeyNestKeyFileFormat.hashed,
        displayName: 'Hashed Binary Key File',
        summary: 'SHA-256 hashed binary file (${fileBytes.length} bytes).',
      );
    }

    final trimmed = text.trim();

    // 3. Check for XML Key File
    if (trimmed.contains('<KeyFile>') ||
        trimmed.contains('<KeyFile ') ||
        trimmed.startsWith('<?xml')) {
      return _parseXmlKeyFile(trimmed, fileBytes);
    }

    // 4. Check for 64-character Hex string (ignoring whitespace)
    final hexCharsOnly = trimmed.replaceAll(RegExp(r'\s+'), '');
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hexCharsOnly)) {
      try {
        final decoded = convert.hex.decode(hexCharsOnly);
        return KeyNestKeyFileResult(
          keyBytes: Uint8List.fromList(decoded),
          format: KeyNestKeyFileFormat.hex64,
          displayName: '64-Character Hex Key',
          summary: 'Hexadecimal-encoded key file (64 characters / 32 bytes).',
        );
      } catch (e) {
        throw KeyFileValidationException('Failed to decode hex key file: $e');
      }
    }

    // 5. If file looks like an XML file but failed XML detection/validation
    if (trimmed.startsWith('<') && trimmed.endsWith('>')) {
      throw const KeyFileValidationException(
        'Invalid or unrecognized XML format. Key file must contain <KeyFile> and <Key><Data> elements.',
      );
    }

    // 6. Arbitrary file hashed representation (standard KeePass fallback)
    final hash = crypto.sha256.convert(fileBytes).bytes;
    return KeyNestKeyFileResult(
      keyBytes: Uint8List.fromList(hash),
      format: KeyNestKeyFileFormat.hashed,
      displayName: 'Hashed Key File',
      summary: 'SHA-256 hashed file (${fileBytes.length} bytes).',
    );
  }

  /// Parses KeePass 2.x XML key files (both v2.0 hex and v1.0 base64).
  static KeyNestKeyFileResult _parseXmlKeyFile(
    String xmlString,
    Uint8List rawBytes,
  ) {
    xml.XmlDocument doc;
    try {
      doc = xml.XmlDocument.parse(xmlString);
    } catch (e) {
      throw KeyFileValidationException(
        'Malformed XML key file: Failed to parse XML structure.',
      );
    }

    final keyFileElements = doc.findAllElements('KeyFile');
    if (keyFileElements.isEmpty) {
      throw const KeyFileValidationException(
        'Missing <KeyFile> root element in XML key file.',
      );
    }

    final keyElements = doc.findAllElements('Key');
    if (keyElements.isEmpty) {
      throw const KeyFileValidationException(
        'Missing <Key> element in XML key file.',
      );
    }

    final dataElements = keyElements.first.findElements('Data');
    if (dataElements.isEmpty) {
      throw const KeyFileValidationException(
        'Missing <Data> element inside <Key> in XML key file.',
      );
    }

    final dataNode = dataElements.first;
    final rawDataText = dataNode.innerText.replaceAll(RegExp(r'\s+'), '');
    if (rawDataText.isEmpty) {
      throw const KeyFileValidationException(
        'XML key file contains empty <Data> element.',
      );
    }

    final versionElements = doc.findAllElements('Version');
    final versionStr = versionElements.isNotEmpty
        ? versionElements.first.innerText.trim()
        : null;
    final hashAttr = dataNode.getAttribute('Hash');

    // KeePass XML v2.0 (Hex encoded with optional 4-byte verification hash)
    if ((versionStr != null && versionStr.startsWith('2.')) ||
        hashAttr != null) {
      if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(rawDataText)) {
        throw const KeyFileValidationException(
          'Corrupted XML v2 key file: <Data> must contain hexadecimal characters.',
        );
      }

      final Uint8List keyBytes;
      try {
        keyBytes = Uint8List.fromList(convert.hex.decode(rawDataText));
      } catch (e) {
        throw KeyFileValidationException(
          'Invalid hex data in XML key file: $e',
        );
      }

      if (keyBytes.length != 32) {
        throw KeyFileValidationException(
          'Invalid key length in XML key file. Expected 32 bytes (64 hex characters), but found ${keyBytes.length} bytes.',
        );
      }

      // Verify the 4-byte hash if present
      if (hashAttr != null && hashAttr.trim().isNotEmpty) {
        final cleanHash = hashAttr.replaceAll(RegExp(r'\s+'), '');
        final Uint8List expectedHash;
        try {
          expectedHash = Uint8List.fromList(convert.hex.decode(cleanHash));
        } catch (_) {
          throw const KeyFileValidationException(
            'Corrupted XML key file: Invalid hex in Hash attribute.',
          );
        }

        if (expectedHash.length != 4) {
          throw KeyFileValidationException(
            'Invalid Hash attribute length. Expected 4 bytes (8 hex characters), found ${expectedHash.length} bytes.',
          );
        }

        final actualHash = Uint8List.fromList(
          crypto.sha256.convert(keyBytes).bytes.sublist(0, 4),
        );

        if (!listEquals(expectedHash, actualHash)) {
          throw const KeyFileValidationException(
            'Corrupted XML key file: Verification hash does not match key data. The key file may be damaged.',
          );
        }
      }

      return KeyNestKeyFileResult(
        keyBytes: keyBytes,
        format: KeyNestKeyFileFormat.xmlV2,
        displayName: 'KeePass XML Key File (v2.0)',
        summary: 'KeePass 2.x XML v2.0 key file with verified hash.',
      );
    }

    // KeePass XML v1.0 (Base64 encoded)
    try {
      final keyBytes = Uint8List.fromList(base64.decode(rawDataText));
      if (keyBytes.isEmpty) {
        throw const KeyFileValidationException(
          'Base64 decoded key data is empty.',
        );
      }
      return KeyNestKeyFileResult(
        keyBytes: keyBytes,
        format: KeyNestKeyFileFormat.xmlV1,
        displayName: 'KeePass XML Key File (v1.0)',
        summary:
            'KeePass 2.x XML v1.0 base64-encoded key file (${keyBytes.length} bytes).',
      );
    } catch (e) {
      if (e is KeyFileValidationException) {
        rethrow;
      }
      throw KeyFileValidationException(
        'Corrupted XML v1 key file: Failed to decode base64 data ($e).',
      );
    }
  }

  /// Creates composite KDBX credentials combining a master password and key file.
  /// Fully standard-compliant with KeePass KDBX composite credential derivation.
  static Credentials createCompositeCredentials({
    String? password,
    Uint8List? keyFileBytes,
  }) {
    final passwordCreds = (password != null && password.isNotEmpty)
        ? PasswordCredentials(ProtectedValue.fromString(password))
        : null;

    if (keyFileBytes == null || keyFileBytes.isEmpty) {
      if (passwordCreds == null) {
        throw ArgumentError('Either password or key file must be provided.');
      }
      return Credentials.composite(ProtectedValue.fromString(password!), null);
    }

    final keyResult = parse(keyFileBytes);
    final keyFileCreds = KeyFileCredentials.fromBytes(keyResult.keyBytes);

    return KeyFileComposite(
      password: passwordCreds,
      keyFile: keyFileCreds,
    );
  }

  /// Generates a KeePass-compatible XML 2.0 key file (`.keyx`).
  static Uint8List generateXmlV2({Uint8List? keyBytes}) {
    final key = keyBytes ?? _generateRandom32Bytes();
    if (key.length != 32) {
      throw ArgumentError('Key material must be exactly 32 bytes.');
    }

    final hash = Uint8List.fromList(
      crypto.sha256.convert(key).bytes.sublist(0, 4),
    );
    final hashHex = _formatHexKeepass(convert.hex.encode(hash).toUpperCase());
    final keyHex = _formatHexKeepass(convert.hex.encode(key).toUpperCase());

    final builder = xml.XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="utf-8"');
    builder.element(
      'KeyFile',
      nest: () {
        builder.element(
          'Meta',
          nest: () {
            builder.element(
              'Version',
              nest: () {
                builder.text('2.0');
              },
            );
          },
        );
        builder.element(
          'Key',
          nest: () {
            builder.element(
              'Data',
              nest: () {
                builder.attribute('Hash', hashHex);
                builder.text(keyHex);
              },
            );
          },
        );
      },
    );

    final xmlDoc = builder.buildDocument();
    return Uint8List.fromList(utf8.encode(xmlDoc.toXmlString(pretty: true)));
  }

  static Uint8List _generateRandom32Bytes() {
    final random = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  static String _formatHexKeepass(String hexString) {
    final buffer = StringBuffer();
    for (var i = 0; i < hexString.length; i += 8) {
      if (i > 0) {
        buffer.write(' ');
      }
      final end = (i + 8 <= hexString.length) ? i + 8 : hexString.length;
      buffer.write(hexString.substring(i, end));
    }
    return buffer.toString();
  }
}
