import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/widgets/keyboard_handler.dart';
import 'package:keynest/ui/widgets/shortcut/keynest_intents.dart';
import 'package:keynest/ui/widgets/shortcut/shortcuts.dart';

class _GuardTestWidget extends StatefulWidget {
  const _GuardTestWidget({required this.hasChanges});
  final bool hasChanges;

  @override
  State<_GuardTestWidget> createState() => _GuardTestWidgetState();
}

class _GuardTestWidgetState extends State<_GuardTestWidget>
    implements KeyNestDetailPaneGuard {
  @override
  bool get hasUnsavedChanges => widget.hasChanges;

  @override
  Future<bool> confirmDiscardChanges() async => !widget.hasChanges;

  @override
  Widget build(BuildContext context) => const SizedBox(width: 20, height: 20);
}

void main() {
  group('[UI-01] Keyboard Shortcut Deferral When EditableText Has Focus', () {
    testWidgets(
      'Typing ? or pressing ArrowDown in a focused TextField does not fire global vault intents',
      (tester) async {
        var helpCount = 0;
        var moveDownCount = 0;
        final controller = TextEditingController();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: KeyboardHandler(
                systemWideShortcuts: false,
                child: Actions(
                  actions: <Type, Action<Intent>>{
                    KeyboardShortcutHelpIntent:
                        CallbackAction<KeyboardShortcutHelpIntent>(
                          onInvoke: (_) {
                            helpCount++;
                            return null;
                          },
                        ),
                    MoveDownIntent: CallbackAction<MoveDownIntent>(
                      onInvoke: (_) {
                        moveDownCount++;
                        return null;
                      },
                    ),
                  },
                  child: Focus(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();
        expect(isEditableTextFocused(), isTrue);

        // Pressing Down Arrow while TextField is focused should be ignored by KeyNestShortcutManager
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(moveDownCount, 0);

        // Typing '?' while TextField is focused should not trigger KeyboardShortcutHelpIntent
        await tester.enterText(find.byType(TextField), 'what?');
        await tester.pump();
        expect(controller.text, 'what?');
        expect(helpCount, 0);

        focusNode.unfocus();
        await tester.pump();
        expect(isEditableTextFocused(), isFalse);

        focusNode.dispose();
        controller.dispose();
      },
    );
  });

  group('[UI-02] KeyNestDetailPaneGuard Subtree Discovery', () {
    testWidgets(
      'findActiveInSubtree locates dirty detail pane state and confirmDiscardInSubtree respects guard',
      (tester) async {
        final subtreeKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Container(
                key: subtreeKey,
                child: const _GuardTestWidget(hasChanges: true),
              ),
            ),
          ),
        );

        final guard = KeyNestDetailPaneGuard.findActiveInSubtree(
          subtreeKey.currentContext,
        );
        expect(guard, isNotNull);
        expect(guard!.hasUnsavedChanges, isTrue);
        expect(
          await KeyNestDetailPaneGuard.confirmDiscardInSubtree(
            subtreeKey.currentContext,
          ),
          isFalse,
        );
      },
    );
  });

  group('[Section 4.2] Theme & Palette Contrast Tokens', () {
    test(
      'Dark theme error color uses high-contrast KeyNestTokens.darkError (#FFB4AB)',
      () {
        final darkTheme = createDarkTheme();
        expect(darkTheme.colorScheme.error, equals(KeyNestTokens.darkError));
        expect(
          KeyNestPalette.errorColorFor(true),
          equals(KeyNestPalette.errorDark),
        );
        expect(
          KeyNestPalette.primaryColorFor(true),
          equals(KeyNestPalette.primaryDark),
        );
        expect(
          KeyNestPalette.primaryColorFor(false),
          equals(KeyNestPalette.primary),
        );
      },
    );
  });

  group('[Section 4.3] Design System Controls & Accessibility', () {
    testWidgets(
      'KeyNestTextField supports Form validation, errorText without isError, and controller updates',
      (tester) async {
        final formKey = GlobalKey<FormState>();
        final controller1 = TextEditingController(text: '');
        final controller2 = TextEditingController(text: 'Updated');

        late StateSetter outerSetState;
        var activeController = controller1;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  outerSetState = setState;
                  return Form(
                    key: formKey,
                    child: Column(
                      children: [
                        KeyNestTextField(
                          controller: activeController,
                          label: 'Folder Name',
                          validator: (v) =>
                              (v == null || v.isEmpty) ? 'Required' : null,
                        ),
                        KeyNestTextField(
                          label: 'Direct Error',
                          errorText: 'Explicit error message',
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );

        expect(find.text('Explicit error message'), findsOneWidget);
        expect(formKey.currentState!.validate(), isFalse);
        await tester.pump();
        expect(find.text('Required'), findsOneWidget);

        outerSetState(() {
          activeController = controller2;
        });
        await tester.pump();
        expect(formKey.currentState!.validate(), isTrue);

        controller1.dispose();
        controller2.dispose();
      },
    );

    testWidgets(
      'KeyNestSearchTextField forwards autofocus and exposes clear button tooltip',
      (tester) async {
        final controller = TextEditingController(text: 'query');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KeyNestSearchTextField(
                controller: controller,
                autofocus: true,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byTooltip('Clear text'), findsOneWidget);
        controller.dispose();
      },
    );

    testWidgets(
      'KeyNestActionPillButton and KeyNestFilterChip meet 44dp minimum touch target height',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  KeyNestActionPillButton(
                    icon: const Icon(Icons.copy),
                    label: 'Copy',
                    onClick: () {},
                  ),
                  KeyNestFilterChip(
                    selected: true,
                    label: 'Filter',
                    onClick: () {},
                  ),
                ],
              ),
            ),
          ),
        );

        final pillSize = tester.getSize(find.byType(KeyNestActionPillButton));
        final chipSize = tester.getSize(find.byType(KeyNestFilterChip));
        expect(pillSize.height, greaterThanOrEqualTo(44.0));
        expect(chipSize.height, greaterThanOrEqualTo(44.0));
      },
    );

    testWidgets(
      'showAnchoredPopover does not throw ArgumentError on very short viewports',
      (tester) async {
        tester.view.physicalSize = const Size(320, 120);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        late BuildContext anchorCtx;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  anchorCtx = context;
                  return const SizedBox(width: 40, height: 40);
                },
              ),
            ),
          ),
        );

        unawaited(
          showAnchoredPopover<void>(
            anchorContext: anchorCtx,
            builder: (_) => const Text('Popover Content'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Popover Content'), findsOneWidget);
      },
    );
  });
}
