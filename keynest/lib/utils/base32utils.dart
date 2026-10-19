import 'dart:typed_data';

import 'package:base32/base32.dart';
import 'package:keynest/utils/constants.dart';

final _cleanRegExp = RegExp(r'[\s\-_]');
final _validBase32Chars = RegExp(r'^[A-Z2-7=]+$');

/// Normalizes a Base32 string by removing spaces, hyphens, underscores,
/// converting to uppercase, and adding standard '=' padding if omitted.
String normalizeBase32(String code) {
  var clean = code.replaceAll(_cleanRegExp, CharConstants.empty).toUpperCase();
  if (clean.isEmpty) {
    return clean;
  }
  final padLength = (8 - (clean.length % 8)) % 8;
  if (padLength > 0) {
    clean += '=' * padLength;
  }
  return clean;
}

/// Decodes an RFC 4648 Base32 string to binary bytes.
/// Tolerates spaces, hyphens, underscores, lowercase, and missing padding.
Uint8List base32Decode(String code) {
  final clean = normalizeBase32(code);
  if (clean.isEmpty) {
    return Uint8List(0);
  }
  if (!_validBase32Chars.hasMatch(clean)) {
    throw FormatException('Invalid Base32 character sequence', code);
  }
  return base32.decode(clean);
}

String base32Encode(Uint8List data) => base32.encode(data);
