import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/ui/screens/keynest_cloud_vault_browser_screen.dart';
import 'package:keynest/ui/screens/main_app_scaffold.dart';
import 'package:keynest/ui/widgets/keynest_custom_field_sheet.dart';
import 'package:keynest/utils/dialog_utils.dart';

Widget _buildTestApp({
  required Widget child,
  ThemeMode themeMode = ThemeMode.dark,
  Size screenSize = const Size(360, 640),
  EdgeInsets viewInsets = EdgeInsets.zero,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: keyNestLightTheme,
    darkTheme: keyNestDarkTheme,
    themeMode: themeMode,
    home: MediaQuery(
      data: MediaQueryData(
        size: screenSize,
        viewInsets: viewInsets,
      ),
      child: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dialog Responsive Layout & Overflow Tests', () {
    testWidgets(
      'ss1: Add Switch / Boolean Field dialog renders cleanly on narrow screen with keyboard',
      (tester) async {
        tester.view.physicalSize = const Size(320 * 2, 600 * 2);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          _buildTestApp(
            screenSize: const Size(320, 600),
            viewInsets: const EdgeInsets.only(bottom: 260),
            child: Builder(
              builder: (context) {
                return Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () {
                        KeyNestCustomFieldSheet.promptAddField(
                          context,
                          initialKind: CustomFieldKind.yesNo,
                        );
                      },
                      child: const Text('Open Switch Dialog'),
                    ),
                  ),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('Open Switch Dialog'));
        await tester.pumpAndSettle();

        // Verify title text fits and KeyNestDialogTitle exists
        expect(find.text('Add Switch / Boolean Field'), findsOneWidget);
        expect(find.byType(KeyNestDialogTitle), findsOneWidget);
        expect(find.byIcon(Icons.toggle_on_rounded), findsOneWidget);

        // Verify input field, switch tile, and actions are rendered
        expect(find.text('Field Name'), findsOneWidget);
        expect(find.text('State: Off'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Add'), findsOneWidget);

        // Toggle switch state
        await tester.tap(find.byType(SwitchListTile));
        await tester.pumpAndSettle();
        expect(find.text('State: On'), findsOneWidget);

        // Ensure no RenderFlex overflow
        expect(tester.takeException(), isNull);

        // Dismiss dialog
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'ss2: Add Authenticator (2FA) dialog renders cleanly without title overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320 * 2, 600 * 2);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          _buildTestApp(
            screenSize: const Size(320, 600),
            viewInsets: const EdgeInsets.only(bottom: 260),
            child: Builder(
              builder: (context) {
                return Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () {
                        KeyNestCustomFieldSheet.promptAddField(
                          context,
                          initialKind: CustomFieldKind.authenticator,
                        );
                      },
                      child: const Text('Open 2FA Dialog'),
                    ),
                  ),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('Open 2FA Dialog'));
        await tester.pumpAndSettle();

        // Verify title text matches Add Authenticator (2FA) and does not overflow
        expect(find.text('Add Authenticator (2FA)'), findsOneWidget);
        expect(find.byType(KeyNestDialogTitle), findsOneWidget);
        expect(find.byIcon(Icons.timer_outlined), findsOneWidget);

        // Verify inputs - Authenticator does not ask for Field Name per simplified creation
        expect(find.text('Field Name'), findsNothing);
        expect(find.text('Secret Key (TOTP)'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Add'), findsOneWidget);

        // Verify no RenderFlex overflow occurred
        expect(tester.takeException(), isNull);

        // Dismiss dialog
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'ss3: Delete Selected Vaults dialog scrolls and supports multiple vaults without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(340 * 2, 500 * 2);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final mockVaults = List.generate(
          8,
          (i) => CloudVaultItem(
            id: 'vault_$i',
            name: 'personal_backup_vault_${i + 1}_very_long_storage_filename.kdbx',
            sizeBytes: 1024 * 1024 * (i + 1) * 3,
            modifiedTime: DateTime.now(),
            isLinked: false,
          ),
        );

        bool? userConfirmed;

        await tester.pumpWidget(
          _buildTestApp(
            screenSize: const Size(340, 500),
            child: Builder(
              builder: (context) {
                return Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            clipBehavior: Clip.antiAlias,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                KeyNestTokens.radiusDialog,
                              ),
                            ),
                            insetPadding: KeyNestDialogDefaults.insetPadding,
                            actionsOverflowDirection: VerticalDirection.down,
                            title: const KeyNestDialogTitle(
                              title: 'Delete Selected Vaults?',
                              icon: Icons.warning_amber_rounded,
                              iconColor: KeyNestTokens.error,
                            ),
                            content: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Are you sure you want to permanently delete ${mockVaults.length} vaults from Google Drive?',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: KeyNestTokens.error.withValues(
                                        alpha: 0.1,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: KeyNestTokens.error.withValues(
                                          alpha: 0.3,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        ...mockVaults.map(
                                          (v) => Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 4,
                                            ),
                                            child: Text(
                                              '• ${v.name} (${v.formattedSize})',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              softWrap: true,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        const Text(
                                          'WARNING: This action deletes the files directly from your cloud storage. '
                                          'This operation cannot be undone through KeyNest.',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: KeyNestTokens.error,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          softWrap: true,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(false),
                                child: const Text('Cancel'),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: KeyNestTokens.error,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: () => Navigator.of(ctx).pop(true),
                                child: const Text('Delete from Cloud'),
                              ),
                            ],
                          ),
                        );
                        userConfirmed = confirmed;
                      },
                      child: const Text('Open Delete Dialog'),
                    ),
                  ),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('Open Delete Dialog'));
        await tester.pumpAndSettle();

        // Verify title & warning icon
        expect(find.text('Delete Selected Vaults?'), findsOneWidget);
        expect(find.byType(KeyNestDialogTitle), findsOneWidget);
        expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

        // Verify SingleChildScrollView exists to handle large multiple vault list
        expect(find.byType(SingleChildScrollView), findsOneWidget);

        // Verify destructive action buttons
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Delete from Cloud'), findsOneWidget);

        // Ensure zero RenderFlex overflow even with 8 vaults in 500px height
        expect(tester.takeException(), isNull);

        // Tap Delete from Cloud and verify confirmation returned true
        await tester.tap(find.text('Delete from Cloud'));
        await tester.pumpAndSettle();
        expect(userConfirmed, isTrue);
      },
    );

    testWidgets(
      'KeyNestDialogTitle handles long titles without overflowing dialog bounds',
      (tester) async {
        await tester.pumpWidget(
          _buildTestApp(
            screenSize: const Size(300, 400),
            child: const Scaffold(
              body: AlertDialog(
                title: KeyNestDialogTitle(
                  title:
                      'Very Extremely Long Dialog Title That Would Definitely Overflow On Narrow Screens Without Proper Flex Constraints',
                  icon: Icons.shield_rounded,
                ),
                content: Text('Content'),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(KeyNestDialogTitle), findsOneWidget);
      },
    );

    testWidgets('MainAppScaffold.route provides smooth PageRouteBuilder', (
      tester,
    ) async {
      final route = MainAppScaffold.route();
      expect(route, isA<PageRouteBuilder<void>>());
      expect(route.settings.name, equals('/main'));
      expect((route as PageRouteBuilder<void>).transitionDuration, equals(const Duration(milliseconds: 180)));
    });
  });
}
