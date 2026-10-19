import 'dart:math';

import 'package:charcode/ascii.dart';
import 'package:charcode/html_entity.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

class PasswordGenerator {
  factory PasswordGenerator.singleton() => _instance;
  PasswordGenerator._();

  static final _instance = PasswordGenerator._();
  final _random = Random.secure();

  String generatePassword(CharacterSet characterSet, int length) {
    if (length <= 0) {
      return '';
    }
    final max = characterSet.length;
    if (max == 0) {
      return '';
    }

    if (characterSet is CharacterSetCollection) {
      final validSets = characterSet.sets
          .where((s) => s != null && s.length > 0)
          .cast<CharacterSet>()
          .toList();
      if (validSets.isNotEmpty && length >= validSets.length) {
        final chars = <int>[];
        // 1. Guarantee at least one character from each selected set
        for (final set in validSets) {
          chars.add(set[_random.nextInt(set.length)]);
        }
        // 2. Fill the rest randomly from the full collection
        while (chars.length < length) {
          chars.add(characterSet[_random.nextInt(max)]);
        }
        // 3. Securely shuffle so guaranteed characters are randomly placed
        for (var i = chars.length - 1; i > 0; i--) {
          final j = _random.nextInt(i + 1);
          final temp = chars[i];
          chars[i] = chars[j];
          chars[j] = temp;
        }
        return String.fromCharCodes(chars);
      }
    }

    return String.fromCharCodes(
      List.generate(length, (i) => characterSet[_random.nextInt(max)]),
    );
  }
}

abstract class CharacterSet {
  const CharacterSet();

  static const alphabetAsciiLowerCase = CharacterRange($a, $z);
  static const alphabetAsciiUpperCase = CharacterRange($A, $Z);
  static const numeric = CharacterRange($0, $9);
  static const alphabetUmlauts = CharacterRange($Agrave, $yuml);
  @NonNls
  static const specialCharacters = CharacterString(
    r'''@%+\/$'!#$^?:,.(){}[]~-_''',
  );

  /// keys used for persisting user selection for default password generator.
  @NonNls
  static const selectableCharacterSets = {
    'alphabetAsciiLowerCase': alphabetAsciiLowerCase,
    'alphabetAsciiUpperCase': alphabetAsciiUpperCase,
    'numeric': numeric,
    'alphabetUmlauts': alphabetUmlauts,
    'specialCharacters': specialCharacters,
  };

  static const alphaNumeric = CharacterSetCollection([
    alphabetAsciiLowerCase,
    alphabetAsciiUpperCase,
    numeric,
  ]);

  int operator [](int pos);

  int get length;

  CharacterSet operator +(CharacterSet other) =>
      CharacterSetCollection([this, other]);

  static String characterSetIdFor(CharacterSet? set) => selectableCharacterSets
      .entries
      .firstWhere((entry) => entry.value == set)
      .key;

  static Set<CharacterSet?> characterSetFromIds(Iterable<String> ids) =>
      ids.map((setId) => CharacterSet.selectableCharacterSets[setId]).toSet();
}

class CharacterSetCollection extends CharacterSet {
  const CharacterSetCollection(this.sets);

  final List<CharacterSet?> sets;

  @override
  int operator [](int pos) {
    var i = pos;
    for (final set in sets) {
      if (i < set!.length) {
        return set[i];
      }
      i -= set.length;
    }
    throw RangeError('Unable to find $pos ($i items after last index).');
  }

  @override
  int get length => sets.fold(0, (prev, set) => prev + set!.length);
}

class CharacterRange extends CharacterSet {
  const CharacterRange(this.charCodeStart, this.charCodeEnd);

  final int charCodeStart;
  final int charCodeEnd;

  @override
  int operator [](int pos) {
    final ret = charCodeStart + pos;
    if (ret > charCodeEnd) {
      throw RangeError(
        'Out of range. $pos (vs. $charCodeStart to $charCodeEnd)',
      );
    }
    return ret;
  }

  @override
  int get length => charCodeEnd - charCodeStart + 1;
}

class CharacterString extends CharacterSet {
  const CharacterString(this._string);

  final String _string;

  @override
  int operator [](int pos) => _string.codeUnitAt(pos);

  @override
  int get length => _string.length;
}
