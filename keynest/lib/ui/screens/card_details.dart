import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/add_payment_card.dart';
import 'package:keynest/ui/screens/group_list.dart';
import 'package:keynest/ui/widgets/keynest_custom_field_sheet.dart';
import 'package:keynest/ui/widgets/keynest_password_history_sheet.dart';
import 'package:keynest/ui/widgets/keynest_payment_card.dart';
import 'package:keynest/ui/widgets/keynest_popup_menu.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:provider/provider.dart';

class CardDetailsScreen extends StatefulWidget {
  const CardDetailsScreen({super.key, required this.entry});

  static Route<void> route({required KdbxEntry entry}) => KeyNestPageRoute(
    settings: const RouteSettings(name: '/cardDetails'),
    builder: (context) => CardDetailsScreen(entry: entry),
  );

  final KdbxEntry entry;

  @override
  State<CardDetailsScreen> createState() => _CardDetailsScreenState();
}

class _CardDetailsScreenState extends State<CardDetailsScreen> {
  bool _showNumber = false;
  bool _showCvv = false;
  bool _showPin = false;
  final Set<String> _revealedCustomFields = <String>{};

  Future<KdbxGroup?> _showMoveToGroup(KdbxEntry entry) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final newGroup = (await Navigator.of(context).push(
      GroupListFlat.route(
        {if (entry.parent != null) entry.parent!},
        groupListMode: GroupListMode.singleSelect,
      ),
    ))?.firstOrNull;
    if (newGroup != null && newGroup != entry.parent) {
      if (!mounted) {
        return null;
      }
      final isCrossVault = newGroup.file != entry.file;
      final moved = await KeyNestItemTypeHelper.promptAndMoveOrCopyEntry(
        context: context,
        entry: entry,
        targetGroup: newGroup,
        kdbxBloc: kdbxBloc,
      );
      if (mounted) {
        if (moved && isCrossVault) {
          Navigator.of(context).pop();
        } else {
          setState(() {});
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text('Placed in "${newGroup.name.get() ?? 'Folder'}"'),
                duration: const Duration(milliseconds: 2000),
              ),
            );
        }
      }
    }
    return newGroup;
  }

  Future<void> _showDuplicateToGroup(KdbxEntry entry) async {
    final kdbxBloc = context.read<KdbxBloc>();
    final targetGroup = (await Navigator.of(context).push(
      GroupListFlat.route(
        {if (entry.parent != null) entry.parent!},
        groupListMode: GroupListMode.singleSelect,
      ),
    ))?.firstOrNull;
    if (targetGroup != null && mounted) {
      final cloned = await KeyNestItemTypeHelper.copyEntryToGroup(
        sourceEntry: entry,
        targetGroup: targetGroup,
        kdbxBloc: kdbxBloc,
      );
      if (mounted) {
        final targetVaultName = KeyNestVaultScope.cleanVaultName(
          kdbxBloc,
          targetGroup.file,
        );
        final targetFolderName = targetGroup.name.get() ?? 'Folder';
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'Duplicated "${cloned.label ?? 'Card'}" into $targetVaultName » $targetFolderName',
              ),
              duration: const Duration(milliseconds: 2000),
            ),
          );
      }
    }
  }

  void _copyToClipboard(String label, String value) {
    if (value.isEmpty) {
      return;
    }
    HapticFeedback.lightImpact();
    final isSensitive =
        label == 'Card Number' ||
        label == 'CVV' ||
        label == 'PIN' ||
        KeyNestItemTypeHelper.isSensitiveFieldKey(label);
    if (isSensitive) {
      SecurityService.copySensitive(context, value, label: label);
    } else {
      SecurityService.copyNonSensitive(context, value, label: label);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final entry = widget.entry;

    final title = entry.label?.isNotEmpty == true
        ? entry.label!
        : 'Card Details';
    final holder = entry.getString(KdbxKey('Cardholder'))?.getText() ?? '';
    final number = entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
    final expiry = entry.getString(KdbxKey('Expiry'))?.getText() ?? '';
    final cvv = entry.getString(KdbxKey('CVV'))?.getText() ?? '';
    final pin = entry.getString(KdbxKey('PIN'))?.getText() ?? '';
    final network = entry.getString(KdbxKey('Network'))?.getText() ?? 'Auto';

    final colorHex = entry.getString(KdbxKey('CardColorHex'))?.getText();
    final cardColor = KeyNestPaymentCardView.parseCardColor(colorHex);

    final finishStr = entry.getString(KdbxKey('CardFinish'))?.getText();
    final finish = CardFinish.values.firstWhere(
      (f) => f.name == finishStr,
      orElse: () => CardFinish.matte,
    );

    final secColorHex = entry
        .getString(KdbxKey('CardSecondaryColorHex'))
        ?.getText();
    final defaultSec =
        Color.lerp(cardColor, Colors.black, 0.35) ?? const Color(0xFF0F172A);
    final secondaryColor = secColorHex != null && secColorHex.isNotEmpty
        ? KeyNestPaymentCardView.parseCardColor(secColorHex, defaultSec)
        : defaultSec;

    final gradientStr = entry.getString(KdbxKey('CardGradient'))?.getText();
    final gradientDirection = GradientDirection.values.firstWhere(
      (g) => g.name == gradientStr,
      orElse: () => GradientDirection.diagonal,
    );

    final orientationStr = entry
        .getString(KdbxKey('CardOrientation'))
        ?.getText();
    final orientation = CardOrientation.values.firstWhere(
      (o) => o.name == orientationStr,
      orElse: () => CardOrientation.landscape,
    );

    final namePosStr = entry.getString(KdbxKey('CardNamePos'))?.getText();
    final namePosition = NamePosition.values.firstWhere(
      (p) => p.name == namePosStr,
      orElse: () => NamePosition.left,
    );

    // Format card number for display
    final cleanNumber = number.replaceAll(RegExp(r'\D'), '');
    final formattedNumber = cleanNumber
        .replaceAllMapped(
          RegExp(r'.{4}'),
          (match) => '${match.group(0)} ',
        )
        .trim();

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        actions: [
          // Edit Button
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            icon: const Icon(Icons.edit_rounded, size: 18),
            label: const Text(
              'Edit',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            onPressed: () async {
              await Navigator.of(context).push(
                AddPaymentCardScreen.route(existingEntry: widget.entry),
              );
              if (mounted) {
                setState(() {});
              }
            },
          ),
          // Delete Popup Menu
          KeyNestPopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (val) async {
              if (val == 'move') {
                await _showMoveToGroup(widget.entry);
              } else if (val == 'duplicate') {
                await _showDuplicateToGroup(widget.entry);
              } else if (val == 'delete') {
                final kdbxBloc = context.read<KdbxBloc>();
                final navigator = Navigator.of(context);
                final scaffoldMessenger = ScaffoldMessenger.of(context);
                final confirm = await DialogUtils.showConfirmDialog(
                  context: context,
                  params: ConfirmDialogParams(
                    title: 'Delete Card',
                    content:
                        'Are you sure you want to delete this payment card?',
                    positiveButtonText: 'Delete',
                  ),
                );
                if (confirm == true && mounted) {
                  if (KeyNestItemTypeHelper.isEntryInTrash(widget.entry)) {
                    widget.entry.file.deletePermanently(widget.entry);
                  } else {
                    widget.entry.file.deleteEntry(widget.entry);
                  }
                  await kdbxBloc.saveFile(widget.entry.file);
                  if (mounted) {
                    navigator.pop();
                    scaffoldMessenger.clearSnackBars();
                    scaffoldMessenger.showSnackBar(
                      const SnackBar(
                        content: Text('Card deleted successfully'),
                        duration: Duration(milliseconds: 1800),
                      ),
                    );
                  }
                }
              } else if (val == 'history') {
                await KeyNestPasswordHistorySheet.show(context, widget.entry);
                if (mounted) {
                  setState(() {});
                }
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'move',
                child: Row(
                  children: [
                    Icon(Icons.drive_file_move_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Move to Folder'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'duplicate',
                child: Row(
                  children: [
                    Icon(Icons.copy_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Duplicate'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline_rounded,
                      color: KeyNestPalette.error,
                      size: 20,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Delete',
                      style: TextStyle(color: KeyNestPalette.error),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'history',
                child: Row(
                  children: [
                    const Icon(Icons.history_rounded, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      widget.entry.history.isNotEmpty
                          ? 'History (${widget.entry.history.length})'
                          : 'History',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: KeyNestTokens.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              // Interactive Card Visual Preview
              Center(
                child: KeyNestPaymentCardView(
                  cardholderName: holder.isNotEmpty
                      ? holder
                      : 'CARDHOLDER NAME',
                  cardNumber: _showNumber
                      ? (formattedNumber.isNotEmpty
                            ? formattedNumber
                            : '•••• •••• •••• ••••')
                      : (cleanNumber.length >= 4
                            ? '•••• •••• •••• ${cleanNumber.substring(cleanNumber.length - 4)}'
                            : '•••• •••• •••• ••••'),
                  expiry: expiry.isNotEmpty ? expiry : 'MM/YY',
                  cardNetwork: network,
                  cardColor: cardColor,
                  secondaryColor: secondaryColor,
                  finish: finish,
                  gradientDirection: gradientDirection,
                  orientation: orientation,
                  namePosition: namePosition,
                  isMasked: !_showNumber,
                  onToggleMask: () =>
                      setState(() => _showNumber = !_showNumber),
                ),
              ),
              const SizedBox(height: 28),

              // Information Section Header
              Text(
                'Card Information',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 12),

              // Folder location tile
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? KeyNestPalette.surfaceContainerDark
                      : KeyNestPalette.surfaceLight,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? KeyNestPalette.entryBorderDark
                        : KeyNestPalette.entryBorderLight,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_rounded,
                      size: 18,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.lightIcon,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Folder / Group',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                          Text(
                            entry.parent?.name.get() ?? 'Root Group',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? KeyNestPalette.textPrimaryDark
                                  : KeyNestPalette.textPrimaryLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => _showMoveToGroup(entry),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                      child: const Text(
                        'Move',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Cardholder Name Tile
              _InfoTile(
                label: 'Cardholder Name',
                value: holder.isNotEmpty ? holder : 'Not specified',
                icon: Icons.person_outline_rounded,
                onCopy: holder.isNotEmpty
                    ? () => _copyToClipboard('Cardholder name', holder)
                    : null,
              ),
              const SizedBox(height: 10),

              // Card Number Tile (with show/hide and copy)
              _InfoTile(
                label: 'Card Number',
                value: _showNumber
                    ? (formattedNumber.isNotEmpty ? formattedNumber : '••••')
                    : (cleanNumber.length >= 4
                          ? '•••• •••• •••• ${cleanNumber.substring(cleanNumber.length - 4)}'
                          : '•••• •••• •••• ••••'),
                icon: Icons.credit_card_rounded,
                isMonospace: true,
                onToggleVisibility: () =>
                    setState(() => _showNumber = !_showNumber),
                isMasked: !_showNumber,
                onCopy: cleanNumber.isNotEmpty
                    ? () => _copyToClipboard('Card number', cleanNumber)
                    : null,
              ),
              const SizedBox(height: 10),

              // Expiry & CVV Row (Responsive flex to ensure CVV is never clipped or truncated)
              LayoutBuilder(
                builder: (context, constraints) {
                  final isVeryNarrow = constraints.maxWidth < 340;
                  if (isVeryNarrow) {
                    return Column(
                      children: [
                        _InfoTile(
                          label: 'Expiry Date',
                          value: expiry.isNotEmpty ? expiry : 'MM/YY',
                          icon: Icons.calendar_today_rounded,
                          isMonospace: true,
                          onCopy: expiry.isNotEmpty
                              ? () => _copyToClipboard('Expiry date', expiry)
                              : null,
                        ),
                        const SizedBox(height: 10),
                        _InfoTile(
                          label: 'CVV / CVC',
                          value: _showCvv
                              ? (cvv.isNotEmpty ? cvv : '•••')
                              : (cvv.isNotEmpty ? '•' * cvv.length : '•••'),
                          icon: Icons.security_rounded,
                          isMonospace: true,
                          onToggleVisibility: () =>
                              setState(() => _showCvv = !_showCvv),
                          isMasked: !_showCvv,
                          onCopy: cvv.isNotEmpty
                              ? () => _copyToClipboard('CVV', cvv)
                              : null,
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: _InfoTile(
                          label: 'Expiry Date',
                          value: expiry.isNotEmpty ? expiry : 'MM/YY',
                          icon: Icons.calendar_today_rounded,
                          isMonospace: true,
                          compact: true,
                          onCopy: expiry.isNotEmpty
                              ? () => _copyToClipboard('Expiry date', expiry)
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 5,
                        child: _InfoTile(
                          label: 'CVV / CVC',
                          value: _showCvv
                              ? (cvv.isNotEmpty ? cvv : '•••')
                              : (cvv.isNotEmpty ? '•' * cvv.length : '•••'),
                          icon: Icons.security_rounded,
                          isMonospace: true,
                          compact: true,
                          onToggleVisibility: () =>
                              setState(() => _showCvv = !_showCvv),
                          isMasked: !_showCvv,
                          onCopy: cvv.isNotEmpty
                              ? () => _copyToClipboard('CVV', cvv)
                              : null,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),

              // PIN Tile (if exists)
              if (pin.isNotEmpty) ...[
                _InfoTile(
                  label: 'ATM / Card PIN',
                  value: _showPin ? pin : '••••',
                  icon: Icons.password_rounded,
                  isMonospace: true,
                  onToggleVisibility: () =>
                      setState(() => _showPin = !_showPin),
                  isMasked: !_showPin,
                  onCopy: () => _copyToClipboard('PIN', pin),
                ),
                const SizedBox(height: 10),
              ],

              // Card Network Tile
              _InfoTile(
                label: 'Card Network',
                value: network,
                icon: Icons.account_balance_wallet_outlined,
              ),

              // Custom Fields / Notes
              ...entry.stringEntries
                  .where(
                    (s) =>
                        !AddPaymentCardScreen.isCardSystemKey(s.key.key) &&
                        s.value?.getText()?.isNotEmpty == true,
                  )
                  .map(
                    (s) {
                      final rawVal = s.value?.getText() ?? '';
                      final isProtected = s.value is ProtectedValue;
                      final kind = KeyNestCustomFieldSheet.resolveFieldKind(
                        entry,
                        s.key.key,
                        value: rawVal,
                        isProtected: isProtected,
                      );
                      final isRevealed = _revealedCustomFields.contains(
                        s.key.key,
                      );
                      final isMasked =
                          (kind == CustomFieldKind.hidden ||
                              kind == CustomFieldKind.pin ||
                              kind == CustomFieldKind.authenticator ||
                              isProtected) &&
                          !isRevealed;

                      final typeItem = KeyNestCustomFieldSheet.fieldTypes
                          .firstWhere(
                            (t) => t.kind == kind,
                            orElse: () =>
                                KeyNestCustomFieldSheet.fieldTypes.first,
                          );

                      if (kind == CustomFieldKind.yesNo) {
                        final isTrue =
                            KeyNestCustomFieldSheet.isTruthy(rawVal);
                        return Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Material(
                            color: isDark
                                ? KeyNestPalette.cardDark
                                : KeyNestPalette.surfaceLight,
                            borderRadius: BorderRadius.circular(
                              KeyNestShapes.radiusCard,
                            ),
                            child: InkWell(
                              onTap: () => _copyToClipboard(
                                s.key.key,
                                isTrue ? 'Yes' : 'No',
                              ),
                              borderRadius: BorderRadius.circular(
                                KeyNestShapes.radiusCard,
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                    KeyNestShapes.radiusCard,
                                  ),
                                  border: Border.all(
                                    color: isDark
                                        ? KeyNestPalette.entryBorderDark
                                        : KeyNestPalette.entryBorderLight,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: Center(
                                        child: Icon(
                                          typeItem.icon,
                                          size: 22,
                                          color: isDark
                                              ? KeyNestPalette.primaryDark
                                              : KeyNestPalette.lightIcon,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '${s.key.key} (${typeItem.title})',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                              color: isDark
                                                  ? KeyNestPalette
                                                      .textSecondaryDark
                                                  : KeyNestPalette
                                                      .textSecondaryLight,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            isTrue
                                                ? 'On (Enabled)'
                                                : 'Off (Disabled)',
                                            style: theme.textTheme.bodyLarge
                                                ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                              color: isDark
                                                  ? KeyNestPalette
                                                      .textPrimaryDark
                                                  : KeyNestPalette
                                                      .textPrimaryLight,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IgnorePointer(
                                      child: Switch.adaptive(
                                        value: isTrue,
                                        activeColor: isDark
                                            ? KeyNestPalette.primaryDark
                                            : KeyNestPalette.primary,
                                        onChanged: null,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }

                      String displayVal;
                      if (isMasked) {
                        displayVal = kind == CustomFieldKind.pin
                            ? '••••'
                            : '••••••••••••';
                      } else {
                        displayVal = rawVal;
                      }

                      return Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: _InfoTile(
                          label: '${s.key.key} (${typeItem.title})',
                          value: displayVal,
                          icon: typeItem.icon,
                          isMonospace: kind == CustomFieldKind.pin,
                          isMasked: isMasked,
                          onToggleVisibility:
                              (isProtected ||
                                  kind == CustomFieldKind.hidden ||
                                  kind == CustomFieldKind.pin ||
                                  kind == CustomFieldKind.authenticator)
                              ? () => setState(() {
                                  if (isRevealed) {
                                    _revealedCustomFields.remove(s.key.key);
                                  } else {
                                    _revealedCustomFields.add(s.key.key);
                                  }
                                })
                              : null,
                          onCopy: () => _copyToClipboard(s.key.key, rawVal),
                        ),
                      );
                    },
                  ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  side: BorderSide(
                    color: isDark
                        ? KeyNestPalette.entryBorderDark
                        : KeyNestPalette.entryBorderLight,
                  ),
                ),
                icon: Icon(
                  Icons.add_rounded,
                  size: 18,
                  color: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.lightIcon,
                ),
                label: Text(
                  'Add Custom Field',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                  ),
                ),
                onPressed: () async {
                  final existingKeys = entry.stringEntries
                      .map((s) => s.key.key)
                      .toSet();
                  final field = await KeyNestCustomFieldSheet.promptAddField(
                    context,
                    existingKeys: existingKeys,
                  );
                  if (field != null && context.mounted) {
                    final isSensitive =
                        field.kind == CustomFieldKind.hidden ||
                        field.kind == CustomFieldKind.pin ||
                        field.kind == CustomFieldKind.authenticator ||
                        KeyNestItemTypeHelper.isSensitiveFieldKey(
                          field.key,
                          kind: field.kind,
                        );
                    entry.setString(
                      KdbxKey(field.key),
                      isSensitive
                          ? ProtectedValue.fromString(field.value)
                          : PlainValue(field.value),
                    );
                    entry.customData['FieldType_${field.key}'] =
                        field.kind.name;
                    KeyNestItemTypeHelper.upgradeEntrySensitiveFields(entry);
                    await context.read<KdbxBloc>().saveFile(entry.file);
                    if (mounted) {
                      setState(() {});
                    }
                  }
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.label,
    required this.value,
    required this.icon,
    this.onCopy,
    this.onToggleVisibility,
    this.isMasked,
    this.isMonospace = false,
    this.compact = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onCopy;
  final VoidCallback? onToggleVisibility;
  final bool? isMasked;
  final bool isMonospace;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return KeyNestPressScale(
      onTap: onCopy,
      child: Material(
        color: isDark ? KeyNestPalette.cardDark : KeyNestPalette.surfaceLight,
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
        child: InkWell(
          onTap: onCopy,
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
          child: Container(
            padding: compact
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
                : const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
              border: Border.all(
                color: isDark
                    ? KeyNestPalette.entryBorderDark
                    : KeyNestPalette.entryBorderLight,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: compact ? 20 : 24,
                  height: compact ? 20 : 24,
                  child: Center(
                    child: Icon(
                      icon,
                      size: compact ? 17 : 22,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.lightIcon,
                    ),
                  ),
                ),
                SizedBox(width: compact ? 8 : 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight,
                          fontSize: compact ? 11 : 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          value,
                          maxLines: 1,
                          softWrap: false,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFamily: isMonospace
                                ? KeyNestTheme.monoFontFamily
                                : null,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                            letterSpacing: isMasked == true
                                ? 1.5
                                : (isMonospace ? 0.8 : 0),
                            fontSize: compact ? 13 : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (onToggleVisibility != null)
                  IconButton(
                    padding: compact
                        ? EdgeInsets.zero
                        : const EdgeInsets.all(8),
                    constraints: compact
                        ? const BoxConstraints(minWidth: 22, minHeight: 22)
                        : null,
                    iconSize: compact ? 16 : 20,
                    icon: Icon(
                      isMasked == true
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: compact ? 16 : 20,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                    onPressed: onToggleVisibility,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
