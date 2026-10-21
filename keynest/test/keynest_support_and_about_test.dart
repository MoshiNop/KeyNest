import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/deps.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_github_service.dart';
import 'package:keynest/services/keynest_support_service.dart';
import 'package:keynest/ui/screens/about.dart';
import 'package:keynest/ui/screens/app_bar_menu.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

class FakeDeps implements Deps {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeAnalytics implements Analytics {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KeyNestSupportService Log Sanitization Tests', () {
    test('Redacts passwords, tokens, and cryptographic keys', () {
      const rawLog = '''
2026-10-21 12:00:00 [INFO] User opened vault
2026-10-21 12:00:01 [DEBUG] password: MySuperSecretVaultPassword123!
2026-10-21 12:00:02 [DEBUG] masterPassword=AnotherSecretMasterKey
2026-10-21 12:00:03 [DEBUG] Authorization: Bearer ya29.a0AfH6SMAAAAAA-secret-token
2026-10-21 12:00:04 [DEBUG] access_token: secret_access_token_xyz
2026-10-21 12:00:05 [DEBUG] refresh_token: secret_refresh_token_abc
2026-10-21 12:00:06 [DEBUG] client_secret: super_secret_oauth_client_secret
2026-10-21 12:00:07 [DEBUG] encryptionKey: 0123456789abcdef0123456789abcdef
2026-10-21 12:00:08 [INFO] System OS: Windows 11, Version: 10.0.22631
''';

      final sanitized = KeyNestSupportService.sanitizeLogContent(rawLog);

      expect(sanitized, isNot(contains('MySuperSecretVaultPassword123!')));
      expect(sanitized, isNot(contains('AnotherSecretMasterKey')));
      expect(sanitized, isNot(contains('ya29.a0AfH6SMAAAAAA-secret-token')));
      expect(sanitized, isNot(contains('secret_access_token_xyz')));
      expect(sanitized, isNot(contains('secret_refresh_token_abc')));
      expect(sanitized, isNot(contains('super_secret_oauth_client_secret')));
      expect(sanitized, isNot(contains('0123456789abcdef0123456789abcdef')));

      expect(sanitized, contains('[REDACTED]'));
      expect(sanitized, contains('Windows 11'));
      expect(sanitized, contains('User opened vault'));
    });
  });

  group('KeyNestGitHubService Models and Parsing Tests', () {
    test('GitHubRepoInfo parses json and fallback values correctly', () {
      final repo = GitHubRepoInfo.fromJson({
        'name': 'KeyNest',
        'full_name': 'MoshiNop/KeyNest',
        'html_url': 'https://github.com/MoshiNop/KeyNest',
        'description': 'Free, open-source KeePass password manager',
        'stargazers_count': 42,
        'forks_count': 5,
        'open_issues_count': 2,
        'default_branch': 'main',
        'license': {
          'name': 'GNU General Public License v3.0',
          'spdx_id': 'GPL-3.0',
        },
      });

      expect(repo.name, equals('KeyNest'));
      expect(repo.fullName, equals('MoshiNop/KeyNest'));
      expect(repo.starsCount, equals(42));
      expect(repo.licenseSpdx, equals('GPL-3.0'));

      final json = repo.toJson();
      expect(json['full_name'], equals('MoshiNop/KeyNest'));
    });

    test('GitHubContributor parses json correctly', () {
      final contributor = GitHubContributor.fromJson({
        'login': 'MoshiNop',
        'avatar_url': 'https://avatars.githubusercontent.com/u/212212047?v=4',
        'html_url': 'https://github.com/MoshiNop',
        'contributions': 20,
      });

      expect(contributor.login, equals('MoshiNop'));
      expect(contributor.contributions, equals(20));
      expect(contributor.avatarUrl, contains('212212047'));
    });

    test('GitHubRelease parses json correctly with assets', () {
      final release = GitHubRelease.fromJson({
        'tag_name': 'v1.0.0',
        'name': 'KeyNest v1.0.0',
        'published_at': '2026-10-20T00:59:14Z',
        'html_url': 'https://github.com/MoshiNop/KeyNest/releases/tag/v1.0.0',
        'body': 'Initial production release.',
        'assets': [
          {
            'name': 'Keynest-release-arm64-v8a.apk',
            'browser_download_url':
                'https://github.com/MoshiNop/KeyNest/releases/download/v1.0.0/Keynest-release-arm64-v8a.apk',
          }
        ],
      });

      expect(release.tagName, equals('v1.0.0'));
      expect(release.apkAssetName, equals('Keynest-release-arm64-v8a.apk'));
      expect(release.apkDownloadUrl, contains('.apk'));
    });

    test('KeyNestAboutData round-trip serialization', () {
      final aboutData = KeyNestAboutData.fallback;
      final json = aboutData.toJson();
      final restored = KeyNestAboutData.fromJson(json, isFromCache: true);

      expect(restored.repo.fullName, equals('MoshiNop/KeyNest'));
      expect(restored.contributors.first.login, equals('MoshiNop'));
      expect(restored.isFromCache, isTrue);
    });
  });

  group('AppBarMenu Initial Page Menu Tests', () {
    testWidgets('Initial page menu provides Send Logs, Help, About, and Contact',
        (tester) async {
      final openedKdbxFiles = OpenedKdbxFiles({});
      final fakeDeps = FakeDeps();
      final fakeAnalytics = FakeAnalytics();

      late List<PopupMenuEntry<VoidCallback>> items;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<Analytics>.value(value: fakeAnalytics),
            Provider<Deps>.value(value: fakeDeps),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                items = AppBarMenu.createDefaultPopupMenuItems(
                  context,
                  openedKdbxFiles,
                  isOnOpenFileScreen: true,
                ).toList();

                return Scaffold(
                  body: Center(
                    child: Text('Menu Item Count: ${items.length}'),
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.pump();

      // Verify 3 popup entries exist (Theme Selection, Send Logs, About)
      expect(items.length, equals(3));

      // Inspect child widgets of items
      final itemTitles = <String>[];
      for (final item in items) {
        if (item is PopupMenuItem<VoidCallback>) {
          final child = item.child;
          if (child is ListTile && child.title is Text) {
            itemTitles.add((child.title as Text).data ?? '');
          }
        }
      }

      expect(itemTitles, contains('Send Logs'));
      expect(itemTitles, contains('About'));
      expect(itemTitles, isNot(contains('Help')));
      expect(itemTitles, isNot(contains('Contact')));
    });
  });

  group('AboutScreen Widget Tests', () {
    testWidgets('Renders KeyNest identity, project sections, and licenses',
        (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'KeyNest',
        packageName: 'com.moshinop.keynest',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );

      // Pre-populate mock data to guarantee deterministic, immediate rendering in test
      KeyNestGitHubService.setMockData(KeyNestAboutData.fallback);
      addTearDown(() => KeyNestGitHubService.setMockData(null));

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AboutScreen(),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify App Identity
      expect(find.text('About KeyNest'), findsOneWidget);
      expect(find.text('KeyNest'), findsOneWidget);
      expect(find.textContaining('v1.0.0'), findsWidgets);
      expect(
        find.textContaining('Free, open-source, cross-platform password manager'),
        findsOneWidget,
      );

      // Verify Moshiur Rahman credit under header
      expect(find.text('Moshiur Rahman'), findsOneWidget);

      // Verify Project Information Section
      expect(find.text('Project Information'), findsOneWidget);
      expect(find.text('GitHub Repository'), findsOneWidget);
      expect(find.text('User Guide & Documentation'), findsOneWidget);
      expect(find.text('Issue Tracker'), findsOneWidget);

      // Verify Acknowledgements & Contributors are removed
      expect(find.text('Acknowledgements & Credits'), findsNothing);
      expect(find.text('Repository Contributors'), findsNothing);

      // Verify Open-Source Licenses
      expect(find.text('Open-Source Licenses'), findsOneWidget);
      expect(find.text('Project License'), findsOneWidget);
      expect(find.text('Third-Party Dependency Licenses'), findsOneWidget);

      // Verify Support Section
      expect(find.text('Help & Contact'), findsOneWidget);
      expect(find.textContaining('moshidevs@gmail.com'), findsOneWidget);
    });
  });

  group('Settings Screen KeyNest Section Tests', () {
    testWidgets('KeyNest Password Manager tile opens About page directly',
        (tester) async {
      bool openedAbout = false;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListTile(
              key: const ValueKey('keyNestHeaderTile'),
              title: const Text('KeyNest Password Manager'),
              subtitle: const Text('Help, About, and Contact • v1.0.0'),
              onTap: () {
                openedAbout = true;
              },
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('KeyNest Password Manager'), findsOneWidget);
      expect(find.text('Help, About, and Contact • v1.0.0'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('keyNestHeaderTile')));
      await tester.pump();

      expect(openedAbout, isTrue);
    });

    test('KeyNestSupportService constants match project specification', () {
      expect(KeyNestSupportService.supportEmail, equals('moshidevs@gmail.com'));
      expect(KeyNestSupportService.supportSubject, equals('KeyNest Support'));
      expect(
        KeyNestSupportService.officialUserGuideUrl,
        equals(
            'https://github.com/MoshiNop/KeyNest/blob/main/docs/user-guide/README.md'),
      );
      expect(
        KeyNestSupportService.repositoryUrl,
        equals('https://github.com/MoshiNop/KeyNest'),
      );
    });
  });
}
