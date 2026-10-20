import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/widgets/keynest_custom_field_sheet.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:keynest/ui/widgets/keynest_payment_card.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:provider/provider.dart';

class AddPaymentCardScreen extends StatefulWidget {
  const AddPaymentCardScreen({
    super.key,
    this.existingEntry,
    this.initialFile,
    this.initialGroup,
  });

  final KdbxEntry? existingEntry;
  final KdbxFile? initialFile;
  final KdbxGroup? initialGroup;

  static Route<void> route({
    KdbxEntry? existingEntry,
    KdbxFile? initialFile,
    KdbxGroup? initialGroup,
  }) => KeyNestPushPageRoute(
    settings: const RouteSettings(name: '/addCard'),
    builder: (context) => AddPaymentCardScreen(
      existingEntry: existingEntry,
      initialFile: initialFile,
      initialGroup: initialGroup,
    ),
  );

  static bool isCardSystemKey(String key) {
    const systemKeys = {
      'Title',
      'Cardholder',
      'Password',
      'Expiry',
      'CVV',
      'PIN',
      'Network',
      'CardColorHex',
      'CardSecondaryColorHex',
      'CardFinish',
      'CardOrientation',
      'CardGradient',
      'CardNamePos',
      'ItemCategory',
      'RecordType',
      'IsDeleted',
      'KeyNest.ItemType',
      'UserName',
      'URL',
      'Notes',
    };
    return systemKeys.contains(key);
  }

  @override
  State<AddPaymentCardScreen> createState() => _AddPaymentCardScreenState();
}

class _AddPaymentCardScreenState extends State<AddPaymentCardScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _numberController = TextEditingController();
  final TextEditingController _expiryController = TextEditingController();
  final TextEditingController _cvvController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();

  bool _isCvvMasked = true;
  bool _isPinMasked = true;
  bool _isNumberMasked = false;

  String _selectedNetwork = 'Auto';
  Color _selectedColor = const Color(0xFF1E293B);
  Color _secondaryColor = const Color(0xFF0F172A);
  GradientDirection _gradientDirection = GradientDirection.diagonal;
  CardFinish _finish = CardFinish.matte;
  CardOrientation _orientation = CardOrientation.landscape;
  NamePosition _namePosition = NamePosition.left;

  bool _isSaving = false;
  KdbxEntry? _createdEntry;

  final List<CustomFieldModel> _customFields = [];

  static const List<Color> colorPresets = [
    Color(0xFF1E293B), // Charcoal
    Color(0xFF6E56CF), // Purple
    Color(0xFFEF4444), // Coral Red
    Color(0xFF0EA5E9), // Ocean Blue
    Color(0xFF10B981), // Emerald
    Color(0xFFF59E0B), // Amber
    Color(0xFF0284C7), // Deep Blue
    Color(0xFF111827), // Jet Black
  ];

  static const List<String> cardNetworks = [
    'Auto',
    'Visa',
    'Mastercard',
    'American Express',
    'Discover',
    'RuPay',
    'JCB',
    'Diners Club',
  ];

  @override
  void initState() {
    super.initState();
    _selectedFile = widget.existingEntry?.file ?? widget.initialFile;
    _selectedGroup = widget.existingEntry?.parent ?? widget.initialGroup;

    if (widget.existingEntry != null) {
      final e = widget.existingEntry!;
      _nameController.text =
          e.getString(KdbxKey('Cardholder'))?.getText() ?? '';
      _numberController.text =
          e.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
      _expiryController.text = e.getString(KdbxKey('Expiry'))?.getText() ?? '';
      _cvvController.text = e.getString(KdbxKey('CVV'))?.getText() ?? '';
      _pinController.text = e.getString(KdbxKey('PIN'))?.getText() ?? '';
      _selectedNetwork = e.getString(KdbxKey('Network'))?.getText() ?? 'Auto';

      final colorHex = e.getString(KdbxKey('CardColorHex'))?.getText();
      if (colorHex != null && colorHex.isNotEmpty) {
        _selectedColor = KeyNestPaymentCardView.parseCardColor(
          colorHex,
          _selectedColor,
        );
      }

      final secColorHex = e
          .getString(KdbxKey('CardSecondaryColorHex'))
          ?.getText();
      final defaultSec =
          Color.lerp(_selectedColor, Colors.black, 0.3) ?? _selectedColor;
      if (secColorHex != null && secColorHex.isNotEmpty) {
        _secondaryColor = KeyNestPaymentCardView.parseCardColor(
          secColorHex,
          defaultSec,
        );
      } else {
        _secondaryColor = defaultSec;
      }

      final finishStr = e.getString(KdbxKey('CardFinish'))?.getText();
      if (finishStr != null && finishStr.isNotEmpty) {
        _finish = CardFinish.values.firstWhere(
          (f) => f.name == finishStr,
          orElse: () => CardFinish.matte,
        );
      }

      final gradStr = e.getString(KdbxKey('CardGradient'))?.getText();
      if (gradStr != null && gradStr.isNotEmpty) {
        _gradientDirection = GradientDirection.values.firstWhere(
          (g) => g.name == gradStr,
          orElse: () => GradientDirection.diagonal,
        );
      }

      final orientStr = e.getString(KdbxKey('CardOrientation'))?.getText();
      if (orientStr != null && orientStr.isNotEmpty) {
        _orientation = CardOrientation.values.firstWhere(
          (o) => o.name == orientStr,
          orElse: () => CardOrientation.landscape,
        );
      }

      final namePosStr = e.getString(KdbxKey('CardNamePos'))?.getText();
      if (namePosStr != null && namePosStr.isNotEmpty) {
        _namePosition = NamePosition.values.firstWhere(
          (p) => p.name == namePosStr,
          orElse: () => NamePosition.left,
        );
      }

      for (final s in e.stringEntries) {
        final k = s.key.key;
        if (!AddPaymentCardScreen.isCardSystemKey(k) &&
            s.value?.getText()?.isNotEmpty == true) {
          final val = s.value!.getText() ?? '';
          final kind = KeyNestCustomFieldSheet.resolveFieldKind(
            e,
            k,
            value: val,
            isProtected: s.value is ProtectedValue,
          );
          _customFields.add(CustomFieldModel(key: k, value: val, kind: kind));
        }
      }
    }
  }

  KdbxFile? _selectedFile;
  KdbxGroup? _selectedGroup;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectedFile == null) {
      final kdbxBloc = context.read<KdbxBloc>();
      _selectedFile =
          widget.initialFile ?? kdbxBloc.openedFilesKdbx.firstOrNull;
      _selectedGroup = widget.initialGroup ?? _selectedFile?.body.rootGroup;
    }
  }

  @override
  void dispose() {
    if (_createdEntry != null) {
      try {
        _createdEntry!.file.deleteEntry(_createdEntry!);
      } catch (_) {}
      _createdEntry = null;
    }
    _nameController.dispose();
    _numberController.dispose();
    _expiryController.dispose();
    _cvvController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _onSaveCard() async {
    if (_isSaving) {
      return;
    }
    final kdbxBloc = context.read<KdbxBloc>();

    if (_selectedFile == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('No vault selected to save card.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      return;
    }

    final holder = _nameController.text.trim();
    if (holder.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Cardholder name is required.'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }

    final rawNumber = _numberController.text.trim();
    final cleanNumber = rawNumber.replaceAll(RegExp(r'[\s\-]'), '');
    if (cleanNumber.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Card number is required.'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }
    if (!RegExp(r'^\d{16}$').hasMatch(cleanNumber)) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Card number must be exactly 16 digits.'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }

    final rawExpiry = _expiryController.text.trim();
    if (rawExpiry.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Expiration date is required.'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }
    final (expMonth, expYear) = _parseExpiryDate(rawExpiry);
    final hasValidFormat = RegExp(
      r'^(0[1-9]|1[0-2])[\/\-]?([0-9]{2}|[0-9]{4})$',
    ).hasMatch(rawExpiry.replaceAll(' ', ''));
    if (!hasValidFormat || expMonth < 1 || expMonth > 12) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Invalid expiration date format (MM/YY expected).'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }
    final now = DateTime.now();
    final isExpired =
        expYear < now.year || (expYear == now.year && expMonth < now.month);
    if (isExpired) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Card has expired.'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }

    final rawCvv = _cvvController.text.trim();
    if (rawCvv.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('CVC is required.'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }
    if (!RegExp(r'^\d{3,4}$').hasMatch(rawCvv)) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('CVC must be a valid 3 or 4-digit code.'),
            backgroundColor: KeyNestPalette.error,
            duration: Duration(milliseconds: 2500),
          ),
        );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final entry =
          widget.existingEntry ??
          (_createdEntry ??= kdbxBloc.createEntry(
            file: _selectedFile,
            group: _selectedGroup,
          ));

      if (_selectedGroup != null && entry.parent != _selectedGroup) {
        entry.file.move(entry, _selectedGroup!);
      }

      final title = '$holder Card';

      entry.setString(KdbxKeyCommon.TITLE, PlainValue(title));
      KeyNestItemTypeHelper.setItemType(entry, KeyNestItemType.card);
      if (entry.getString(KdbxKey('ItemCategory')) == null) {
        entry.setString(KdbxKey('ItemCategory'), PlainValue('Card'));
      }
      entry.setString(
        KdbxKey('Cardholder'),
        PlainValue(holder),
      );

      // Card number stored encrypted in KDBX (digits only)
      entry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString(cleanNumber),
      );
      entry.setString(
        KdbxKey('Expiry'),
        PlainValue(rawExpiry),
      );
      entry.setString(
        KdbxKey('CVV'),
        ProtectedValue.fromString(rawCvv),
      );
      if (_pinController.text.isNotEmpty) {
        entry.setString(
          KdbxKey('PIN'),
          ProtectedValue.fromString(_pinController.text.trim()),
        );
      } else if (widget.existingEntry != null) {
        entry.removeString(KdbxKey('PIN'));
      }
      entry.setString(
        KdbxKey('Network'),
        PlainValue(_selectedNetwork),
      );

      // Save visual properties
      entry.setString(
        KdbxKey('CardColorHex'),
        PlainValue(_selectedColor.toARGB32().toRadixString(16)),
      );
      entry.setString(
        KdbxKey('CardSecondaryColorHex'),
        PlainValue(_secondaryColor.toARGB32().toRadixString(16)),
      );
      entry.setString(
        KdbxKey('CardFinish'),
        PlainValue(_finish.name),
      );
      entry.setString(
        KdbxKey('CardGradient'),
        PlainValue(_gradientDirection.name),
      );
      entry.setString(
        KdbxKey('CardOrientation'),
        PlainValue(_orientation.name),
      );
      entry.setString(
        KdbxKey('CardNamePos'),
        PlainValue(_namePosition.name),
      );

      // Remove deleted custom fields from existing entry
      if (widget.existingEntry != null) {
        final currentCustomKeys = _customFields.map((f) => f.key).toSet();
        for (final s in widget.existingEntry!.stringEntries.toList()) {
          final k = s.key.key;
          if (!AddPaymentCardScreen.isCardSystemKey(k) &&
              !currentCustomKeys.contains(k)) {
            entry.removeString(s.key);
            entry.customData['FieldType_$k'] = '';
          }
        }
      }

      for (final custom in _customFields) {
        final isSensitive =
            custom.kind == CustomFieldKind.hidden ||
            custom.kind == CustomFieldKind.pin ||
            custom.kind == CustomFieldKind.authenticator ||
            KeyNestItemTypeHelper.isSensitiveFieldKey(
              custom.key,
              kind: custom.kind,
            );
        entry.setString(
          KdbxKey(custom.key),
          isSensitive
              ? ProtectedValue.fromString(custom.value)
              : PlainValue(custom.value),
        );
        entry.customData['FieldType_${custom.key}'] = custom.kind.name;
      }

      KeyNestItemTypeHelper.upgradeEntrySensitiveFields(entry);
      entry.times.lastModificationTime.set(DateTime.now().toUtc());

      await kdbxBloc.saveFile(entry.file);
      _createdEntry = null;

      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('Card saved securely to vault'),
              duration: Duration(milliseconds: 1800),
            ),
          );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('Failed to save card: $e'),
              backgroundColor: Colors.redAccent,
              duration: const Duration(seconds: 4),
            ),
          );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _showExpiryPicker(BuildContext context) async {
    final parsed = _parseExpiryDate(_expiryController.text);
    int tempMonth = parsed.$1;
    int tempYear = parsed.$2;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currentYear = DateTime.now().year;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: isDark
                  ? KeyNestPalette.surfaceDark
                  : KeyNestPalette.surfaceLight,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: isDark
                      ? KeyNestPalette.entryBorderDark
                      : KeyNestPalette.entryBorderLight,
                ),
              ),
              titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              actionsPadding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? KeyNestPalette.primaryContainerDark
                          : KeyNestPalette.primaryContainerLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.calendar_month_rounded,
                      size: 20,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.lightIcon,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Expiry Date',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Year Selector Bar
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? KeyNestPalette.surfaceContainerDark
                            : KeyNestPalette.bgLight,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark
                              ? KeyNestPalette.entryBorderDark
                              : KeyNestPalette.entryBorderLight,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left_rounded),
                            iconSize: 22,
                            onPressed: tempYear > currentYear - 5
                                ? () {
                                    setDialogState(() {
                                      tempYear--;
                                    });
                                  }
                                : null,
                          ),
                          Text(
                            '$tempYear',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'JetBrainsMono',
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right_rounded),
                            iconSize: 22,
                            onPressed: tempYear < currentYear + 30
                                ? () {
                                    setDialogState(() {
                                      tempYear++;
                                    });
                                  }
                                : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Month Grid (4 columns x 3 rows)
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 1.6,
                          ),
                      itemCount: 12,
                      itemBuilder: (context, index) {
                        final month = index + 1;
                        final isSelected = tempMonth == month;
                        const monthNames = [
                          'Jan',
                          'Feb',
                          'Mar',
                          'Apr',
                          'May',
                          'Jun',
                          'Jul',
                          'Aug',
                          'Sep',
                          'Oct',
                          'Nov',
                          'Dec',
                        ];
                        final mStr = month.toString().padLeft(2, '0');
                        return InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            setDialogState(() {
                              tempMonth = month;
                            });
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary)
                                  : (isDark
                                        ? KeyNestPalette.surfaceContainerDark
                                        : KeyNestPalette.bgLight),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isSelected
                                    ? (isDark
                                          ? KeyNestPalette.primaryDark
                                          : KeyNestPalette.primary)
                                    : (isDark
                                          ? KeyNestPalette.entryBorderDark
                                          : KeyNestPalette.entryBorderLight),
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  mStr,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected
                                        ? (isDark
                                              ? const Color(0xFF00315D)
                                              : Colors.white)
                                        : (isDark
                                              ? KeyNestPalette.textPrimaryDark
                                              : KeyNestPalette
                                                    .textPrimaryLight),
                                  ),
                                ),
                                Text(
                                  monthNames[index],
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isSelected
                                        ? (isDark
                                              ? const Color(
                                                  0xFF00315D,
                                                ).withValues(alpha: 0.8)
                                              : Colors.white70)
                                        : (isDark
                                              ? KeyNestPalette.textSecondaryDark
                                              : KeyNestPalette
                                                    .textSecondaryLight),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Select'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && mounted) {
      final formatted = _formatExpiryDate(tempMonth, tempYear);
      setState(() {
        _expiryController.text = formatted;
      });
    }
  }

  static (int, int) _parseExpiryDate(String raw) {
    final now = DateTime.now();
    final clean = raw.trim();
    if (clean.isEmpty) {
      return (now.month, now.year);
    }

    if (clean.contains('-') && clean.length >= 7) {
      final parts = clean.split('-');
      if (parts.length >= 2) {
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (y != null && m != null && m >= 1 && m <= 12) {
          return (m, y < 100 ? 2000 + y : y);
        }
      }
    }

    final separator = clean.contains('/')
        ? '/'
        : (clean.contains('.') ? '.' : (clean.contains('-') ? '-' : null));
    if (separator != null) {
      final parts = clean.split(separator);
      if (parts.length >= 2) {
        final m = int.tryParse(parts[0].trim());
        var y = int.tryParse(parts[1].trim());
        if (m != null && y != null && m >= 1 && m <= 12) {
          if (y < 100) {
            y = 2000 + y;
          }
          return (m, y);
        }
      }
    }

    final digits = clean.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 4) {
      final m = int.tryParse(digits.substring(0, 2));
      final y = int.tryParse(digits.substring(2, 4));
      if (m != null && y != null && m >= 1 && m <= 12) {
        return (m, 2000 + y);
      }
    }

    return (now.month, now.year);
  }

  static String _formatExpiryDate(int month, int year) {
    final mStr = month.toString().padLeft(2, '0');
    final yStr = (year % 100).toString().padLeft(2, '0');
    return '$mStr/$yStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: Text(
          widget.existingEntry != null ? 'Edit Card' : 'Add Card',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_selectedFile != null) ...[
              KeyNestDestinationTile(
                file: _selectedFile!,
                group: _selectedGroup,
                onChangeDestination: () async {
                  final dest = await KeyNestDestinationPickerSheet.show(
                    context,
                    initialFile: _selectedFile!,
                    initialGroup: _selectedGroup,
                  );
                  if (dest != null && mounted) {
                    setState(() {
                      _selectedFile = dest.file;
                      _selectedGroup = dest.group;
                    });
                  }
                },
              ),
              const SizedBox(height: 12),
            ],

            // Live Interactive Card Preview
            KeyNestPaymentCardView(
              cardholderName: _nameController.text,
              cardNumber: _numberController.text,
              expiry: _expiryController.text,
              cardNetwork: _selectedNetwork,
              cardColor: _selectedColor,
              secondaryColor: _secondaryColor,
              finish: _finish,
              gradientDirection: _gradientDirection,
              orientation: _orientation,
              namePosition: _namePosition,
              isMasked: _isNumberMasked,
              onToggleMask: () =>
                  setState(() => _isNumberMasked = !_isNumberMasked),
            ),
            const SizedBox(height: 24),

            // Card Colour Swatches
            _SectionLabel(title: 'Card Colour'),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: colorPresets.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final col = colorPresets[index];
                  final isSelected = _selectedColor == col;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedColor = col;
                        _secondaryColor =
                            Color.lerp(col, Colors.black, 0.3) ?? col;
                      });
                    },
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: col,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.white : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow: [
                          if (isSelected)
                            BoxShadow(
                              color: col.withValues(alpha: 0.6),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                        ],
                      ),
                      child: isSelected
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),

            // Secondary Colour Swatches
            _SectionLabel(title: 'Secondary Colour'),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: colorPresets.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final col = colorPresets[index];
                  final isSelected =
                      _secondaryColor.toARGB32() == col.toARGB32();
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _secondaryColor = col;
                      });
                    },
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: col,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.white : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow: [
                          if (isSelected)
                            BoxShadow(
                              color: col.withValues(alpha: 0.6),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                        ],
                      ),
                      child: isSelected
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),

            // Gradient Direction Selector
            _SectionLabel(title: 'Gradient Direction'),
            const SizedBox(height: 8),
            _SegmentedPills<GradientDirection>(
              values: GradientDirection.values,
              selectedValue: _gradientDirection,
              labelBuilder: (g) {
                switch (g) {
                  case GradientDirection.diagonal:
                    return '⊞ Diagonal';
                  case GradientDirection.horizontal:
                    return '⇄ Horizontal';
                  case GradientDirection.vertical:
                    return '⇅ Vertical';
                }
              },
              onSelected: (val) => setState(() => _gradientDirection = val),
            ),
            const SizedBox(height: 20),

            // Finish Selector
            _SectionLabel(title: 'Finish'),
            const SizedBox(height: 8),
            _SegmentedPills<CardFinish>(
              values: CardFinish.values,
              selectedValue: _finish,
              labelBuilder: (f) {
                switch (f) {
                  case CardFinish.matte:
                    return '○ Matte';
                  case CardFinish.metal:
                    return '⚙ Metal';
                  case CardFinish.plastic:
                    return '💧 Plastic';
                }
              },
              onSelected: (val) => setState(() => _finish = val),
            ),
            const SizedBox(height: 20),

            // Orientation Selector
            _SectionLabel(title: 'Orientation'),
            const SizedBox(height: 8),
            _SegmentedPills<CardOrientation>(
              values: CardOrientation.values,
              selectedValue: _orientation,
              labelBuilder: (o) =>
                  o == CardOrientation.landscape ? '▭ Landscape' : '▯ Portrait',
              onSelected: (val) => setState(() => _orientation = val),
            ),
            const SizedBox(height: 20),

            // Name Position Selector
            _SectionLabel(title: 'Name Position'),
            const SizedBox(height: 8),
            _SegmentedPills<NamePosition>(
              values: NamePosition.values,
              selectedValue: _namePosition,
              labelBuilder: (p) {
                switch (p) {
                  case NamePosition.left:
                    return '⫷ Left';
                  case NamePosition.center:
                    return '≡ Center';
                  case NamePosition.right:
                    return '⫸ Right';
                }
              },
              onSelected: (val) => setState(() => _namePosition = val),
            ),
            const SizedBox(height: 24),

            // Cardholder Name Input
            _InputFieldContainer(
              label: 'Cardholder Name',
              icon: Icons.person_outline_rounded,
              child: TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.characters,
                minLines: 1,
                maxLines: 2,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Name on card',
                  isDense: true,
                  hintStyle: TextStyle(
                    color:
                        (isDark
                                ? KeyNestTokens.darkOnSurface
                                : KeyNestTokens.lightOnSurface)
                            .withValues(alpha: 0.38),
                    fontWeight: FontWeight.normal,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Card Number Input (16 digits strictly, non-numeric prevented, single line)
            _InputFieldContainer(
              label: 'Card Number',
              icon: Icons.credit_card_rounded,
              trailing: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 26,
                  minHeight: 26,
                ),
                iconSize: 18,
                icon: Icon(
                  _isNumberMasked
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 18,
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
                onPressed: () =>
                    setState(() => _isNumberMasked = !_isNumberMasked),
              ),
              child: TextField(
                controller: _numberController,
                obscureText: _isNumberMasked,
                keyboardType: TextInputType.number,
                maxLines: 1,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(16),
                ],
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFamily: KeyNestTheme.monoFontFamily,
                  letterSpacing: _isNumberMasked ? 1.5 : 0.8,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '16 digits',
                  isDense: true,
                  hintStyle: TextStyle(
                    color:
                        (isDark
                                ? KeyNestTokens.darkOnSurface
                                : KeyNestTokens.lightOnSurface)
                            .withValues(alpha: 0.38),
                    fontWeight: FontWeight.normal,
                    letterSpacing: 0,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Card Network Chips
            _SectionLabel(title: 'Card Network'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: cardNetworks.map((net) {
                final isSelected = _selectedNetwork == net;
                return ChoiceChip(
                  label: Text(net),
                  selected: isSelected,
                  selectedColor: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                  backgroundColor: isDark
                      ? KeyNestPalette.surfaceContainerDark
                      : KeyNestPalette.surfaceLight,
                  labelStyle: TextStyle(
                    color: isSelected
                        ? (isDark ? const Color(0xFF00315D) : Colors.white)
                        : (isDark
                              ? KeyNestPalette.textPrimaryDark
                              : KeyNestPalette.textPrimaryLight),
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 13,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide.none,
                  ),
                  onSelected: (val) {
                    if (val) {
                      setState(() => _selectedNetwork = net);
                    }
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // Expiry & CVV Row (Both on single line, MM/YY format with validation)
            Row(
              children: [
                Expanded(
                  child: _InputFieldContainer(
                    label: 'Expiry Date',
                    icon: Icons.calendar_today_rounded,
                    compact: true,
                    trailing: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      iconSize: 18,
                      tooltip: 'Select Expiry Date',
                      icon: Icon(
                        Icons.edit_calendar_rounded,
                        size: 18,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                      onPressed: () => _showExpiryPicker(context),
                    ),
                    child: InkWell(
                      onTap: () => _showExpiryPicker(context),
                      child: IgnorePointer(
                        child: TextField(
                          controller: _expiryController,
                          keyboardType: TextInputType.number,
                          maxLines: 1,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFamily: KeyNestTheme.monoFontFamily,
                            letterSpacing: 0.8,
                            fontSize: 13,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                          ),
                          decoration: InputDecoration(
                            hintText: 'MM/YY',
                            isDense: true,
                            hintStyle: TextStyle(
                              color:
                                  (isDark
                                          ? KeyNestTokens.darkOnSurface
                                          : KeyNestTokens.lightOnSurface)
                                      .withValues(alpha: 0.38),
                              fontWeight: FontWeight.normal,
                              letterSpacing: 0,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _InputFieldContainer(
                    label: 'CVV / CVC',
                    icon: Icons.security_rounded,
                    compact: true,
                    trailing: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      iconSize: 18,
                      icon: Icon(
                        _isCvvMasked
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        size: 18,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                      onPressed: () =>
                          setState(() => _isCvvMasked = !_isCvvMasked),
                    ),
                    child: TextField(
                      controller: _cvvController,
                      obscureText: _isCvvMasked,
                      keyboardType: TextInputType.number,
                      maxLines: 1,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFamily: KeyNestTheme.monoFontFamily,
                        letterSpacing: _isCvvMasked ? 1.5 : 0.8,
                        fontSize: 13,
                        color: isDark
                            ? KeyNestPalette.textPrimaryDark
                            : KeyNestPalette.textPrimaryLight,
                      ),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: '3-4 digits',
                        isDense: true,
                        hintStyle: TextStyle(
                          color:
                              (isDark
                                      ? KeyNestTokens.darkOnSurface
                                      : KeyNestTokens.lightOnSurface)
                                  .withValues(alpha: 0.38),
                          fontWeight: FontWeight.normal,
                          letterSpacing: 0,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Card PIN (optional)
            _InputFieldContainer(
              label: 'Card PIN (optional)',
              icon: Icons.password_rounded,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    iconSize: 18,
                    icon: const Icon(Icons.shuffle_rounded, size: 18),
                    tooltip: 'Generate Random PIN',
                    onPressed: () {
                      final random = Random.secure();
                      final pin = List.generate(
                        4,
                        (_) => random.nextInt(10),
                      ).join();
                      setState(() {
                        _pinController.text = pin;
                        _isPinMasked = false;
                      });
                    },
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    iconSize: 18,
                    icon: Icon(
                      _isPinMasked
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 18,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                    onPressed: () =>
                        setState(() => _isPinMasked = !_isPinMasked),
                  ),
                ],
              ),
              child: TextField(
                controller: _pinController,
                obscureText: _isPinMasked,
                keyboardType: TextInputType.number,
                maxLines: 1,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFamily: KeyNestTheme.monoFontFamily,
                  letterSpacing: _isPinMasked ? 1.5 : 0.8,
                  color: isDark
                      ? KeyNestPalette.textPrimaryDark
                      : KeyNestPalette.textPrimaryLight,
                ),
                decoration: InputDecoration(
                  hintText: '4 to 6 digits',
                  isDense: true,
                  hintStyle: TextStyle(
                    color:
                        (isDark
                                ? KeyNestTokens.darkOnSurface
                                : KeyNestTokens.lightOnSurface)
                            .withValues(alpha: 0.38),
                    fontWeight: FontWeight.normal,
                    letterSpacing: 0,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Custom Fields Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _SectionLabel(title: 'CUSTOM FIELDS'),
              ],
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < _customFields.length; i++) ...[
              Builder(
                builder: (context) {
                  final field = _customFields[i];
                  final typeItem = KeyNestCustomFieldSheet.fieldTypes
                      .firstWhere(
                        (t) => t.kind == field.kind,
                        orElse: () => KeyNestCustomFieldSheet.fieldTypes.first,
                      );

                  if (field.kind == CustomFieldKind.yesNo) {
                    final isTrue =
                        KeyNestCustomFieldSheet.isTruthy(field.value);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isDark
                              ? KeyNestPalette.cardDark
                              : KeyNestPalette.surfaceLight,
                          borderRadius: BorderRadius.circular(
                            KeyNestShapes.radiusCard,
                          ),
                          border: Border.all(
                            color: isDark
                                ? KeyNestPalette.entryBorderDark
                                : KeyNestPalette.entryBorderLight,
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              typeItem.icon,
                              size: 20,
                              color: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${field.key} (${typeItem.title})',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: isDark
                                          ? KeyNestPalette.textSecondaryDark
                                          : KeyNestPalette.textSecondaryLight,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    isTrue ? 'On (Enabled)' : 'Off (Disabled)',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? KeyNestPalette.textPrimaryDark
                                          : KeyNestPalette.textPrimaryLight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: isTrue,
                              activeThumbColor: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary,
                              onChanged: (val) {
                                setState(() {
                                  _customFields[i].value =
                                      KeyNestCustomFieldSheet.boolToString(
                                    val,
                                    originalValue: field.value,
                                  );
                                });
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.remove_circle_outline_rounded,
                                color: Colors.redAccent,
                                size: 20,
                              ),
                              onPressed: () async {
                                final confirmed =
                                    await DialogUtils.showConfirmDialog(
                                  context: context,
                                  params: ConfirmDialogParams(
                                    title: 'Delete Field',
                                    content:
                                        'Are you sure you want to delete "${field.key}"?',
                                    positiveButtonText: 'Delete',
                                    negativeButtonText: 'Cancel',
                                  ),
                                );
                                if (confirmed == true && mounted) {
                                  setState(() => _customFields.removeAt(i));
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  String displayVal;
                  if (field.kind == CustomFieldKind.hidden) {
                    displayVal = '••••••••••••';
                  } else if (field.kind == CustomFieldKind.pin) {
                    displayVal = '••••';
                  } else {
                    displayVal = field.value;
                  }

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(
                        KeyNestShapes.radiusCard,
                      ),
                      onTap: () async {
                        final updated =
                            await KeyNestCustomFieldSheet.promptAddField(
                              context,
                              existing: field,
                            );
                        if (updated != null && mounted) {
                          setState(() => _customFields[i] = updated);
                        }
                      },
                      child: _InputFieldContainer(
                        label: '${field.key} (${typeItem.title})',
                        icon: KeyNestCustomFieldSheet.getIconForField(
                          field.key,
                          kind: field.kind,
                          fallback: typeItem.icon,
                        ),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.remove_circle_outline_rounded,
                            color: Colors.redAccent,
                            size: 20,
                          ),
                          onPressed: () async {
                            final confirmed =
                                await DialogUtils.showConfirmDialog(
                              context: context,
                              params: ConfirmDialogParams(
                                title: 'Delete Field',
                                content:
                                    'Are you sure you want to delete "${field.key}"?',
                                positiveButtonText: 'Delete',
                                negativeButtonText: 'Cancel',
                              ),
                            );
                            if (confirmed == true && mounted) {
                              setState(() => _customFields.removeAt(i));
                            }
                          },
                        ),
                        child: Text(
                          displayVal,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing:
                                (field.kind == CustomFieldKind.hidden ||
                                    field.kind == CustomFieldKind.pin)
                                ? 2.0
                                : 0,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
            OutlinedButton.icon(
              onPressed: () async {
                final existingKeys = _customFields.map((f) => f.key).toSet();
                final field = await KeyNestCustomFieldSheet.promptAddField(
                  context,
                  existingKeys: existingKeys,
                );
                if (field != null && mounted) {
                  setState(() => _customFields.add(field));
                }
              },
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Add Field'),
              style: OutlinedButton.styleFrom(
                foregroundColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                side: BorderSide(
                  color: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                  width: 1.2,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    KeyNestShapes.radiusButton,
                  ),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 32),

            // Save Card Button
            ElevatedButton(
              onPressed: _isSaving ? null : _onSaveCard,
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                foregroundColor: isDark
                    ? const Color(0xFF00315D)
                    : Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    KeyNestShapes.radiusButton,
                  ),
                ),
              ),
              child: _isSaving
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isDark ? const Color(0xFF00315D) : Colors.white,
                        ),
                      ),
                    )
                  : const Text(
                      'Save Card',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        color: isDark
            ? KeyNestPalette.textSecondaryDark
            : KeyNestPalette.textSecondaryLight,
      ),
    );
  }
}

class CardExpiryInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text.replaceAll('/', '').replaceAll(RegExp(r'\D'), '');
    if (text.length > 4) {
      text = text.substring(0, 4);
    }

    // Handle backspace when right after '/'
    if (oldValue.text.length > newValue.text.length &&
        oldValue.text.endsWith('/') &&
        text.length == 2) {
      text = text.substring(0, 1);
    }

    // Month validation (01-12)
    if (text.isNotEmpty) {
      final firstDigit = int.tryParse(text[0]) ?? 0;
      if (firstDigit > 1) {
        text = '0$text';
        if (text.length > 4) {
          text = text.substring(0, 4);
        }
      } else if (text.length >= 2) {
        final month = int.tryParse(text.substring(0, 2)) ?? 0;
        if (month == 0) {
          text = '01${text.substring(2)}';
        } else if (month > 12) {
          text = '12${text.substring(2)}';
        }
      }
    }

    final buffer = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      if (i == 2) {
        buffer.write('/');
      }
      buffer.write(text[i]);
    }

    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class _InputFieldContainer extends StatelessWidget {
  const _InputFieldContainer({
    required this.label,
    required this.icon,
    required this.child,
    this.trailing,
    this.compact = false,
  });

  final String label;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bg = isDark ? KeyNestPalette.cardDark : KeyNestPalette.surfaceLight;
    final borderColor = isDark
        ? KeyNestPalette.entryBorderDark
        : KeyNestPalette.entryBorderLight;

    return Container(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 10)
          : const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
        border: Border.all(color: borderColor, width: 1.0),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                    : KeyNestPalette.primary,
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
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                    fontSize: compact ? 11 : 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                child,
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: trailing!,
            ),
          ],
        ],
      ),
    );
  }
}

class _SegmentedPills<T> extends StatelessWidget {
  const _SegmentedPills({
    required this.values,
    required this.selectedValue,
    required this.labelBuilder,
    required this.onSelected,
  });

  final List<T> values;
  final T selectedValue;
  final String Function(T) labelBuilder;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      children: values.map((val) {
        final isSelected = val == selectedValue;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Material(
              color: isSelected
                  ? (isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary)
                  : (isDark
                        ? KeyNestPalette.surfaceContainerDark
                        : KeyNestPalette.surfaceLight),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onSelected(val),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: isSelected
                        ? null
                        : Border.all(
                            color: isDark
                                ? KeyNestPalette.entryBorderDark
                                : KeyNestPalette.entryBorderLight,
                          ),
                  ),
                  child: Text(
                    labelBuilder(val),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: isSelected
                          ? (isDark ? const Color(0xFF00315D) : Colors.white)
                          : (isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
