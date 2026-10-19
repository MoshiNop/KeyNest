import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/ui/screens/password_list.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:mockito/mockito.dart';

import '../../util/test_util.dart';
import '../../util/test_util.mocks.dart';

void main() {
  PrintAppender.setupLogging();
  final testUtil = TestUtil();
  group('entry view model', () {
    late KdbxEntry entry;
    late MockKdbxBloc kdbxBloc;

    setUp(() {
      final file = testUtil.createFile();
      final rootGroup = file.body.rootGroup;
      entry = KdbxEntry.create(file, rootGroup);
      rootGroup.addEntry(entry);

      kdbxBloc = MockKdbxBloc();
      final fakeFile = OpenedFile(
        (b) => b
          ..lastOpenedAt = clock.now().toUtc()
          ..uuid = AppDataBloc.createUuid()
          ..sourceType = OpenedFilesSourceType.Url
          ..sourcePath = 'foo'
          ..name = 'bar',
      );
      final fakeKdbxOpenedFile = KdbxOpenedFile(
        fileSource: FileSourceUrl(
          Uri.parse('https://keynest.app/'),
          uuid: AppDataBloc.createUuid(),
        ),
        openedFile: fakeFile,
        kdbxFile: file,
        kdbxFileContent: FileContent(Uint8List(0)),
      );
      when(kdbxBloc.fileForKdbxFile(any)).thenReturn(fakeKdbxOpenedFile);
    });
    String? website(String value) {
      entry.setString(EntryViewModel.websiteKey, PlainValue(value));
      final vm = EntryViewModel(entry, kdbxBloc);
      return vm.website;
    }

    test('url transforms', () {
      expect(website('keynest.app'), 'http://keynest.app/');
      // Note: multi-line input handling should be standardized.
      expect(website('keynest.app\nloremipsum'), 'http://keynest.app/');
      expect(website('\n\nkeynest.app\r\n'), 'http://keynest.app/');
      expect(website('\n\nkeynest.app//blubb\r\n'), 'http://keynest.app/');
      expect(website('   \n'), isNull);
    });
  });
}
