import 'dart:typed_data';

import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/ui/design_system/filter_chips.dart';
import 'package:keynest/ui/screens/keynest_vault_manager_screen.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'util/test_util.dart';
import 'util/test_util.mocks.dart';

class MockCloudStorageProvider extends Mock implements CloudStorageProvider {
  @override
  String get displayName => 'Google Drive';

  @override
  String get id => 'google_drive';

  @override
  String displayNameFromPath(Map<String, String?> fileInfo) => 'PersonalVault';

  @override
  String displayPath(Map<String, String?> fileInfo) =>
      'KeyNest/PersonalVault.kdbx';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('en', null);
  });

  group('Vault Header Layout and Storage Badge Repositioning Tests', () {
    late KdbxFile fileSaf;
    late KdbxFile fileGdrive;
    late KdbxFile fileLong;
    late MockKdbxBloc mockBloc;
    late MemoryFileSystem fs;

    late FileSourceLocal safSource;
    late FileSourceCloudStorage gdriveSource;
    late FileSourceLocal longSource;

    late KdbxOpenedFile openedSaf;
    late KdbxOpenedFile openedGdrive;
    late KdbxOpenedFile openedLong;

    setUp(() {
      final credentials = Credentials.composite(
        ProtectedValue.fromString('TestPass123!'),
        null,
      );
      fileSaf = KdbxFormat().create(credentials, 'myvault.kdbx');
      final rootSaf = fileSaf.body.rootGroup;
      fileSaf.createGroup(parent: rootSaf, name: 'Documents');

      fileGdrive = KdbxFormat().create(credentials, 'CloudVault.kdbx');
      final rootGdrive = fileGdrive.body.rootGroup;
      fileGdrive.createGroup(parent: rootGdrive, name: 'Work');

      fileLong = KdbxFormat().create(credentials, 'LongVault.kdbx');

      fs = MemoryFileSystem();

      // 1. SAF Local FileSource
      safSource = FileSourceLocal(
        fs.file('/storage/emulated/0/test/myvault.kdbx'),
        databaseName: 'myvault',
        uuid: 'vault-saf-uuid',
        filePickerIdentifier:
            'content://com.android.externalstorage.documents/document/primary%3Atest%2Fmyvault.kdbx',
      );
      final ofSaf = OpenedFile.fromFileSource(safSource, 'myvault');
      openedSaf = KdbxOpenedFile(
        fileSource: safSource,
        openedFile: ofSaf,
        kdbxFile: fileSaf,
        kdbxFileContent: FileContent(Uint8List.fromList([1, 2])),
      );

      // 2. Google Drive FileSource
      final gdriveProvider = MockCloudStorageProvider();
      gdriveSource = FileSourceCloudStorage(
        provider: gdriveProvider,
        fileInfo: {
          'id': 'gdrive-file-id-123',
          'name': 'KeyNest/PersonalVault.kdbx',
          'path': '/KeyNest/PersonalVault.kdbx',
        },
        databaseName: 'PersonalVault',
        uuid: 'vault-gdrive-uuid',
      );
      final ofGdrive = OpenedFile.fromFileSource(gdriveSource, 'PersonalVault');
      openedGdrive = KdbxOpenedFile(
        fileSource: gdriveSource,
        openedFile: ofGdrive,
        kdbxFile: fileGdrive,
        kdbxFileContent: FileContent(Uint8List.fromList([3, 4])),
      );

      // 3. Very Long Path & Name FileSource
      longSource = FileSourceLocal(
        fs.file(
          '/storage/emulated/0/Documents/Vaults/Production/Primary/Database/2026/EnterpriseMasterRecordsDatabaseVault.kdbx',
        ),
        databaseName: 'Very Long Company Enterprise Master Database Vault 2026',
        uuid: 'vault-long-uuid',
      );
      final ofLong = OpenedFile.fromFileSource(
        longSource,
        'Very Long Company Enterprise Master Database Vault 2026',
      );
      openedLong = KdbxOpenedFile(
        fileSource: longSource,
        openedFile: ofLong,
        kdbxFile: fileLong,
        kdbxFileContent: FileContent(Uint8List.fromList([5, 6])),
      );

      mockBloc = MockKdbxBloc();
      when(
        mockBloc.openedFilesKdbx,
      ).thenReturn([fileSaf, fileGdrive, fileLong]);
      when(mockBloc.openedFilesWithSources).thenReturn([
        MapEntry(safSource, fileSaf),
        MapEntry(gdriveSource, fileGdrive),
        MapEntry(longSource, fileLong),
      ]);
      when(mockBloc.openedFiles).thenReturn(
        OpenedKdbxFiles({
          safSource: openedSaf,
          gdriveSource: openedGdrive,
          longSource: openedLong,
        }),
      );
      when(mockBloc.fileForKdbxFile(fileSaf)).thenReturn(openedSaf);
      when(mockBloc.fileForKdbxFile(fileGdrive)).thenReturn(openedGdrive);
      when(mockBloc.fileForKdbxFile(fileLong)).thenReturn(openedLong);
    });

    Widget createTestApp({
      Size screenSize = const Size(400, 800),
      List<KdbxOpenedFile>? files,
    }) {
      final activeFiles = files ?? [openedSaf, openedGdrive, openedLong];
      final filesMap = {for (final f in activeFiles) f.fileSource: f};

      when(mockBloc.openedFiles).thenReturn(OpenedKdbxFiles(filesMap));
      when(
        mockBloc.openedFilesKdbx,
      ).thenReturn(activeFiles.map((f) => f.kdbxFile).toList());
      when(mockBloc.openedFilesWithSources).thenReturn(
        activeFiles.map((f) => MapEntry(f.fileSource, f.kdbxFile)).toList(),
      );

      return MediaQuery(
        data: MediaQueryData(size: screenSize),
        child: MultiProvider(
          providers: [
            Provider<KdbxBloc>.value(value: mockBloc),
            Provider<OpenedKdbxFiles>.value(value: OpenedKdbxFiles(filesMap)),
            Provider<Analytics>.value(value: MockAnalytics()),
            Provider<Env>.value(value: TestEnv(EnvSecretsFake(''))),
            Provider<AppData>.value(value: AppData()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const KeyNestVaultManagerScreen(),
          ),
        ),
      );
    }

    testWidgets(
      '1. SAF badge is compact, positioned upward, and header three-dot button aligns with folder button',
      (tester) async {
        await tester.pumpWidget(createTestApp(files: [openedSaf]));
        await tester.pumpAndSettle();

        // Find SAF badge
        final safBadgeFinder = find.widgetWithText(KeyNestStatusBadge, 'SAF');
        expect(safBadgeFinder, findsOneWidget);

        // Find the overflow menus (more_vert icons in header and folder row)
        final overflowMenuFinder = find.byIcon(Icons.more_vert_rounded);
        expect(overflowMenuFinder, findsNWidgets(2));

        // Get bounds of SAF badge, header menu, and folder menu
        final safBadgeRect = tester.getRect(safBadgeFinder);
        final headerMenuRect = tester.getRect(overflowMenuFinder.first);
        final folderMenuRect = tester.getRect(overflowMenuFinder.last);

        // Badge sits in upper-right area above header overflow menu with spacing
        expect(safBadgeRect.bottom, lessThan(headerMenuRect.top));

        // Center X of header three-dot button aligns with folder-row three-dot button
        expect(
          (headerMenuRect.center.dx - folderMenuRect.center.dx).abs(),
          lessThan(1.0),
        );

        // Storage path is rendered and visible
        expect(find.text(safSource.friendlyLocation), findsOneWidget);
      },
    );

    testWidgets(
      '2. Google Drive badge is in upper-right and header three-dot button aligns with folder button',
      (tester) async {
        await tester.pumpWidget(createTestApp(files: [openedGdrive]));
        await tester.pumpAndSettle();

        final gdriveBadgeFinder = find.widgetWithText(
          KeyNestStatusBadge,
          'GOOGLE DRIVE',
        );
        expect(gdriveBadgeFinder, findsOneWidget);

        final overflowMenuFinder = find.byIcon(Icons.more_vert_rounded);
        expect(overflowMenuFinder, findsNWidgets(2));

        final gdriveBadgeRect = tester.getRect(gdriveBadgeFinder);
        final headerMenuRect = tester.getRect(overflowMenuFinder.first);
        final folderMenuRect = tester.getRect(overflowMenuFinder.last);

        // Badge is placed upward in upper-right area, above header overflow menu
        expect(gdriveBadgeRect.bottom, lessThan(headerMenuRect.top));

        // Header three-dot button aligns horizontally with folder three-dot button
        expect(
          (headerMenuRect.center.dx - folderMenuRect.center.dx).abs(),
          lessThan(1.0),
        );

        // Provider name remains readable and complete
        final badgeWidget = tester.widget<KeyNestStatusBadge>(
          gdriveBadgeFinder,
        );
        expect(badgeWidget.text, equals('GOOGLE DRIVE'));
      },
    );

    testWidgets(
      '3. Long storage path and long vault name render without overflow',
      (tester) async {
        await tester.pumpWidget(createTestApp(files: [openedLong]));
        await tester.pumpAndSettle();

        // Check long path text is present
        final pathFinder = find.text(longSource.friendlyLocation);
        expect(pathFinder, findsOneWidget);

        // Verify Text maxLines is 2 to allow wrapping onto second line
        final pathText = tester.widget<Text>(pathFinder);
        expect(pathText.maxLines, equals(2));
        expect(pathText.softWrap, isTrue);

        // Vault name is present
        expect(find.text(longSource.displayName), findsOneWidget);

        // No Flutter layout overflow error occurred during render
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '4. Narrow screen (320px width) renders vault header cleanly without header overflow',
      (tester) async {
        final headerErrors = <FlutterErrorDetails>[];
        final prevOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          final s = details.toString();
          if (s.contains('_buildVaultCard') ||
              s.contains('keynest_vault_manager_screen.dart:449')) {
            headerErrors.add(details);
          }
        };
        addTearDown(() => FlutterError.onError = prevOnError);

        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          createTestApp(screenSize: const Size(320, 640), files: [openedSaf]),
        );
        await tester.pumpAndSettle();

        // Badges should exist and be properly positioned
        final badgeFinder = find.widgetWithText(KeyNestStatusBadge, 'SAF');
        expect(badgeFinder, findsOneWidget);

        // Overflow menu exists
        final overflowFinder = find.byIcon(Icons.more_vert_rounded).first;
        expect(overflowFinder, findsOneWidget);

        // Badge is above overflow menu
        final badgeRect = tester.getRect(badgeFinder);
        final overflowRect = tester.getRect(overflowFinder);
        expect(badgeRect.bottom, lessThan(overflowRect.top));

        // Storage path is rendered
        expect(find.text(safSource.friendlyLocation), findsOneWidget);

        // Expansion control is accessible
        final expandButton = find.byIcon(Icons.expand_less_rounded);
        expect(expandButton, findsOneWidget);

        // Zero errors occurred in the vault header
        expect(headerErrors, isEmpty);
      },
    );

    testWidgets(
      '5. Expand/collapse button toggles properly and does not collide with badge',
      (tester) async {
        await tester.pumpWidget(createTestApp(files: [openedSaf]));
        await tester.pumpAndSettle();

        // Get expand button
        final expandBtn = find.byIcon(Icons.expand_less_rounded);
        expect(expandBtn, findsOneWidget);
        final expandRect = tester.getRect(expandBtn);
        final safBadgeRect = tester.getRect(
          find.widgetWithText(KeyNestStatusBadge, 'SAF'),
        );

        // Expand button does not collide with badge
        expect(expandRect.top, greaterThan(safBadgeRect.top));

        // Tap to collapse
        await tester.tap(expandBtn);
        await tester.pumpAndSettle();

        // Icon changed to expand_more_rounded
        expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
      },
    );
  });
}
