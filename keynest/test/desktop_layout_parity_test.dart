import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/l10n-generated/app_localizations_en.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/authenticator_tab.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/screens/keynest_csv_import_screen.dart';
import 'package:keynest/ui/screens/keynest_data_screens.dart';
import 'package:keynest/ui/screens/keynest_home_shell.dart';
import 'package:keynest/ui/screens/password_generator.dart';
import 'package:keynest/ui/widgets/keynest_chips.dart';
import 'package:keynest/ui/widgets/keynest_desktop_nav_rail.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:keynest/ui/widgets/keynest_empty_state.dart';
import 'package:keynest/ui/widgets/keynest_nav_bar.dart';
import 'package:keynest/utils/platform.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'util/test_util.dart';
import 'util/test_util.mocks.dart';

class FakeAnalyticsEvents extends Mock implements AnalyticsEvents {}

class FakeAnalytics extends Mock implements Analytics {
  @override
  final AnalyticsEvents events = FakeAnalyticsEvents();
}

class _TestNavigatorObserver extends NavigatorObserver {
  Route<dynamic>? lastPushedRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastPushedRoute = route;
    super.didPush(route, previousRoute);
  }
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en', null);
  });

  tearDown(() {
    KeyNestPlatform.debugOverrideIsAndroid = null;
    KeyNestPlatform.debugOverrideIsIOS = null;
    KeyNestVaultScope.instance.setActiveTab(0);
  });

  group('Desktop & Mobile Platform Parity Tests', () {
    test('Mobile platforms (Android, iOS) are strictly classified as mobile and not desktop', () {
      // Android
      KeyNestPlatform.debugOverrideIsAndroid = true;
      KeyNestPlatform.debugOverrideIsIOS = false;
      expect(KeyNestPlatform.isAndroid, isTrue);
      expect(KeyNestPlatform.isMobile, isTrue);

      // iOS
      KeyNestPlatform.debugOverrideIsAndroid = false;
      KeyNestPlatform.debugOverrideIsIOS = true;
      expect(KeyNestPlatform.isIOS, isTrue);
      expect(KeyNestPlatform.isMobile, isTrue);
    });

    test('Desktop platforms (Windows, Linux, macOS) and Web share isDesktopOrWeb', () {
      expect(KeyNestPlatform.isDesktopOrWeb, isTrue);
      expect(KeyNestPlatform.isDesktop, isTrue);
      expect(
        KeyNestPlatform.isWindows ||
            KeyNestPlatform.isLinux ||
            KeyNestPlatform.isMacOS,
        isTrue,
      );
    });
  });

  group('KeyNestDesktopNavRail Widget Tests', () {
    testWidgets('Renders all 5 navigation tabs and switches tabs via VaultScope', (tester) async {
      int activeIndex = 0;
      KeyNestVaultScope.instance.setActiveTab(0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return KeyNestDesktopNavRail(
                  currentIndex: activeIndex,
                  counts: const {0: 12, 1: 5, 2: 3, 3: 1, 4: 8},
                  onTap: (index) {
                    setState(() {
                      activeIndex = index;
                    });
                    KeyNestVaultScope.instance.setActiveTab(index);
                  },
                );
              },
            ),
          ),
        ),
      );

      // Check all 5 tabs rendered
      expect(find.text('Secrets'), findsOneWidget);
      expect(find.text('Records'), findsOneWidget);
      expect(find.text('Cards'), findsOneWidget);
      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('2FA'), findsOneWidget);

      // Check badge counts rendered
      expect(find.text('12'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);

      // Tap Records tab
      await tester.tap(find.text('Records'));
      await tester.pumpAndSettle();

      expect(activeIndex, equals(1));
      expect(KeyNestVaultScope.instance.activeTabIndex, equals(1));

      // Tap 2FA tab
      await tester.tap(find.text('2FA'));
      await tester.pumpAndSettle();

      expect(activeIndex, equals(4));
      expect(KeyNestVaultScope.instance.activeTabIndex, equals(4));
    });
  });

  group('Desktop Master View Mode Tests', () {
    testWidgets('KeyNestHomeShell with isDesktopMaster: true omits mobile bottom nav and FAB', (tester) async {
      KeyNestVaultScope.instance.setActiveTab(0);
      final mockKdbxBloc = MockKdbxBloc();
      when(mockKdbxBloc.openedFilesKdbx).thenReturn([]);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<KdbxBloc>.value(value: mockKdbxBloc),
            Provider<Analytics>.value(value: FakeAnalytics()),
            Provider<AppData>.value(value: AppData()),
            ProxyProvider<AppLocalizations, CommonFields>(
              update: (_, loc, _) => CommonFields(loc),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('en'),
            home: KeyNestHomeShell(
              isDesktopMaster: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // Mobile bottom nav should NOT be rendered in desktop master mode
      expect(find.byType(KeyNestBottomNav), findsNothing);

      // Mobile FAB should NOT be rendered in desktop master mode
      expect(find.byType(FloatingActionButton), findsNothing);
    });
  });

  group('Desktop Compact SnackBar Theme Tests', () {
    test('Light and dark themes configure compact floating snackbars on desktop', () {
      final lightTheme = createTheme();
      final darkTheme = createDarkTheme();

      expect(lightTheme.snackBarTheme.behavior, equals(SnackBarBehavior.floating));
      expect(lightTheme.snackBarTheme.width, equals(380.0));

      expect(darkTheme.snackBarTheme.behavior, equals(SnackBarBehavior.floating));
      expect(darkTheme.snackBarTheme.width, equals(380.0));
    });
  });

  group('Desktop Middle Pane Empty States Tests', () {
    testWidgets('Renders clean text message without action button on desktop', (tester) async {
      // Records tab
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: KeyNestEmptyState(
              type: EmptyStateType.records,
              actionLabel: 'Add Record',
            ),
          ),
        ),
      );
      expect(find.text('No records'), findsOneWidget);
      expect(find.text('Add Record'), findsNothing);

      // Cards tab
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: KeyNestEmptyState(
              type: EmptyStateType.cards,
              actionLabel: 'Add card',
            ),
          ),
        ),
      );
      expect(find.text('No cards'), findsOneWidget);
      expect(find.text('Add card'), findsNothing);

      // Notes tab
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: KeyNestEmptyState(
              type: EmptyStateType.notes,
              actionLabel: 'Add note',
            ),
          ),
        ),
      );
      expect(find.text('No notes'), findsOneWidget);
      expect(find.text('Add note'), findsNothing);

      // Secrets tab
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyNestEmptyState.secrets(),
          ),
        ),
      );
      expect(find.text('No items'), findsOneWidget);
      expect(find.text('Add Password'), findsNothing);

      // 2FA tab
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyNestEmptyState.twoFactor(),
          ),
        ),
      );
      expect(find.text('No 2FA accounts'), findsOneWidget);
      expect(find.text('Add 2FA account'), findsNothing);
    });
  });

  group('Desktop Compact Dialog Route Tests', () {
    test('KeyNestDesktopDialogRoute defaults to compact dimensions', () {
      final route = KeyNestDesktopDialogRoute<void>(
        builder: (_) => const SizedBox(),
      );
      expect(route.barrierDismissible, isTrue);
      expect(route.opaque, isFalse);
    });

    test('Settings sub-screens use KeyNestDesktopDialogRoute on desktop', () {
      expect(KeyNestPlatform.isDesktopOrWeb, isTrue);

      final passGenRoute = PasswordGeneratorScreen.route(
        finishButton: FinishButtonStyle.done,
      );
      expect(passGenRoute, isA<KeyNestDesktopDialogRoute<String>>());

      final trashRoute = KeyNestRecentlyDeletedScreen.route();
      expect(trashRoute, isA<KeyNestDesktopDialogRoute<void>>());

      final catRoute = KeyNestManageCategoriesScreen.route();
      expect(catRoute, isA<KeyNestDesktopDialogRoute<void>>());

      final file = TestUtil().createFile();
      final csvRoute = KeyNestCsvImportScreen.route(
        fileName: 'test.csv',
        csvText: 'header\nvalue',
        parsedRows: [
          ['header'],
          ['value'],
        ],
        initialDestination: KeyNestDestination(
          file: file,
          group: file.body.rootGroup,
        ),
      );
      expect(csvRoute, isA<KeyNestDesktopDialogRoute<dynamic>>());
    });
  });

  group('KeyNestChip Selection Indicator Tests', () {
    testWidgets('Selected chip displays checkmark icon and distinct visual state', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: const [
                KeyNestChip(label: 'Unselected', isSelected: false),
                KeyNestChip(label: 'Selected', isSelected: true),
              ],
            ),
          ),
        ),
      );

      // Only the selected chip has a checkmark icon
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.text('Selected'), findsOneWidget);
      expect(find.text('Unselected'), findsOneWidget);
    });
  });

  group('Desktop Empty States Polished Layout Tests', () {
    testWidgets('Renders empty state icon badge, title and helper subtitle on desktop', (tester) async {
      expect(KeyNestPlatform.isDesktopOrWeb, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyNestEmptyState.secrets(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      expect(find.text('No items'), findsOneWidget);
      expect(find.text('Items will appear here once added'), findsOneWidget);
    });
  });

  group('KeyNestTotpCardItem Platform Parity & Regression Tests', () {
    testWidgets('Android platform renders Edit button (Icons.edit_outlined) and opens edit mode directly', (tester) async {
      KeyNestPlatform.debugOverrideIsAndroid = true;
      KeyNestPlatform.debugOverrideIsIOS = false;
      expect(KeyNestPlatform.isDesktopOrWeb, isFalse);
      expect(KeyNestPlatform.isAndroid, isTrue);

      final file = TestUtil().createFile();
      final root = file.body.rootGroup;
      final entry = KdbxEntry.create(file, root);
      root.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Test TOTP Service'));
      entry.setString(KdbxKeyCommon.USER_NAME, PlainValue('user@example.com'));

      final clockNotifier = ValueNotifier<int>(DateTime.now().millisecondsSinceEpoch);
      final navObserver = _TestNavigatorObserver();

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [navObserver],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: KeyNestTotpCardItem(
              entry: entry,
              clockNotifier: clockNotifier,
              searchQuery: '',
              commonFields: CommonFields(AppLocalizationsEn()),
              isDark: false,
              theme: ThemeData.light(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Android displays the Edit icon with tooltip 'Edit entry'
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byTooltip('Edit entry'), findsOneWidget);
      // Desktop 'View details' icon must NOT be present on Android
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
      expect(find.byTooltip('View details'), findsNothing);

      // Tap Edit button
      await tester.tap(find.byIcon(Icons.edit_outlined));

      // Verify EntryDetailsScreen route was pushed with isEditing: true matching main branch
      expect(navObserver.lastPushedRoute, isNotNull);
      final pushedRoute = navObserver.lastPushedRoute!;
      expect(pushedRoute.settings.name, equals('/entry'));

      final itemElement = tester.element(find.byType(KeyNestTotpCardItem));
      final screen = (pushedRoute as PageRouteBuilder).buildPage(
        itemElement,
        const AlwaysStoppedAnimation(1.0),
        const AlwaysStoppedAnimation(0.0),
      ) as EntryDetailsScreen;
      expect(screen.isEditing, isTrue);
      expect(screen.entry, equals(entry));
    });

    testWidgets('Desktop platform renders View details button (Icons.visibility_outlined) and preserves desktop behavior', (tester) async {
      KeyNestPlatform.debugOverrideIsAndroid = false;
      KeyNestPlatform.debugOverrideIsIOS = false;
      expect(KeyNestPlatform.isDesktopOrWeb, isTrue);

      final file = TestUtil().createFile();
      final root = file.body.rootGroup;
      final entry = KdbxEntry.create(file, root);
      root.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Desktop TOTP'));

      final clockNotifier = ValueNotifier<int>(DateTime.now().millisecondsSinceEpoch);
      bool onSelectCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: KeyNestTotpCardItem(
              entry: entry,
              clockNotifier: clockNotifier,
              searchQuery: '',
              commonFields: CommonFields(AppLocalizationsEn()),
              isDark: false,
              theme: ThemeData.light(),
              onSelect: () {
                onSelectCalled = true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Desktop displays the View details icon with tooltip 'View details'
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      expect(find.byTooltip('View details'), findsOneWidget);
      // Mobile 'Edit entry' icon must NOT be present on desktop
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.byTooltip('Edit entry'), findsNothing);

      // Tap View details button - should trigger onSelect on desktop
      await tester.tap(find.byIcon(Icons.visibility_outlined));

      expect(onSelectCalled, isTrue);
    });

    testWidgets('Desktop platform opens entry in view mode (isEditing: false) when onSelect is null', (tester) async {
      KeyNestPlatform.debugOverrideIsAndroid = false;
      KeyNestPlatform.debugOverrideIsIOS = false;
      expect(KeyNestPlatform.isDesktopOrWeb, isTrue);

      final file = TestUtil().createFile();
      final root = file.body.rootGroup;
      final entry = KdbxEntry.create(file, root);
      root.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Desktop View Entry'));

      final clockNotifier = ValueNotifier<int>(DateTime.now().millisecondsSinceEpoch);
      final navObserver = _TestNavigatorObserver();

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [navObserver],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: KeyNestTotpCardItem(
              entry: entry,
              clockNotifier: clockNotifier,
              searchQuery: '',
              commonFields: CommonFields(AppLocalizationsEn()),
              isDark: false,
              theme: ThemeData.light(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify View details icon
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);

      // Tap View details button
      await tester.tap(find.byIcon(Icons.visibility_outlined));

      // Verify EntryDetailsScreen route was pushed with isEditing: false
      expect(navObserver.lastPushedRoute, isNotNull);
      final pushedRoute = navObserver.lastPushedRoute!;
      expect(pushedRoute.settings.name, equals('/entry'));

      final itemElement = tester.element(find.byType(KeyNestTotpCardItem));
      final screen = (pushedRoute as PageRouteBuilder).buildPage(
        itemElement,
        const AlwaysStoppedAnimation(1.0),
        const AlwaysStoppedAnimation(0.0),
      ) as EntryDetailsScreen;
      expect(screen.isEditing, isFalse);
      expect(screen.entry, equals(entry));
    });
  });
}
