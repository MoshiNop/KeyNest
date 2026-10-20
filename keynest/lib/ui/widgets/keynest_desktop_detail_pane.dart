import 'dart:async';

import 'package:flutter/material.dart' hide CharacterRange;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/password_list.dart';
import 'package:keynest/ui/widgets/keynest_password_history_sheet.dart';
import 'package:keynest/ui/widgets/keynest_totp_tile.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/password_generator.dart';
import 'package:provider/provider.dart';

/// Modern desktop detail pane for Desktop (Windows, macOS, Linux, Web).
/// Features:
/// - Top breadcrumb with vault/folder indicator and action buttons (Share, Edit, More)
/// - Security warning banner for weak/compromised passwords
/// - Hero icon + large title
/// - Grouped field card with username, password, strength indicator, website, TOTP, and notes
/// - In-place Edit mode with Cancel/Save buttons
/// - Responsive empty state when no item is selected
class KeyNestDesktopDetailPane extends StatefulWidget {
  const KeyNestDesktopDetailPane({
    super.key,
    required this.entry,
    this.initialIsEditing = false,
    this.onEntrySaved,
    this.onEntryDeleted,
    this.onAddNewItem,
  });

  final KdbxEntry? entry;
  final bool initialIsEditing;
  final ValueChanged<KdbxEntry>? onEntrySaved;
  final VoidCallback? onEntryDeleted;
  final VoidCallback? onAddNewItem;

  @override
  State<KeyNestDesktopDetailPane> createState() =>
      _KeyNestDesktopDetailPaneState();
}

class _KeyNestDesktopDetailPaneState
    extends State<KeyNestDesktopDetailPane> {
  bool _isEditing = false;
  bool _isPasswordMasked = true;
  bool _dismissedSecurityBanner = false;

  // Edit mode form controllers
  late final TextEditingController _titleController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _urlController;
  late final TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.initialIsEditing;
    _initControllers();
  }

  @override
  void didUpdateWidget(covariant KeyNestDesktopDetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entry != oldWidget.entry) {
      _isPasswordMasked = true;
      _dismissedSecurityBanner = false;
      _isEditing = widget.initialIsEditing;
      _initControllers();
    }
  }

  void _initControllers() {
    final e = widget.entry;
    _titleController = TextEditingController(text: e?.label ?? '');
    _usernameController = TextEditingController(
      text: e?.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '',
    );
    _passwordController = TextEditingController(
      text: e?.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '',
    );
    _urlController = TextEditingController(
      text: e?.getString(KdbxKeyCommon.URL)?.getText() ?? '',
    );
    _notesController = TextEditingController(
      text: e?.getString(KdbxKey('Notes'))?.getText() ?? '',
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _urlController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _copyToClipboard(String label, String value) {
    if (value.isEmpty) {
      return;
    }
    HapticFeedback.lightImpact();
    if (label.toLowerCase().contains('password') ||
        label.toLowerCase().contains('pin') ||
        label.toLowerCase().contains('cvv')) {
      SecurityService.copySensitive(context, value, label: label);
    } else {
      SecurityService.copyNonSensitive(context, value, label: label);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $label to clipboard'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _generateRandomPassword() {
    final sets = CharacterSetCollection([
      CharacterSet.alphabetAsciiLowerCase,
      CharacterSet.alphabetAsciiUpperCase,
      CharacterSet.numeric,
      const CharacterRange(33, 47), // symbols
    ]);
    final pass = PasswordGenerator.singleton().generatePassword(sets, 20);
    setState(() {
      _passwordController.text = pass;
    });
  }

  Future<void> _saveEntry() async {
    final entry = widget.entry;
    if (entry == null) {
      return;
    }

    final kdbxBloc = context.read<KdbxBloc>();

    entry.label = _titleController.text.trim().isEmpty
        ? 'Untitled Item'
        : _titleController.text.trim();

    entry.setString(
      KdbxKeyCommon.USER_NAME,
      PlainValue(_usernameController.text.trim()),
    );
    entry.setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString(_passwordController.text),
    );
    entry.setString(
      KdbxKeyCommon.URL,
      PlainValue(_urlController.text.trim()),
    );
    entry.setString(
      KdbxKey('Notes'),
      PlainValue(_notesController.text),
    );

    entry.times.lastModificationTime.set(DateTime.now());

    final file = entry.file;
    await kdbxBloc.saveFile(file);

    widget.onEntrySaved?.call(entry);
    KeyNestVaultScope.instance.notifyScopeChanged();

    if (mounted) {
      setState(() {
        _isEditing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Item saved successfully'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _deleteEntry() async {
    final entry = widget.entry;
    if (entry == null) {
      return;
    }

    final confirm = await DialogUtils.showConfirmDialog(
      context: context,
      params: ConfirmDialogParams(
        title: 'Delete Item',
        content:
            'Are you sure you want to move "${entry.label ?? 'this item'}" to Trash?',
        positiveButtonText: 'Delete',
      ),
    );

    if (confirm && mounted) {
      final kdbxBloc = context.read<KdbxBloc>();
      final file = entry.file;
      file.deleteEntry(entry);
      await kdbxBloc.saveFile(file);
      widget.onEntryDeleted?.call();
      KeyNestVaultScope.instance.notifyScopeChanged();
    }
  }

  bool _isWeakPassword(String password) {
    if (password.isEmpty) {
      return false;
    }
    if (password.length < 10) {
      return true;
    }
    final lower = password.toLowerCase();
    if (lower == 'password' ||
        lower == '123456' ||
        lower == '12345678' ||
        lower == 'qwerty' ||
        lower == 'admin') {
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final entry = widget.entry;

    if (entry == null) {
      return _buildEmptyState(context, isDark);
    }

    if (_isEditing) {
      return _buildEditMode(context, isDark, entry);
    }

    return _buildViewMode(context, isDark, entry);
  }

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    return Container(
      color: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isDark ? KeyNestPalette.primaryDark : const Color(0xFF0A85EA))
                    .withValues(alpha: 0.12),
              ),
              child: Icon(
                Icons.shield_outlined,
                size: 40,
                color: isDark ? KeyNestPalette.primaryDark : const Color(0xFF0A85EA),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No Item Selected',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Select an item from the list to view or edit details',
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
            const SizedBox(height: 24),
            if (widget.onAddNewItem != null)
              FilledButton.icon(
                onPressed: widget.onAddNewItem,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('+ New Item'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0A85EA),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildViewMode(BuildContext context, bool isDark, KdbxEntry entry) {
    final title = entry.label?.isNotEmpty == true ? entry.label! : 'Untitled';
    final username = entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
    final password = entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
    final url = entry.getString(KdbxKeyCommon.URL)?.getText() ?? '';
    final notes = entry.getString(KdbxKey('Notes'))?.getText() ?? '';
    final folderName = entry.parent?.name.get() ?? 'Root Group';
    final activeVaultName = KeyNestVaultScope.instance.getSelectedVault(context.read<KdbxBloc>())?.body.meta.customData['title'] ??
        'Vault';

    final hasTotp = EntryTotpHelper.hasTotp(entry);
    final isWeak = _isWeakPassword(password);
    final modified = entry.times.lastModificationTime.get();
    final modifiedStr = modified != null
        ? DateFormat('EEEE, MMMM d, y \'at\' h:mm:ss a').format(modified)
        : null;

    final cardBorder = isDark ? KeyNestPalette.cardBorderDark : const Color(0xFFE2E8F0);
    final cardBg = isDark ? KeyNestPalette.surfaceDark : Colors.white;

    return Container(
      color: isDark ? KeyNestPalette.bgDark : const Color(0xFFF8FAFC),
      child: Column(
        children: [
          // 1. Top Breadcrumb & Action Bar
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: cardBg,
              border: Border(bottom: BorderSide(color: cardBorder, width: 1)),
            ),
            child: Row(
              children: [
                // Profile & Vault Breadcrumb
                Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: isDark ? KeyNestPalette.primaryDark : const Color(0xFF0A85EA),
                ),
                const SizedBox(width: 8),
                Text(
                  activeVaultName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded, size: 16, color: Colors.grey.shade400),
                const SizedBox(width: 6),
                Text(
                  folderName,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
                const Spacer(),
                // Share Action
                IconButton(
                  tooltip: 'Share Item',
                  icon: const Icon(Icons.share_outlined, size: 18),
                  onPressed: () => _copyToClipboard('Credentials', '$username : $password'),
                ),
                const SizedBox(width: 4),
                // Edit Button
                OutlinedButton.icon(
                  onPressed: () => setState(() => _isEditing = true),
                  icon: const Icon(Icons.edit_outlined, size: 15),
                  label: const Text('Edit'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isDark ? Colors.white : Colors.black87,
                    side: BorderSide(color: cardBorder),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(width: 6),
                // More Menu
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 18),
                  onSelected: (val) {
                    if (val == 'delete') {
                      _deleteEntry();
                    } else if (val == 'history') {
                      KeyNestPasswordHistorySheet.show(context, entry);
                    } else if (val == 'copy_user') {
                      _copyToClipboard('Username', username);
                    } else if (val == 'copy_pass') {
                      _copyToClipboard('Password', password);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'copy_user', child: Text('Copy Username')),
                    const PopupMenuItem(value: 'copy_pass', child: Text('Copy Password')),
                    const PopupMenuItem(value: 'history', child: Text('Password History')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete Item', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 2. Body: Security Banner, Hero Header, Grouped Card
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              children: [
                // Security Warning Banner
                if (isWeak && !_dismissedSecurityBanner)
                  Container(
                    margin: const EdgeInsets.only(bottom: 24),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFC93B2B),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 20),
                            const SizedBox(width: 4),
                            const Text(
                              'Weak password',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
                              onPressed: () => setState(() => _isEditing = true),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'This password is too easy to guess. Change your password to something stronger.',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            ElevatedButton(
                              onPressed: () {
                                if (url.isNotEmpty) {
                                  _copyToClipboard('URL', url);
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFFC93B2B),
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              child: const Text('Change password on website', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            ),
                            const SizedBox(width: 10),
                            TextButton(
                              onPressed: () => setState(() => _dismissedSecurityBanner = true),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              child: const Text('Ignore', style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                // Hero Header: Large Icon + Big Title
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: (isDark ? KeyNestPalette.primaryDark : const Color(0xFF0A85EA))
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: EntryIcon(
                        entry: entry,
                        size: 30,
                        fallback: (ctx) => Icon(
                          Icons.vpn_key_rounded,
                          size: 28,
                          color: isDark ? KeyNestPalette.primaryDark : const Color(0xFF0A85EA),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Grouped Field Card
                Container(
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cardBorder, width: 1),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Field 1: username
                      if (username.isNotEmpty) ...[
                        _buildFieldRow(
                          label: 'username',
                          value: username,
                          isDark: isDark,
                          onCopy: () => _copyToClipboard('Username', username),
                        ),
                        Divider(height: 1, color: cardBorder),
                      ],

                      // Field 2: password
                      _buildFieldRow(
                        label: 'password',
                        value: _isPasswordMasked
                            ? '••••••••••••'
                            : (password.isEmpty ? '(Empty password)' : password),
                        isDark: isDark,
                        badgeWidget: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isWeak ? const Color(0xFFC93B2B).withValues(alpha: 0.15) : Colors.green.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isWeak ? 'Weak' : 'Strong',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isWeak ? const Color(0xFFC93B2B) : Colors.green,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                isWeak ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded,
                                size: 12,
                                color: isWeak ? const Color(0xFFC93B2B) : Colors.green,
                              ),
                            ],
                          ),
                        ),
                        trailingActions: [
                          IconButton(
                            tooltip: _isPasswordMasked ? 'Reveal Password' : 'Hide Password',
                            icon: Icon(
                              _isPasswordMasked ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                              size: 17,
                              color: Colors.grey,
                            ),
                            onPressed: () => setState(() => _isPasswordMasked = !_isPasswordMasked),
                          ),
                          IconButton(
                            tooltip: 'Copy Password',
                            icon: const Icon(Icons.copy_rounded, size: 17, color: Colors.grey),
                            onPressed: () => _copyToClipboard('Password', password),
                          ),
                        ],
                      ),

                      // Field 3: website
                      if (url.isNotEmpty) ...[
                        Divider(height: 1, color: cardBorder),
                        _buildFieldRow(
                          label: 'website',
                          value: url,
                          isLink: true,
                          isDark: isDark,
                          onCopy: () => _copyToClipboard('Website', url),
                        ),
                      ],

                      // Field 4: TOTP (if present)
                      if (hasTotp) ...[
                        Divider(height: 1, color: cardBorder),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          child: KeyNestTotpTile(
                            entry: entry,
                            label: 'one-time password',
                          ),
                        ),
                      ],

                      // Field 5: notes (if present)
                      if (notes.isNotEmpty) ...[
                        Divider(height: 1, color: cardBorder),
                        _buildFieldRow(
                          label: 'notes',
                          value: notes,
                          isDark: isDark,
                          onCopy: () => _copyToClipboard('Notes', notes),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                // Footer: Last edited timestamp
                if (modifiedStr != null)
                  Row(
                    children: [
                      Icon(Icons.chevron_right_rounded, size: 16, color: Colors.grey.shade400),
                      const SizedBox(width: 4),
                      Text(
                        'Last edited $modifiedStr',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.black45,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldRow({
    required String label,
    required String value,
    required bool isDark,
    bool isLink = false,
    Widget? badgeWidget,
    List<Widget>? trailingActions,
    VoidCallback? onCopy,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: isLink
                        ? const Color(0xFF0A85EA)
                        : (isDark ? Colors.white : Colors.black87),
                    decoration: isLink ? TextDecoration.underline : TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          ?badgeWidget,
          ...?trailingActions,
          if (trailingActions == null && onCopy != null)
            IconButton(
              tooltip: 'Copy $label',
              icon: const Icon(Icons.copy_rounded, size: 17, color: Colors.grey),
              onPressed: onCopy,
            ),
        ],
      ),
    );
  }

  Widget _buildEditMode(BuildContext context, bool isDark, KdbxEntry entry) {
    final cardBorder = isDark ? KeyNestPalette.cardBorderDark : const Color(0xFFE2E8F0);
    final cardBg = isDark ? KeyNestPalette.surfaceDark : Colors.white;

    return Container(
      color: isDark ? KeyNestPalette.bgDark : const Color(0xFFF8FAFC),
      child: Column(
        children: [
          // Edit Mode Top Action Bar (Cancel / Save)
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: cardBg,
              border: Border(bottom: BorderSide(color: cardBorder, width: 1)),
            ),
            child: Row(
              children: [
                Text(
                  'Editing Item',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _isEditing = false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _saveEntry,
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Save'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0A85EA),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),

          // Edit Form Fields
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(28),
              children: [
                // Title
                _buildEditTextField(
                  label: 'Title',
                  controller: _titleController,
                  isDark: isDark,
                  cardBorder: cardBorder,
                  icon: Icons.title_rounded,
                ),
                const SizedBox(height: 16),

                // Username
                _buildEditTextField(
                  label: 'Username / Email',
                  controller: _usernameController,
                  isDark: isDark,
                  cardBorder: cardBorder,
                  icon: Icons.person_outline_rounded,
                ),
                const SizedBox(height: 16),

                // Password + Generator button
                _buildEditTextField(
                  label: 'Password',
                  controller: _passwordController,
                  isDark: isDark,
                  cardBorder: cardBorder,
                  icon: Icons.lock_outline_rounded,
                  suffixAction: IconButton(
                    tooltip: 'Generate Random Password',
                    icon: const Icon(Icons.casino_outlined, size: 20, color: Color(0xFF0A85EA)),
                    onPressed: _generateRandomPassword,
                  ),
                ),
                const SizedBox(height: 16),

                // Website URL
                _buildEditTextField(
                  label: 'Website URL',
                  controller: _urlController,
                  isDark: isDark,
                  cardBorder: cardBorder,
                  icon: Icons.link_rounded,
                ),
                const SizedBox(height: 16),

                // Notes
                _buildEditTextField(
                  label: 'Notes',
                  controller: _notesController,
                  isDark: isDark,
                  cardBorder: cardBorder,
                  icon: Icons.notes_rounded,
                  maxLines: 4,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditTextField({
    required String label,
    required TextEditingController controller,
    required bool isDark,
    required Color cardBorder,
    required IconData icon,
    Widget? suffixAction,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.white : Colors.black87,
          ),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, size: 20, color: Colors.grey),
            suffixIcon: suffixAction,
            filled: true,
            fillColor: isDark ? KeyNestPalette.surfaceDark : Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: cardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF0A85EA), width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
