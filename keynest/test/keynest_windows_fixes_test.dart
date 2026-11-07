import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/l10n-generated/app_localizations_en.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/screens/main_app_scaffold.dart';
import 'package:keynest/ui/widgets/keynest_desktop_nav_rail.dart';
import 'package:keynest/ui/widgets/keynest_nav_bar.dart';
import 'package:keynest/utils/platform.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'util/test_util.dart';
import 'util/test_util.mocks.dart';

class _FakeAnalyticsEvents extends Mock implements AnalyticsEvents {}

class _FakeAnalytics extends Mock implements Analytics {
  @override
  final AnalyticsEvents events = _FakeAnalyticsEvents();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en', null);
  });

  group('Windows & Desktop Window Sizing & Menu Parity Tests', () {
    late KdbxFile kdbxFile;
    late MockKdbxBloc mockBloc;
    late FileSource dummySource;

    setUp(() {
      KeyNestPlatform.debugOverrideIsAndroid = false;
      KeyNestPlatform.debugOverrideIsIOS = false;
      KeyNestVaultScope.instance.setActiveTab(0);
      KeyNestVaultScope.instance.setSearchQuery('');

      kdbxFile = KdbxFormat().create(
        Credentials.composite(ProtectedValue.fromString('pass'), null),
        'Vault',
      );

      dummySource = FileSourceUrl(
        Uri.parse('https://example.com/vault.kdbx'),
        uuid: 'vault-uuid-test',
        databaseName: 'Vault',
      );

      final openedFile = KdbxOpenedFile(
        fileSource: dummySource,
        openedFile: OpenedFile.fromFileSource(dummySource, 'Vault'),
        kdbxFile: kdbxFile,
        kdbxFileContent: FileContent(Uint8List.fromList([1, 2])),
      );

      mockBloc = MockKdbxBloc();
      when(mockBloc.openedFilesKdbx).thenReturn([kdbxFile]);
      when(mockBloc.fileForKdbxFile(any)).thenReturn(openedFile);
      when(mockBloc.openedFilesWithSources).thenReturn([
        MapEntry(dummySource, kdbxFile),
      ]);
    });

    Widget createTestApp({required double width, required double height}) {
      return MultiProvider(
        providers: [
          Provider<KdbxBloc>.value(value: mockBloc),
          Provider<Analytics>.value(value: _FakeAnalytics()),
          Provider<AppData>.value(value: AppData()),
          Provider<CommonFields>.value(value: CommonFields(AppLocalizationsEn())),
          Provider<Env>.value(value: TestEnv(EnvSecretsFake(''))),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: MediaQuery(
            data: MediaQueryData(size: Size(width, height)),
            child: SizedBox(
              width: width,
              height: height,
              child: MainAppTabletScaffold(),
            ),
          ),
        ),
      );
    }

    testWidgets('Wide desktop mode (width >= 780): shows NavRail, hides BottomNav', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(createTestApp(width: 1024, height: 768));
      await tester.pumpAndSettle();

      // NavRail should be visible in wide desktop mode
      expect(find.byType(KeyNestDesktopNavRail), findsOneWidget);

      // BottomNav should be omitted in wide desktop mode
      expect(find.byType(KeyNestBottomNav), findsNothing);
    });

    testWidgets('Narrow desktop mode (width 600): hides NavRail, renders BottomNav and top bar menu actions', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(createTestApp(width: 600, height: 800));
      await tester.pumpAndSettle();

      // NavRail should be hidden to give list full width
      expect(find.byType(KeyNestDesktopNavRail), findsNothing);

      // BottomNav MUST be visible so user can switch tabs like phone/tablet
      expect(find.byType(KeyNestBottomNav), findsOneWidget);

      // Menu actions in top bar should be visible (Manage Vaults, Settings, Lock Vault)
      expect(find.byTooltip('Manage Vaults'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(find.byTooltip('Lock Vault'), findsOneWidget);
    });

    testWidgets('Very narrow desktop mode (width 400): renders BottomNav and overflow menu button', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(createTestApp(width: 400, height: 800));
      await tester.pumpAndSettle();

      // NavRail hidden
      expect(find.byType(KeyNestDesktopNavRail), findsNothing);

      // BottomNav visible
      expect(find.byType(KeyNestBottomNav), findsOneWidget);

      // Overflow menu button visible
      expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
    });

    testWidgets('Detail pane route pop resets selected entry so entry never becomes static on re-click', (tester) async {
      final root = kdbxFile.body.rootGroup;
      final entry = KdbxEntry.create(kdbxFile, root);
      root.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Test Login'));
      entry.setString(KdbxKeyCommon.USER_NAME, PlainValue('user@example.com'));

      await tester.binding.setSurfaceSize(const Size(1024, 768));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(createTestApp(width: 1024, height: 768));
      await tester.pumpAndSettle();

      // Tap the entry card in PasswordList to open view mode
      expect(find.text('Test Login'), findsOneWidget);
      await tester.tap(find.text('Test Login'));
      await tester.pumpAndSettle();

      // View mode details screen should now be visible in detail pane
      expect(find.text('user@example.com'), findsWidgets);

      // Tap the top bar back button to exit view mode
      expect(find.byTooltip('Back'), findsWidgets);
      await tester.tap(find.byTooltip('Back').first);
      await tester.pumpAndSettle();

      // Empty state should be restored in detail pane
      expect(find.byType(EmptyStateInitialRoute), findsOneWidget);

      // Now tap the EXACT SAME entry card again - it MUST reopen view mode immediately!
      await tester.tap(find.text('Test Login'));
      await tester.pumpAndSettle();

      // Entry view mode reopened successfully without becoming static
      expect(find.text('user@example.com'), findsWidgets);
    });
  });
}
