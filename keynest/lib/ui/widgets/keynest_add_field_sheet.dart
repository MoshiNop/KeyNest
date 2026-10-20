import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/ui/widgets/keynest_custom_field_sheet.dart';
import 'package:keynest/utils/dialog_utils.dart';

class KeyNestAddFieldResult {
  const KeyNestAddFieldResult({
    required this.key,
    this.isProtected = false,
    this.customKind,
    this.initialValue,
  });

  final KdbxKey key;
  final bool isProtected;
  final CustomFieldKind? customKind;
  final String? initialValue;
}

class KeyNestFieldOption {
  const KeyNestFieldOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    this.fixedKey,
    this.promptLabel,
    this.defaultName,
    this.isProtected = false,
    this.customKind,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final KdbxKey? fixedKey;
  final String? promptLabel;
  final String? defaultName;
  final bool isProtected;
  final CustomFieldKind? customKind;
}

class KeyNestAddFieldSheet extends StatelessWidget {
  const KeyNestAddFieldSheet({super.key});

  static List<KeyNestFieldOption> get fieldOptions => _options;

  static Future<KeyNestAddFieldResult?> show(BuildContext context) async {
    final option = await showModalBottomSheet<KeyNestFieldOption>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => const KeyNestAddFieldSheet(),
    );
    if (option == null || !context.mounted) {
      return null;
    }
    if (option.fixedKey != null) {
      return KeyNestAddFieldResult(
        key: option.fixedKey!,
        isProtected: option.isProtected,
        customKind: option.customKind,
      );
    }
    if (option.customKind == CustomFieldKind.yesNo) {
      final res = await _promptSwitchField(
        context,
        label: option.promptLabel ?? 'Switch Field Label',
        initial: option.defaultName ?? '',
      );
      if (res == null || res.$1.trim().isEmpty) {
        return null;
      }
      return KeyNestAddFieldResult(
        key: KdbxKey(res.$1.trim()),
        isProtected: false,
        customKind: CustomFieldKind.yesNo,
        initialValue: res.$2 ? 'Yes' : 'No',
      );
    }
    final name = await _promptFieldName(
      context,
      label: option.promptLabel ?? 'Field Name',
      initial: option.defaultName ?? '',
    );
    if (name == null || name.trim().isEmpty) {
      return null;
    }
    return KeyNestAddFieldResult(
      key: KdbxKey(name.trim()),
      isProtected: option.isProtected,
      customKind: option.customKind,
    );
  }

  static final List<KeyNestFieldOption> _options = [
    const KeyNestFieldOption(
      title: 'Authenticator (2FA / TOTP)',
      subtitle: 'Live 6-digit verification code token',
      icon: Icons.timer_outlined,
      iconColor: Color(0xFF8B5CF6),
      iconBg: Color(0xFFF3E8FF),
      fixedKey: KdbxKeyCommon.OTP,
      isProtected: true,
      customKind: CustomFieldKind.authenticator,
    ),
    const KeyNestFieldOption(
      title: 'Secret / Hidden Field',
      subtitle: 'Masked value for API keys, recovery phrases',
      icon: Icons.lock_outline_rounded,
      iconColor: KeyNestTokens.primaryAccent,
      iconBg: Color(0xFFD4E3FF),
      promptLabel: 'Field Label (e.g. API Secret, Security Key)',
      defaultName: 'Secret',
      isProtected: true,
      customKind: CustomFieldKind.hidden,
    ),
    KeyNestFieldOption(
      title: 'PIN Code',
      subtitle: 'Numeric security PIN or pass-code',
      icon: Icons.pin_rounded,
      iconColor: const Color(0xFFF59E0B),
      iconBg: const Color(0xFFFEF3C7),
      fixedKey: KdbxKey('PIN'),
      isProtected: true,
      customKind: CustomFieldKind.pin,
    ),
    const KeyNestFieldOption(
      title: 'Text Field',
      subtitle: 'Custom single-line text (e.g. Account Number)',
      icon: Icons.text_fields_rounded,
      iconColor: Color(0xFF3B82F6),
      iconBg: Color(0xFFDBEAFE),
      promptLabel: 'Field Label (e.g. Account No, Member ID)',
      defaultName: 'Custom Field',
      isProtected: false,
      customKind: CustomFieldKind.text,
    ),
    KeyNestFieldOption(
      title: 'Secondary URL / Website',
      subtitle: 'Alternative login or portal address',
      icon: Icons.link_rounded,
      iconColor: const Color(0xFF06B6D4),
      iconBg: const Color(0xFFCFFAFE),
      fixedKey: KdbxKey('URL 2'),
      isProtected: false,
    ),
    const KeyNestFieldOption(
      title: 'Date / Expiration',
      subtitle: 'Renewal date or milestone calendar timestamp',
      icon: Icons.calendar_today_rounded,
      iconColor: Color(0xFF10B981),
      iconBg: Color(0xFFD1FAE5),
      promptLabel: 'Date Field Label (e.g. Expires, Renew Date)',
      defaultName: 'Expires',
      isProtected: false,
      customKind: CustomFieldKind.date,
    ),
    const KeyNestFieldOption(
      title: 'Switch / Boolean',
      subtitle: 'On / off toggle switch for boolean settings',
      icon: Icons.toggle_on_rounded,
      iconColor: Color(0xFF10B981),
      iconBg: Color(0xFFD1FAE5),
      promptLabel: 'Field Label (e.g. 2FA Enabled, Auto-Pay)',
      defaultName: '',
      isProtected: false,
      customKind: CustomFieldKind.yesNo,
    ),
    KeyNestFieldOption(
      title: 'Tags / Labels',
      subtitle: 'Semicolon-separated tags (e.g. Personal; Finance)',
      icon: Icons.tag_rounded,
      iconColor: const Color(0xFFEC4899),
      iconBg: const Color(0xFFFCE7F3),
      fixedKey: KdbxKey('Tags'),
      isProtected: false,
    ),
    const KeyNestFieldOption(
      title: 'Custom Attribute',
      subtitle: 'Enter any custom KeePass attribute name',
      icon: Icons.add_circle_outline_rounded,
      iconColor: Color(0xFF6366F1),
      iconBg: Color(0xFFE0E7FF),
      promptLabel: 'Attribute Name',
      defaultName: '',
      isProtected: false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark
        ? KeyNestPalette.surfaceDark
        : KeyNestPalette.surfaceLight;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(KeyNestShapes.radiusSheet),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.only(top: 14, bottom: 28),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Sheet Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                              .withValues(alpha: isDark ? 0.20 : 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.playlist_add_rounded,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Add Custom Field',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 17,
                          color: isDark
                              ? KeyNestPalette.textPrimaryDark
                              : KeyNestPalette.textPrimaryLight,
                        ),
                      ),
                      Text(
                        'Choose a specialized field type or custom attribute',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),

            // Options list
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  children: _options.map((option) {
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).pop(option);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? (option.iconColor ==
                                                KeyNestTokens.primaryAccent
                                            ? KeyNestTokens.primaryAccent
                                                  .withValues(alpha: 0.18)
                                            : option.iconColor.withValues(
                                                alpha: 0.18,
                                              ))
                                      : (option.iconColor ==
                                                KeyNestTokens.primaryAccent
                                            ? KeyNestTokens.lightPrimary
                                                  .withValues(alpha: 0.12)
                                            : option.iconBg),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  option.icon,
                                  color:
                                      (!isDark &&
                                          option.iconColor ==
                                              KeyNestTokens.primaryAccent)
                                      ? KeyNestTokens.lightPrimary
                                      : option.iconColor,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      option.title,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15,
                                            color: isDark
                                                ? KeyNestPalette.textPrimaryDark
                                                : KeyNestPalette
                                                      .textPrimaryLight,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      option.subtitle,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            fontSize: 12,
                                            color: isDark
                                                ? KeyNestPalette
                                                      .textSecondaryDark
                                                : KeyNestPalette
                                                      .textSecondaryLight,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 20,
                                color: isDark
                                    ? KeyNestPalette.textSecondaryDark
                                    : KeyNestPalette.textSecondaryLight,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Future<String?> _promptFieldName(
    BuildContext context, {
    required String label,
    required String initial,
  }) async {
    final controller = TextEditingController(text: initial);
    if (initial.isNotEmpty) {
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: initial.length,
      );
    }
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return showDialog<String>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isValid = controller.text.trim().isNotEmpty;
            return AlertDialog(
              clipBehavior: Clip.antiAlias,
              backgroundColor: isDark
                  ? KeyNestPalette.cardDark
                  : KeyNestPalette.cardLight,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
              ),
              insetPadding: KeyNestDialogDefaults.insetPadding,
              actionsOverflowDirection: VerticalDirection.down,
              title: KeyNestDialogTitle(
                title: label,
              ),
              content: SingleChildScrollView(
                child: TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Enter name',
                  filled: true,
                  fillColor: isDark
                      ? KeyNestPalette.surfaceDark
                      : KeyNestPalette.surfaceLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (_) => setDialogState(() {}),
                onSubmitted: (val) {
                  final trimmed = val.trim();
                  if (trimmed.isNotEmpty) {
                    Navigator.of(dialogCtx).pop(trimmed);
                  }
                },
              ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(null),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                    foregroundColor: isDark
                        ? const Color(0xFF00315D)
                        : Colors.white,
                    disabledBackgroundColor: isDark
                        ? Colors.white12
                        : Colors.black12,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: isValid
                      ? () =>
                            Navigator.of(dialogCtx).pop(controller.text.trim())
                      : null,
                  child: const Text('Add Field'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static Future<(String, bool)?> _promptSwitchField(
    BuildContext context, {
    required String label,
    required String initial,
  }) async {
    final controller = TextEditingController(text: initial);
    bool isTrue = false;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return showDialog<(String, bool)>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isValid = controller.text.trim().isNotEmpty;
            return AlertDialog(
              clipBehavior: Clip.antiAlias,
              backgroundColor: isDark
                  ? KeyNestPalette.cardDark
                  : KeyNestPalette.cardLight,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
              ),
              insetPadding: KeyNestDialogDefaults.insetPadding,
              actionsOverflowDirection: VerticalDirection.down,
              actionsPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              title: KeyNestDialogTitle(
                title: 'Add Switch Field',
                icon: Icons.toggle_on_rounded,
                iconColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: label,
                        hintText: 'e.g. 2FA Enabled, Auto-Pay',
                        filled: true,
                        fillColor: isDark
                            ? KeyNestPalette.surfaceDark
                            : KeyNestPalette.surfaceLight,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? KeyNestPalette.surfaceDark
                            : KeyNestPalette.surfaceLight,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isDark
                              ? KeyNestPalette.cardBorderDark
                              : KeyNestPalette.cardBorderLight,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            isTrue ? 'State: On' : 'State: Off',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            isTrue ? 'Enabled' : 'Disabled',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                          value: isTrue,
                          activeThumbColor: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          onChanged: (val) {
                            setDialogState(() {
                              isTrue = val;
                            });
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(null),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                    foregroundColor: isDark
                        ? const Color(0xFF00315D)
                        : Colors.white,
                    disabledBackgroundColor: isDark
                        ? Colors.white12
                        : Colors.black12,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: isValid
                      ? () => Navigator.of(dialogCtx).pop(
                          (controller.text.trim(), isTrue),
                        )
                      : null,
                  child: const Text('Add Field'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
