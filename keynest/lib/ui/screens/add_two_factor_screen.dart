import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/barcodescan_screen.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/platform.dart';
import 'package:keynest/utils/totp_parser.dart';
import 'package:provider/provider.dart';

class AddTwoFactorScreen extends StatefulWidget {
  const AddTwoFactorScreen({
    super.key,
    this.initialFile,
    this.initialGroup,
    this.initialData,
  });

  final KdbxFile? initialFile;
  final KdbxGroup? initialGroup;
  final TotpQrData? initialData;

  static Route<bool> route({
    KdbxFile? initialFile,
    KdbxGroup? initialGroup,
    TotpQrData? initialData,
  }) => KeyNestPlatform.isDesktopOrWeb
      ? KeyNestDesktopDialogRoute<bool>(
          settings: const RouteSettings(name: '/add2fa'),
          maxWidth: 480,
          maxHeight: 580,
          builder: (context) => AddTwoFactorScreen(
            initialFile: initialFile,
            initialGroup: initialGroup,
            initialData: initialData,
          ),
        )
      : KeyNestPushPageRoute<bool>(
          settings: const RouteSettings(name: '/add2fa'),
          builder: (context) => AddTwoFactorScreen(
            initialFile: initialFile,
            initialGroup: initialGroup,
            initialData: initialData,
          ),
        );

  @override
  State<AddTwoFactorScreen> createState() => _AddTwoFactorScreenState();
}

class _AddTwoFactorScreenState extends State<AddTwoFactorScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _titleController;
  late final TextEditingController _secretController;
  late final TextEditingController _accountController;
  late final TextEditingController _issuerController;

  KdbxFile? _selectedFile;
  KdbxGroup? _selectedGroup;

  bool _isSecretObscured = true;
  bool _isSaving = false;
  bool _showAdvanced = false;

  int _digits = 6;
  int _period = 30;
  String _algorithm = 'SHA1';

  @override
  void initState() {
    super.initState();
    final data = widget.initialData;

    _titleController = TextEditingController(text: data?.title ?? '');
    _secretController = TextEditingController(text: data?.secret ?? '');
    _accountController = TextEditingController(text: data?.accountName ?? '');
    _issuerController = TextEditingController(text: data?.issuer ?? '');

    if (data != null) {
      _digits = data.digits;
      _period = data.period;
      _algorithm = data.algorithm;
    }

    _selectedFile = widget.initialFile;
    _selectedGroup = widget.initialGroup;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectedFile == null) {
      final kdbxBloc = context.read<KdbxBloc>();
      final scope = KeyNestVaultScope.instance;
      _selectedFile =
          scope.getSelectedVault(kdbxBloc) ??
          kdbxBloc.openedFilesKdbx.firstOrNull;
      _selectedGroup =
          (scope.getCurrentFolder(kdbxBloc) ?? _selectedFile?.body.rootGroup) ??
          widget.initialGroup;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _secretController.dispose();
    _accountController.dispose();
    _issuerController.dispose();
    super.dispose();
  }

  Future<void> _onChangeDestination() async {
    final dest = await KeyNestDestinationPickerSheet.show(
      context,
      initialFile: _selectedFile,
      initialGroup: _selectedGroup,
    );
    if (dest != null && mounted) {
      setState(() {
        _selectedFile = dest.file;
        _selectedGroup = dest.group;
      });
    }
  }

  Future<void> _onScanQrCode() async {
    final barcodeResult = await BarcodeScanHelper.scanBarcode(
      context,
      titleText: 'Scan TOTP QR Code',
      formats: const [
        BarcodeFormat.qrCode,
        BarcodeFormat.microQRCode,
      ],
      validator: (rawText) {
        final parsed = TotpQrData.parse(rawText.trim());
        if (parsed == null) {
          return 'Not a valid TOTP QR code. Align a TOTP QR code within the frame.';
        }
        return null;
      },
    );

    if (!mounted) {
      return;
    }

    if (barcodeResult case ScanResultValid(barcode: final barcode)) {
      final rawText = barcode.text.trim();
      if (rawText.isNotEmpty) {
        final parsed = TotpQrData.parse(rawText);
        if (parsed != null) {
          _applyParsedData(parsed);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('QR Code scanned and populated successfully'),
              duration: Duration(milliseconds: 1600),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Scanned code is not a supported TOTP format'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    }
  }

  Future<void> _onPasteUri() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard is empty')),
        );
      }
      return;
    }

    final parsed = TotpQrData.parse(text);
    if (parsed != null && mounted) {
      _applyParsedData(parsed);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pasted TOTP data successfully')),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Clipboard does not contain valid TOTP data'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _applyParsedData(TotpQrData data) {
    setState(() {
      _titleController.text = data.title;
      _secretController.text = data.secret;
      _accountController.text = data.accountName ?? '';
      _issuerController.text = data.issuer ?? '';
      _digits = data.digits;
      _period = data.period;
      _algorithm = data.algorithm;
    });
  }

  Future<void> _onSave() async {
    if (_isSaving) {
      return;
    }

    if (!_formKey.currentState!.validate()) {
      return;
    }

    final kdbxBloc = context.read<KdbxBloc>();

    // 1. Validate Destination
    if (_selectedFile == null ||
        !kdbxBloc.openedFilesKdbx.contains(_selectedFile)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a valid open destination vault'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final targetGroup = _selectedGroup ?? _selectedFile!.body.rootGroup;

    // 2. Validate Secret Key
    final cleanSecret = TotpQrData.cleanSecret(_secretController.text);
    if (cleanSecret.isEmpty || !TotpQrData.isValidBase32(cleanSecret)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Secret key must be a valid Base32 string (A-Z, 2-7)'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final title = _titleController.text.trim().isNotEmpty
          ? _titleController.text.trim()
          : '2FA Account';
      final account = _accountController.text.trim();
      final issuer = _issuerController.text.trim();

      final totpData = TotpQrData(
        secret: cleanSecret,
        issuer: issuer.isNotEmpty ? issuer : null,
        accountName: account.isNotEmpty ? account : null,
        title: title,
        digits: _digits,
        period: _period,
        algorithm: _algorithm,
      );

      final otpAuthUri = totpData.toOtpAuthUri();

      // Create entry in explicitly selected vault and group
      final entry = kdbxBloc.createEntry(
        file: _selectedFile,
        group: targetGroup,
      );

      entry.setString(KdbxKeyCommon.TITLE, PlainValue(title));
      if (account.isNotEmpty) {
        entry.setString(KdbxKeyCommon.USER_NAME, PlainValue(account));
      }
      entry.setString(
        KdbxKey('OTPAuth'),
        ProtectedValue.fromString(otpAuthUri),
      );
      KeyNestItemTypeHelper.setItemType(entry, KeyNestItemType.twoFactor);
      if (entry.getString(KdbxKey('ItemCategory')) == null) {
        entry.setString(KdbxKey('ItemCategory'), PlainValue('2FA'));
      }

      KeyNestItemTypeHelper.upgradeEntrySensitiveFields(entry);
      await kdbxBloc.saveFile(_selectedFile!);

      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('2FA Account "$title" created'),
              duration: const Duration(milliseconds: 1800),
            ),
          );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save 2FA entry: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();

    final effectiveFile =
        _selectedFile ??
        KeyNestVaultScope.instance.getSelectedVault(kdbxBloc) ??
        kdbxBloc.openedFilesKdbx.firstOrNull;

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: const Text('Add 2FA Account'),
        leading: KeyNestPlatform.isDesktopOrWeb
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _onSave,
            child: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    'Save',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: KeyNestPalette.primary,
                    ),
                  ),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              // Destination Vault & Folder Selector
              if (effectiveFile != null)
                KeyNestDestinationTile(
                  file: effectiveFile,
                  group: _selectedGroup ?? effectiveFile.body.rootGroup,
                  onChangeDestination: _onChangeDestination,
                ),

              // Action row: Scan QR / Paste Code
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(
                          Icons.qr_code_scanner_rounded,
                          size: 18,
                          color: KeyNestPalette.primary,
                        ),
                        label: const Text('Scan QR Code'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _onScanQrCode,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(
                          Icons.content_paste_rounded,
                          size: 18,
                          color: KeyNestPalette.primary,
                        ),
                        label: const Text('Paste Key / URI'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _onPasteUri,
                      ),
                    ),
                  ],
                ),
              ),

              // Account & Secret Inputs Card
              KeyNestCard(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ACCOUNT DETAILS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Title
                    TextFormField(
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: 'Entry Title *',
                        hintText: 'e.g. GitHub (work), Google, Slack',
                        prefixIcon: Icon(Icons.label_outline_rounded),
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Please enter a title';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),

                    // Secret Key
                    TextFormField(
                      controller: _secretController,
                      obscureText: _isSecretObscured,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Secret Key (Base32) *',
                        hintText: 'e.g. JBSWY3DPEHPK3PXP',
                        prefixIcon: const Icon(Icons.key_rounded),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _isSecretObscured
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () => setState(
                            () => _isSecretObscured = !_isSecretObscured,
                          ),
                        ),
                        border: const OutlineInputBorder(),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Please enter a secret key';
                        }
                        final cleaned = TotpQrData.cleanSecret(val);
                        if (!TotpQrData.isValidBase32(cleaned)) {
                          return 'Invalid Base32 secret key';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),

                    // Account / Username
                    TextFormField(
                      controller: _accountController,
                      decoration: const InputDecoration(
                        labelText: 'Account / Username (Optional)',
                        hintText: 'e.g. alice@example.com or user123',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Issuer / Service
                    TextFormField(
                      controller: _issuerController,
                      decoration: const InputDecoration(
                        labelText: 'Issuer / Service (Optional)',
                        hintText: 'e.g. GitHub, Google, Microsoft',
                        prefixIcon: Icon(Icons.business_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),

              // Advanced Parameters Toggle
              KeyNestCard(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Column(
                  children: [
                    InkWell(
                      onTap: () =>
                          setState(() => _showAdvanced = !_showAdvanced),
                      child: Row(
                        children: [
                          Icon(
                            _showAdvanced
                                ? Icons.tune_rounded
                                : Icons.tune_outlined,
                            size: 20,
                            color: KeyNestPalette.primary,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Advanced TOTP Settings',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          Icon(
                            _showAdvanced
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                          ),
                        ],
                      ),
                    ),
                    if (_showAdvanced) ...[
                      const Divider(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              initialValue: _digits,
                              decoration: const InputDecoration(
                                labelText: 'Digits',
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 6,
                                  child: Text('6 Digits'),
                                ),
                                DropdownMenuItem(
                                  value: 8,
                                  child: Text('8 Digits'),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() => _digits = val);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              initialValue: _period,
                              decoration: const InputDecoration(
                                labelText: 'Period',
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 30,
                                  child: Text('30 Seconds'),
                                ),
                                DropdownMenuItem(
                                  value: 60,
                                  child: Text('60 Seconds'),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() => _period = val);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _algorithm,
                        decoration: const InputDecoration(
                          labelText: 'Algorithm',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'SHA1',
                            child: Text('SHA1 (Default)'),
                          ),
                          DropdownMenuItem(
                            value: 'SHA256',
                            child: Text('SHA256'),
                          ),
                          DropdownMenuItem(
                            value: 'SHA512',
                            child: Text('SHA512'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _algorithm = val);
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
