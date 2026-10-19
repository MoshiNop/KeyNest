import 'package:flutter_test/flutter_test.dart';
import 'package:keynest/utils/error_utils.dart' as err_utils;

void main() {
  group('throws() helper tests', () {
    test('throws without stack trace throws exception directly', () {
      expect(
        () => err_utils.throws(FormatException('test-format-error')),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws with stack trace preserves the original stack trace', () {
      late StackTrace originalTrace;
      late StackTrace caughtTrace;

      try {
        try {
          throw const FormatException('inner error');
        } catch (e, st) {
          originalTrace = st;
          err_utils.throws(e, st);
        }
      } catch (e, st) {
        caughtTrace = st;
      }

      // Verify that the stack trace points to the inner error site and contains original frames
      expect(caughtTrace.toString(), equals(originalTrace.toString()));
    });
  });
}
