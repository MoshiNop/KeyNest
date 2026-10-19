import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/ui/screens/password_list.dart';

import 'util/test_util.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PasswordListFilterIsolateRunner Tests', () {
    late KdbxFile kdbxFile;
    late MockKdbxBloc kdbxBloc;
    late AppData appData;

    setUp(() {
      final credentials = Credentials.composite(
        ProtectedValue.fromString('master-pass'),
        null,
      );
      kdbxFile = KdbxFormat().create(credentials, 'TestVault');
      kdbxBloc = MockKdbxBloc();
      appData = AppData();
    });

    test('matches title with exact, substring, and fuzzy matching', () {
      final entryAmazon = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      entryAmazon.setString(
        KdbxKeyCommon.TITLE,
        PlainValue('Amazon Web Services'),
      );
      final vmAmazon = EntryViewModel(entryAmazon, kdbxBloc);

      // Exact substring
      expect(
        PasswordListFilterIsolateRunner.filterEntries(
          appData,
          [vmAmazon],
          'amazon',
        ),
        isNotEmpty,
      );

      // Substring inside title
      expect(
        PasswordListFilterIsolateRunner.filterEntries(
          appData,
          [vmAmazon],
          'services',
        ),
        isNotEmpty,
      );

      // Fuzzy subsequence ('amzn' -> Amazon)
      expect(
        PasswordListFilterIsolateRunner.filterEntries(
          appData,
          [vmAmazon],
          'amzn',
        ),
        isNotEmpty,
      );
    });

    test('matches internal content: username, notes, and custom fields', () {
      final entry = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('My Bank Account'));
      entry.setString(KdbxKeyCommon.USER_NAME, PlainValue('john_doe_99'));
      entry.setString(KdbxKey('Notes'), PlainValue('PIN code is hidden here'));
      entry.setString(KdbxKey('CustomAccountNumber'), PlainValue('9876543210'));

      final vm = EntryViewModel(entry, kdbxBloc);

      // Search by username
      expect(
        PasswordListFilterIsolateRunner.filterEntries(appData, [
          vm,
        ], 'john_doe'),
        isNotEmpty,
      );

      // Search by notes
      expect(
        PasswordListFilterIsolateRunner.filterEntries(appData, [
          vm,
        ], 'hidden pin'),
        isNotEmpty,
      );

      // Search by custom field
      expect(
        PasswordListFilterIsolateRunner.filterEntries(appData, [vm], '987654'),
        isNotEmpty,
      );
    });

    test('relevance sorting puts exact matches above fuzzy matches', () {
      final entryFuzzy = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      entryFuzzy.setString(KdbxKeyCommon.TITLE, PlainValue('Amateur Zone'));
      final entryExact = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      entryExact.setString(KdbxKeyCommon.TITLE, PlainValue('Amazon'));

      final vmFuzzy = EntryViewModel(entryFuzzy, kdbxBloc);
      final vmExact = EntryViewModel(entryExact, kdbxBloc);

      final results = PasswordListFilterIsolateRunner.filterEntries(
        appData,
        [vmFuzzy, vmExact],
        'amazon',
      );

      expect(results.first.entry, equals(entryExact));
    });
  });
}
