import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/ui/widgets/shortcut/keynest_intents.dart';
import 'package:keynest/utils/constants.dart';

typedef LabelProvider = String Function(AppLocalizations loc);

final defaultKeyNestShortcuts = [
  KeyNestShortcut.def(
    key: LogicalKeyboardKey.keyF,
    intent: const SearchIntent(),
    label: (loc) => loc.searchButtonLabel,
  ),
  KeyNestShortcut.def(
    key: LogicalKeyboardKey.keyB,
    intent: CopyUsernameIntent(),
    label: (loc) => loc.shortcutCopyUsername,
  ),
  KeyNestShortcut.def(
    key: LogicalKeyboardKey.keyC,
    intent: CopyPasswordIntent(),
    label: (loc) => loc.shortcutCopyPassword,
  ),
  KeyNestShortcut.def(
    key: LogicalKeyboardKey.keyT,
    intent: CopyTotpIntent(),
    label: (loc) => loc.shortcutCopyTotp,
  ),
  KeyNestShortcut.all(
    key: const SingleActivator(LogicalKeyboardKey.arrowUp),
    intent: MoveUpIntent(),
    label: (loc) => loc.shortcutMoveUp,
  ),
  KeyNestShortcut.all(
    key: const SingleActivator(LogicalKeyboardKey.keyP, control: true),
    intent: MoveUpIntent(),
    label: (loc) => loc.shortcutMoveUp,
  ),
  KeyNestShortcut.all(
    key: const SingleActivator(LogicalKeyboardKey.arrowDown),
    intent: MoveDownIntent(),
    label: (loc) => loc.shortcutMoveDown,
  ),
  KeyNestShortcut.all(
    key: const SingleActivator(LogicalKeyboardKey.keyN, control: true),
    intent: MoveDownIntent(),
    label: (loc) => loc.shortcutMoveDown,
  ),
  KeyNestShortcut.def(
    key: LogicalKeyboardKey.keyG,
    intent: GeneratePasswordIntent(),
    label: (loc) => loc.shortcutGeneratePassword,
  ),
  KeyNestShortcut.def(
    key: LogicalKeyboardKey.keyU,
    intent: CopyUrlIntent(),
    label: (loc) => loc.shortcutCopyUrl,
  ),
  KeyNestShortcut.def(
    key: LogicalKeyboardKey.keyO,
    intent: OpenUrlIntent(),
    label: (loc) => loc.shortcutOpenUrl,
  ),
  KeyNestShortcut.all(
    key: const SingleActivator(LogicalKeyboardKey.escape),
    intent: CancelSearchFilterIntent(),
    label: (loc) => loc.shortcutCancelSearch,
  ),
  KeyNestShortcut.all(
    key: const CharacterActivator(CharConstants.questionMark),
    intent: KeyboardShortcutHelpIntent(),
    label: (loc) => loc.shortcutShortcutHelp,
  ),
];

class KeyNestShortcut {
  const KeyNestShortcut({
    required this.mac,
    required this.linux,
    required this.windows,
    required this.intent,
    required this.label,
  });
  KeyNestShortcut.def({
    required LogicalKeyboardKey key,
    required Intent intent,
    required LabelProvider label,
  }) : this(
         mac: SingleActivator(key, meta: true),
         linux: SingleActivator(key, control: true),
         windows: SingleActivator(key, control: true),
         intent: intent,
         label: label,
       );
  KeyNestShortcut.all({
    required ShortcutActivator key,
    required Intent intent,
    required LabelProvider label,
  }) : this(
         mac: key,
         linux: key,
         windows: key,
         intent: intent,
         label: label,
       );

  final ShortcutActivator mac;
  final ShortcutActivator linux;
  final ShortcutActivator windows;
  final Intent intent;
  final LabelProvider label;

  ShortcutActivator triggerForPlatform(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
        return linux;
      case TargetPlatform.iOS:
        return mac;
      case TargetPlatform.macOS:
        return mac;
      case TargetPlatform.windows:
        return windows;
    }
  }
}
