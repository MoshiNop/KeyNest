import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/keynest_data_screens.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'util/test_util.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KeyNestRecentlyDeletedScreen Tests', () {
    late KdbxFile kdbxFile;
    late MockKdbxBloc mockBloc;
    late FileSource dummySource;

    setUp(() {
      kdbxFile = KdbxFormat().create(
        Credentials.composite(ProtectedValue.fromString('pass'), null),
        'Vault',
      );

      dummySource = FileSourceUrl(
        Uri.parse('https://example.com/vault.kdbx'),
        uuid: 'vault-uuid-trash',
        databaseName: 'Vault',
      );

      mockBloc = MockKdbxBloc();
      when(mockBloc.openedFilesKdbx).thenReturn([kdbxFile]);
      when(mockBloc.openedFilesWithSources).thenReturn([
        MapEntry(dummySource, kdbxFile),
      ]);
      when(mockBloc.saveFile(any)).thenAnswer(
        (_) async => FileContent(Uint8List.fromList([1, 2, 3])),
      );
    });

    Widget buildTestApp() {
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: keyNestDarkTheme,
        home: Provider<KdbxBloc>.value(
          value: mockBloc,
          child: const KeyNestRecentlyDeletedScreen(),
        ),
      );
    }

    testWidgets('Permanently deleting an item removes it from screen immediately', (
      tester,
    ) async {
      // Create a deleted entry in recycle bin
      final entry = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      kdbxFile.body.rootGroup.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Disposable Secret'));
      entry.setString(KdbxKeyCommon.USER_NAME, PlainValue('test_user'));
      kdbxFile.deleteEntry(entry); // moves to recycle bin

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Verify the item is displayed
      expect(find.text('Disposable Secret'), findsOneWidget);
      expect(find.text('test_user'), findsOneWidget);

      // Tap Delete Permanently icon button
      final deleteIcon = find.byTooltip('Delete Permanently');
      expect(deleteIcon, findsOneWidget);
      await tester.tap(deleteIcon);
      await tester.pumpAndSettle();

      // Verify confirmation dialog
      expect(find.text('Delete Permanently?'), findsOneWidget);
      expect(
        find.text(
          'Permanently delete "Disposable Secret"? This cannot be undone.',
        ),
        findsOneWidget,
      );

      // Tap Delete
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      // The item should be immediately removed from the screen without needing to reopen!
      expect(find.text('Disposable Secret'), findsNothing);
      expect(find.text('Trash is Empty'), findsOneWidget);
    });

    testWidgets('Restoring an item removes it from Recently Deleted screen immediately', (
      tester,
    ) async {
      final entry = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      kdbxFile.body.rootGroup.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Restorable Item'));
      kdbxFile.deleteEntry(entry);

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.text('Restorable Item'), findsOneWidget);

      // Tap Restore
      await tester.tap(find.widgetWithText(TextButton, 'Restore'));
      await tester.pumpAndSettle();

      // The item should disappear from the trash screen immediately!
      expect(find.text('Restorable Item'), findsNothing);
      expect(find.text('Trash is Empty'), findsOneWidget);
    });

    testWidgets('Empty Trash removes all items immediately', (tester) async {
      final entry1 = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      kdbxFile.body.rootGroup.addEntry(entry1);
      entry1.setString(KdbxKeyCommon.TITLE, PlainValue('Item 1'));
      kdbxFile.deleteEntry(entry1);

      final entry2 = KdbxEntry.create(kdbxFile, kdbxFile.body.rootGroup);
      kdbxFile.body.rootGroup.addEntry(entry2);
      entry2.setString(KdbxKeyCommon.TITLE, PlainValue('Item 2'));
      kdbxFile.deleteEntry(entry2);

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.text('Item 1'), findsOneWidget);
      expect(find.text('Item 2'), findsOneWidget);

      // Tap Empty button in AppBar
      await tester.tap(find.text('Empty'));
      await tester.pumpAndSettle();

      expect(find.text('Empty Trash?'), findsOneWidget);

      // Confirm Empty Trash
      await tester.tap(find.widgetWithText(TextButton, 'Empty Trash'));
      await tester.pumpAndSettle();

      expect(find.text('Item 1'), findsNothing);
      expect(find.text('Item 2'), findsNothing);
      expect(find.text('Trash is Empty'), findsOneWidget);
    });
  });
}
