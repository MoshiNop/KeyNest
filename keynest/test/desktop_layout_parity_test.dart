import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/screens/keynest_home_shell.dart';
import 'package:keynest/ui/widgets/keynest_desktop_nav_rail.dart';
import 'package:keynest/ui/widgets/keynest_nav_bar.dart';
import 'package:keynest/utils/platform.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'util/test_util.mocks.dart';

class FakeAnalyticsEvents extends Mock implements AnalyticsEvents {}

class FakeAnalytics extends Mock implements Analytics {
  @override
  final AnalyticsEvents events = FakeAnalyticsEvents();
}

void main() {
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
      // On Windows environment:
      expect(KeyNestPlatform.isDesktopOrWeb, isTrue);
      expect(KeyNestPlatform.isDesktop, isTrue);
      expect(KeyNestPlatform.isWindows, isTrue);
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
}
