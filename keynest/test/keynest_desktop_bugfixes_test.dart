import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/anchored_popover.dart';
import 'package:keynest/ui/screens/password_list.dart';
import 'package:keynest/ui/widgets/keynest_chips.dart';
import 'package:keynest/ui/widgets/keynest_empty_state.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:mockito/mockito.dart';

import 'util/test_util.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KeyNest Desktop Bugfixes Verification Tests', () {
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
        uuid: 'vault-uuid-test',
        databaseName: 'Vault',
      );

      mockBloc = MockKdbxBloc();
      when(mockBloc.openedFilesKdbx).thenReturn([kdbxFile]);
      when(mockBloc.openedFilesWithSources).thenReturn([
        MapEntry(dummySource, kdbxFile),
      ]);
    });

    test('Bug 1: Item deletion immediately updates isEntryInTrash without stale cache', () {
      final root = kdbxFile.body.rootGroup;
      final entry = KdbxEntry.create(kdbxFile, root);
      root.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Test Card'));
      KeyNestItemTypeHelper.setItemType(entry, KeyNestItemType.card);

      // Verify active state initially
      expect(KeyNestItemTypeHelper.isEntryInTrash(entry), isFalse);

      // Perform deletion
      kdbxFile.deleteEntry(entry);
      KeyNestItemTypeHelper.invalidateCache(entry);

      // Verify that deletion is reflected instantly without restarting app or caching stale false
      expect(KeyNestItemTypeHelper.isEntryInTrash(entry), isTrue);

      // Test permanent deletion
      kdbxFile.deletePermanently(entry);
      KeyNestItemTypeHelper.invalidateCache(entry);
      expect(KeyNestItemTypeHelper.isEntryInTrash(entry), isTrue);
    });

    test('Bug 1 & 3: KeyNestVaultScope notifies listeners on chip state changes and updates immediately', () {
      final scope = KeyNestVaultScope.instance;
      bool notified = false;
      void listener() {
        notified = true;
      }

      scope.addListener(listener);

      // Toggle favorites
      notified = false;
      scope.setFavoritesOnly(true);
      expect(notified, isTrue);
      expect(scope.favoritesOnly, isTrue);

      // Toggle category
      notified = false;
      scope.setSelectedCategory('Finance');
      expect(notified, isTrue);
      expect(scope.selectedCategory, equals('Finance'));

      // Change sort mode
      notified = false;
      scope.setSortMode(VaultSortMode.lastModified);
      expect(notified, isTrue);
      expect(scope.sortMode, equals(VaultSortMode.lastModified));

      // Reset
      scope.setFavoritesOnly(false);
      scope.setSelectedCategory(null);
      scope.setSortMode(VaultSortMode.alphabeticalAsc);
      scope.removeListener(listener);
    });

    testWidgets('Bug 3: KeyNestChip selection updates immediately on rebuild', (tester) async {
      bool isSelected = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return KeyNestChip(
                  label: 'Favorites',
                  icon: Icons.star_rounded,
                  isSelected: isSelected,
                  onTap: () {
                    setState(() {
                      isSelected = !isSelected;
                    });
                  },
                );
              },
            ),
          ),
        ),
      );

      // Initially unselected
      expect(find.byIcon(Icons.check_rounded), findsNothing);

      // Tap chip
      await tester.tap(find.byType(KeyNestChip));
      await tester.pumpAndSettle();

      // Now selected with checkmark
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('Bug 2: showAnchoredPopover opens directly adjacent to anchor without throwing', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: keyNestDarkTheme,
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (ctx) {
                  return ElevatedButton(
                    onPressed: () {
                      showAnchoredPopover<void>(
                        anchorContext: ctx,
                        width: 300,
                        builder: (popCtx) => const SizedBox(
                          height: 150,
                          child: Text('Popover Content'),
                        ),
                      );
                    },
                    child: const Text('Open Popover'),
                  );
                },
              ),
            ),
          ),
        ),
      );

      // Tap button to open popover
      await tester.tap(find.text('Open Popover'));
      await tester.pumpAndSettle();

      expect(find.text('Popover Content'), findsOneWidget);

      // Dismiss by tapping outside
      await tester.tapAt(const Offset(50, 50));
      await tester.pumpAndSettle();

      expect(find.text('Popover Content'), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('Bug 2: showAnchoredPopover with centerOnAnchor opens centered directly on the anchor', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));

      late BuildContext buttonCtx;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: keyNestDarkTheme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.center,
              child: SizedBox(
                width: 400,
                height: 60,
                child: Builder(
                  builder: (ctx) {
                    buttonCtx = ctx;
                    return ElevatedButton(
                      onPressed: () {
                        showAnchoredPopover<void>(
                          anchorContext: ctx,
                          width: 320,
                          centerOnAnchor: true,
                          builder: (popCtx) => const SizedBox(
                            key: ValueKey('popover_box'),
                            width: 320,
                            height: 160,
                            child: Text('Centered Content'),
                          ),
                        );
                      },
                      child: const Text('Open Centered Popover'),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );

      final buttonRenderBox = buttonCtx.findRenderObject() as RenderBox;
      final buttonCenter = buttonRenderBox.localToGlobal(Offset(buttonRenderBox.size.width / 2, buttonRenderBox.size.height / 2));

      await tester.tap(find.text('Open Centered Popover'));
      await tester.pumpAndSettle();

      expect(find.text('Centered Content'), findsOneWidget);

      final popoverFinder = find.byKey(const ValueKey('popover_box'));
      final popoverCenter = tester.getCenter(popoverFinder);

      expect(popoverCenter.dx, closeTo(buttonCenter.dx, 1.0));
      expect(popoverCenter.dy, closeTo(buttonCenter.dy, 1.0));

      // Dismiss
      await tester.tapAt(const Offset(50, 50));
      await tester.pumpAndSettle();

      expect(find.text('Centered Content'), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('Bug 5: KeyNestEmptyState renders instantly on desktop without 0.0 opacity flash', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: keyNestDarkTheme,
          home: const Scaffold(
            body: KeyNestEmptyState(
              type: EmptyStateType.records,
              actionLabel: 'Add Record',
            ),
          ),
        ),
      );

      // Check that it renders immediately
      expect(find.text('No records'), findsOneWidget);
      expect(find.text('Items will appear here once added'), findsOneWidget);
      // No blank 0-opacity TweenAnimationBuilder
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    });
  });
}
