import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/theme.dart';

enum CustomFieldKind {
  text,
  hidden,
  pin,
  date,
  yesNo,
  authenticator,
}

class CustomFieldTypeItem {
  const CustomFieldTypeItem({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final CustomFieldKind kind;
  final String title;
  final String subtitle;
  final IconData icon;
}

class CustomFieldModel {
  CustomFieldModel({
    required this.key,
    required this.value,
    required this.kind,
  });

  String key;
  String value;
  CustomFieldKind kind;
}

class KeyNestCustomFieldSheet extends StatelessWidget {
  const KeyNestCustomFieldSheet({super.key});

  static const List<CustomFieldTypeItem> fieldTypes = [
    CustomFieldTypeItem(
      kind: CustomFieldKind.text,
      title: 'Text',
      subtitle: 'e.g. account number, IFSC, notes',
      icon: Icons.text_fields_rounded,
    ),
    CustomFieldTypeItem(
      kind: CustomFieldKind.hidden,
      title: 'Hidden',
      subtitle: 'masked like a password',
      icon: Icons.lock_outline_rounded,
    ),
    CustomFieldTypeItem(
      kind: CustomFieldKind.pin,
      title: 'PIN',
      subtitle: 'digits only, masked',
      icon: Icons.pin_rounded,
    ),
    CustomFieldTypeItem(
      kind: CustomFieldKind.date,
      title: 'Date',
      subtitle: 'pick a calendar date',
      icon: Icons.calendar_today_rounded,
    ),
    CustomFieldTypeItem(
      kind: CustomFieldKind.yesNo,
      title: 'Switch / Boolean',
      subtitle: 'an on-off switch',
      icon: Icons.toggle_on_rounded,
    ),
    CustomFieldTypeItem(
      kind: CustomFieldKind.authenticator,
      title: 'Authenticator (2FA)',
      subtitle: 'TOTP secret key or token',
      icon: Icons.timer_outlined,
    ),
  ];

  static Future<CustomFieldKind?> show(BuildContext context) {
    return showModalBottomSheet<CustomFieldKind>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => const KeyNestCustomFieldSheet(),
    );
  }

  /// Returns whether [value] represents a boolean true state.
  static bool isTruthy(String? value) {
    if (value == null) {
      return false;
    }
    final lower = value.trim().toLowerCase();
    return lower == 'yes' || lower == 'true' || lower == '1' || lower == 'on';
  }

  /// Converts a boolean [val] to string, preserving original format if available.
  static String boolToString(bool val, {String? originalValue}) {
    if (originalValue != null) {
      final lower = originalValue.trim().toLowerCase();
      if (lower == 'true' || lower == 'false') {
        return val ? 'true' : 'false';
      }
      if (lower == '1' || lower == '0') {
        return val ? '1' : '0';
      }
    }
    return val ? 'Yes' : 'No';
  }

  /// Resolves the authentic [CustomFieldKind] for a given KDBX string entry.
  ///
  /// A field is classified as a boolean switch ONLY if it is explicitly marked
  /// with a supported type marker (e.g. `entry.customData['FieldType_$fieldKey']`).
  /// Standard common fields (Notes, Title, UserName, Password, URL) and ordinary
  /// text fields containing "Yes", "No", "True", or "False" are never converted
  /// into switches.
  static CustomFieldKind resolveFieldKind(
    KdbxEntry entry,
    String fieldKey, {
    String? value,
    bool isProtected = false,
  }) {
    // 1. Built-in standard keys must never be custom switches
    if (fieldKey == 'Notes' ||
        fieldKey == 'Title' ||
        fieldKey == 'UserName' ||
        fieldKey == 'Password' ||
        fieldKey == 'URL') {
      return isProtected ? CustomFieldKind.hidden : CustomFieldKind.text;
    }

    // 2. Explicit field type metadata from customData
    final customDataKind = entry.customData['FieldType_$fieldKey'];
    if (customDataKind != null && customDataKind.isNotEmpty) {
      final cdLower = customDataKind.toLowerCase();
      if (cdLower == 'yesno' ||
          cdLower == 'boolean' ||
          cdLower == 'switch' ||
          cdLower == 'bool') {
        return CustomFieldKind.yesNo;
      }
      for (final k in CustomFieldKind.values) {
        if (k.name.toLowerCase() == cdLower) {
          return k;
        }
      }
    }

    // 3. Fallback for non-switch specialized types (PIN, Date, Authenticator, Hidden)
    // Never infer a switch from text value!
    final lowerKey = fieldKey.toLowerCase();
    if (lowerKey.contains('pin')) {
      return CustomFieldKind.pin;
    }
    if (lowerKey.contains('date') ||
        lowerKey.contains('dob') ||
        lowerKey.contains('expiry') ||
        lowerKey.contains('valid')) {
      return CustomFieldKind.date;
    }
    if (lowerKey.contains('otp') ||
        lowerKey.contains('2fa') ||
        lowerKey.contains('totp') ||
        lowerKey.contains('authenticator')) {
      return CustomFieldKind.authenticator;
    }
    if (isProtected ||
        lowerKey.contains('secret') ||
        lowerKey.contains('pass') ||
        lowerKey.contains('security') ||
        lowerKey.contains('answer')) {
      return CustomFieldKind.hidden;
    }
    return CustomFieldKind.text;
  }

  /// Prompts user to select a field type (if not provided) and enters field name and value.
  static Future<CustomFieldModel?> promptAddField(
    BuildContext context, {
    CustomFieldKind? initialKind,
    CustomFieldModel? existing,
    Set<String>? existingKeys,
  }) async {
    CustomFieldKind? kind = initialKind ?? existing?.kind;
    if (kind == null) {
      kind = await KeyNestCustomFieldSheet.show(context);
      if (kind == null || !context.mounted) {
        return null;
      }
    }

    final nameController = TextEditingController(text: existing?.key ?? '');
    final valueController = TextEditingController(text: existing?.value ?? '');
    bool isYesNoTrue = existing != null && isTruthy(existing.value);
    bool obscureValue =
        kind == CustomFieldKind.hidden || kind == CustomFieldKind.pin;

    DateTime? selectedDate;
    if (kind == CustomFieldKind.date &&
        existing != null &&
        existing.value.isNotEmpty) {
      selectedDate = DateTime.tryParse(existing.value.trim());
    }

    String hintName;
    switch (kind) {
      case CustomFieldKind.text:
        hintName = 'e.g. Account Number, Billing Cycle, IBAN';
        break;
      case CustomFieldKind.hidden:
        hintName = 'e.g. Security Answer, Client Secret';
        break;
      case CustomFieldKind.pin:
        hintName = 'e.g. ATM PIN, Door Code';
        break;
      case CustomFieldKind.date:
        hintName = 'e.g. Issue Date, Renewal Date';
        break;
      case CustomFieldKind.yesNo:
        hintName = 'e.g. Contactless Enabled, Auto Pay';
        break;
      case CustomFieldKind.authenticator:
        hintName = 'e.g. 2FA Secret Key';
        break;
    }

    final typeItem = fieldTypes.firstWhere(
      (t) => t.kind == kind,
      orElse: () => fieldTypes.first,
    );

    return showDialog<CustomFieldModel>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final isDark = Theme.of(ctx).brightness == Brightness.dark;

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Icon(
                    typeItem.icon,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    existing != null
                        ? 'Edit ${typeItem.title} Field'
                        : 'Add ${typeItem.title} Field',
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameController,
                      autofocus: existing == null,
                      decoration: InputDecoration(
                        labelText: 'Field Name',
                        hintText: hintName,
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (kind == CustomFieldKind.yesNo) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
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
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            isYesNoTrue ? 'State: On' : 'State: Off',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            isYesNoTrue ? 'Enabled' : 'Disabled',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                          value: isYesNoTrue,
                          activeThumbColor: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          onChanged: (val) {
                            setDialogState(() {
                              isYesNoTrue = val;
                            });
                          },
                        ),
                      ),
                    ] else if (kind == CustomFieldKind.date) ...[
                      InkWell(
                        onTap: () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: selectedDate ?? now,
                            firstDate: DateTime(1900),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setDialogState(() {
                              selectedDate = picked;
                              final formatted =
                                  '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                              valueController.text = formatted;
                            });
                          }
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Date Value',
                            border: OutlineInputBorder(),
                            suffixIcon: Icon(
                              Icons.calendar_today_rounded,
                              size: 20,
                            ),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                          ),
                          child: Text(
                            valueController.text.isNotEmpty
                                ? valueController.text
                                : 'Tap to pick date (YYYY-MM-DD)',
                            style: TextStyle(
                              color: valueController.text.isNotEmpty
                                  ? (isDark ? Colors.white : Colors.black87)
                                  : Colors.grey,
                            ),
                          ),
                        ),
                      ),
                    ] else ...[
                      TextField(
                        controller: valueController,
                        obscureText: obscureValue,
                        keyboardType: kind == CustomFieldKind.pin
                            ? TextInputType.number
                            : TextInputType.text,
                        inputFormatters: kind == CustomFieldKind.pin
                            ? [FilteringTextInputFormatter.digitsOnly]
                            : null,
                        decoration: InputDecoration(
                          labelText: 'Field Value',
                          hintText: kind == CustomFieldKind.pin
                              ? 'Digits only'
                              : (kind == CustomFieldKind.authenticator
                                    ? 'Base32 secret (e.g. JBSWY3DPEHPK3PXP)'
                                    : 'Value'),
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          suffixIcon:
                              (kind == CustomFieldKind.hidden ||
                                  kind == CustomFieldKind.pin)
                              ? IconButton(
                                  icon: Icon(
                                    obscureValue
                                        ? Icons.visibility_rounded
                                        : Icons.visibility_off_rounded,
                                    size: 20,
                                  ),
                                  onPressed: () {
                                    setDialogState(() {
                                      obscureValue = !obscureValue;
                                    });
                                  },
                                )
                              : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
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
                  ),
                  onPressed: () {
                    final keyName = nameController.text.trim();
                    if (keyName.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('Field name cannot be empty'),
                          duration: Duration(milliseconds: 1500),
                        ),
                      );
                      return;
                    }
                    if (existing == null &&
                        existingKeys != null &&
                        existingKeys.contains(keyName)) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text('Field "$keyName" already exists'),
                          duration: const Duration(milliseconds: 1500),
                        ),
                      );
                      return;
                    }

                    String val;
                    if (kind == CustomFieldKind.yesNo) {
                      val = boolToString(isYesNoTrue, originalValue: existing?.value);
                    } else if (kind == CustomFieldKind.date) {
                      val = valueController.text.trim();
                      if (val.isEmpty && selectedDate != null) {
                        val =
                            '${selectedDate!.year.toString().padLeft(4, '0')}-${selectedDate!.month.toString().padLeft(2, '0')}-${selectedDate!.day.toString().padLeft(2, '0')}';
                      }
                    } else {
                      val = valueController.text.trim();
                    }

                    Navigator.of(ctx).pop(
                      CustomFieldModel(
                        key: keyName,
                        value: val,
                        kind: kind!,
                      ),
                    );
                  },
                  child: Text(existing != null ? 'Update' : 'Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

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
      ),
      padding: const EdgeInsets.symmetric(vertical: 20),
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
                  color: isDark
                      ? KeyNestPalette.cardBorderDark
                      : KeyNestPalette.dividerLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            // Field Types
            ...fieldTypes.map(
              (item) => ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                onTap: () => Navigator.pop(context, item.kind),
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isDark
                        ? KeyNestPalette.primaryContainerDark
                        : KeyNestPalette.primaryContainerLight,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    item.icon,
                    size: 22,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                  ),
                ),
                title: Text(
                  item.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                  ),
                ),
                subtitle: Text(
                  item.subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
