import 'package:flutter_test/flutter_test.dart';
import 'package:keynest/utils/password_generator.dart';

void main() {
  group('PasswordGenerator Tests', () {
    final generator = PasswordGenerator.singleton();

    test('CharacterRange length is inclusive', () {
      expect(CharacterSet.alphabetAsciiLowerCase.length, 26);
      expect(CharacterSet.alphabetAsciiUpperCase.length, 26);
      expect(CharacterSet.numeric.length, 10);

      // Verify bounds
      expect(String.fromCharCode(CharacterSet.alphabetAsciiLowerCase[0]), 'a');
      expect(String.fromCharCode(CharacterSet.alphabetAsciiLowerCase[25]), 'z');
      expect(String.fromCharCode(CharacterSet.alphabetAsciiUpperCase[0]), 'A');
      expect(String.fromCharCode(CharacterSet.alphabetAsciiUpperCase[25]), 'Z');
      expect(String.fromCharCode(CharacterSet.numeric[0]), '0');
      expect(String.fromCharCode(CharacterSet.numeric[9]), '9');
    });

    test('generates password of requested length', () {
      const set = CharacterSet.alphaNumeric;
      for (final len in [0, 1, 5, 16, 32, 64]) {
        final pwd = generator.generatePassword(set, len);
        expect(pwd.length, len);
      }
    });

    test('guarantees representation of each selected character set', () {
      const collection = CharacterSetCollection([
        CharacterSet.alphabetAsciiLowerCase,
        CharacterSet.alphabetAsciiUpperCase,
        CharacterSet.numeric,
        CharacterSet.specialCharacters,
      ]);

      // Run multiple iterations to verify deterministic presence
      for (var i = 0; i < 50; i++) {
        final pwd = generator.generatePassword(collection, 16);
        expect(pwd.length, 16);

        final hasLower = pwd.contains(RegExp(r'[a-z]'));
        final hasUpper = pwd.contains(RegExp(r'[A-Z]'));
        final hasDigit = pwd.contains(RegExp(r'[0-9]'));
        final hasSpecial = pwd
            .split('')
            .any((c) => CharacterSet.specialCharacters.contains(c));

        expect(hasLower, isTrue, reason: 'Expected lowercase in "$pwd"');
        expect(hasUpper, isTrue, reason: 'Expected uppercase in "$pwd"');
        expect(hasDigit, isTrue, reason: 'Expected digit in "$pwd"');
        expect(
          hasSpecial,
          isTrue,
          reason: 'Expected special character in "$pwd"',
        );
      }
    });

    test('handles edge case when length equals number of sets', () {
      const collection = CharacterSetCollection([
        CharacterSet.alphabetAsciiLowerCase,
        CharacterSet.alphabetAsciiUpperCase,
        CharacterSet.numeric,
        CharacterSet.specialCharacters,
      ]);

      final pwd = generator.generatePassword(collection, 4);
      expect(pwd.length, 4);
      expect(pwd.contains(RegExp(r'[a-z]')), isTrue);
      expect(pwd.contains(RegExp(r'[A-Z]')), isTrue);
      expect(pwd.contains(RegExp(r'[0-9]')), isTrue);
    });

    test('handles empty collection or length 0 safely', () {
      const emptyCollection = CharacterSetCollection([]);
      expect(generator.generatePassword(emptyCollection, 10), '');
      expect(generator.generatePassword(CharacterSet.alphaNumeric, 0), '');
      expect(generator.generatePassword(CharacterSet.alphaNumeric, -5), '');
    });
  });
}

extension on CharacterSet {
  bool contains(String char) {
    if (char.isEmpty) {
      return false;
    }
    final code = char.codeUnitAt(0);
    for (var i = 0; i < length; i++) {
      if (this[i] == code) {
        return true;
      }
    }
    return false;
  }
}
