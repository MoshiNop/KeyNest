import 'dart:async';
import 'dart:math' as math;
import 'package:autofill_service/autofill_service.dart';
import 'package:autofill_shared/credential_matcher.dart';
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_dynamic_icon_service.dart';
import 'package:keynest/services/keynest_pending_login_memory.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/animations.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/ui/screens/locked_screen.dart';
import 'package:keynest/ui/screens/password_generator.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:keynest/ui/widgets/keynest_popup_menu.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/password_generator.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

final _logger = Logger('keynest_autofill_sheet');

enum _AutofillViewMode { suggested, allLogins }

class KeyNestAutofillSheet extends StatefulWidget {
  const KeyNestAutofillSheet({
    super.key,
    required this.kdbxBloc,
    this.onClose,
  });

  final KdbxBloc kdbxBloc;
  final VoidCallback? onClose;

  static Route<void> route({required KdbxBloc kdbxBloc}) {
    return PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: KeyNestTokens.durationScreenEnter,
      reverseTransitionDuration: KeyNestTokens.durationNormal,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: KeyNestTokens.fastOutSlowIn,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.0, 0.20),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(
            opacity: curved,
            child: child,
          ),
        );
      },
      pageBuilder: (context, anim, secAnim) {
        return Provider<KdbxBloc>.value(
          value: kdbxBloc,
          child: KeyNestAutofillSheet(
            kdbxBloc: kdbxBloc,
            onClose: () {
              Navigator.of(context).pop();
            },
          ),
        );
      },
    );
  }

  @override
  State<KeyNestAutofillSheet> createState() => _KeyNestAutofillSheetState();
}

class _KeyNestAutofillSheetState extends State<KeyNestAutofillSheet> {
  AutofillMetadata? _metadata;
  List<CredentialRequest> _requests = [];
  bool _isLoading = true;
  bool _hasFilled = false;
  _AutofillViewMode _viewMode = _AutofillViewMode.suggested;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // Vault and Folder Navigation Filter (null = All Vaults / All Folders)
  KdbxFile? _selectedNavVault;
  KdbxGroup? _selectedNavGroup;

  // New Login Form State & Focus Management for Keyboard Resizing
  bool _isCreatingNewLogin = false;
  bool _isSavingNewLogin = false;
  String? _newLoginErrorMessage;
  final ScrollController _newLoginScrollController = ScrollController();
  final FocusNode _newTitleFocusNode = FocusNode();
  final FocusNode _newUrlFocusNode = FocusNode();
  final FocusNode _newUsernameFocusNode = FocusNode();
  final FocusNode _newPasswordFocusNode = FocusNode();
  final TextEditingController _newTitleController = TextEditingController();
  final TextEditingController _newUrlController = TextEditingController();
  final TextEditingController _newUsernameController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  bool _obscureNewPassword = true;
  KdbxFile? _newSelectedFile;
  KdbxGroup? _newSelectedGroup;
  Timer? _scrollDebounceTimer;

  // Caching to eliminate repeated database traversal during keyboard animations
  Set<String>? _cachedAllUsernames;
  List<String>? _cachedUsernameSuggestions;
  String? _lastQueryForSuggestions;
  KdbxFile? _cachedFolderOptionsFile;
  List<({KdbxGroup group, String displayName})>? _cachedFolderOptions;

  void _invalidateCaches() {
    _cachedAllUsernames = null;
    _cachedUsernameSuggestions = null;
    _lastQueryForSuggestions = null;
    _cachedFolderOptionsFile = null;
    _cachedFolderOptions = null;
  }

  @override
  void initState() {
    super.initState();
    _newTitleFocusNode.addListener(_onFieldFocused);
    _newUrlFocusNode.addListener(_onFieldFocused);
    _newPasswordFocusNode.addListener(_onFieldFocused);
    _newUsernameFocusNode.addListener(_onFieldFocused);
    _loadAutofillMetadata();
  }

  FocusNode? _getActiveFieldFocusNode() {
    if (_newTitleFocusNode.hasFocus) {
      return _newTitleFocusNode;
    }
    if (_newUrlFocusNode.hasFocus) {
      return _newUrlFocusNode;
    }
    if (_newUsernameFocusNode.hasFocus) {
      return _newUsernameFocusNode;
    }
    if (_newPasswordFocusNode.hasFocus) {
      return _newPasswordFocusNode;
    }
    return null;
  }

  void _onFieldFocused() {
    final activeNode = _getActiveFieldFocusNode();
    if (activeNode == null) {
      return;
    }

    _scrollDebounceTimer?.cancel();
    // Debounce ensureVisible to allow keyboard insets and AnimatedContainer to settle
    // smoothly without clashing animations or scroll controller fighting
    _scrollDebounceTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted || !_newLoginScrollController.hasClients) {
        return;
      }
      final fieldContext = activeNode.context;
      if (fieldContext != null && fieldContext.mounted) {
        Scrollable.ensureVisible(
          fieldContext,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollDebounceTimer?.cancel();
    _searchController.dispose();
    _newTitleFocusNode.removeListener(_onFieldFocused);
    _newUrlFocusNode.removeListener(_onFieldFocused);
    _newPasswordFocusNode.removeListener(_onFieldFocused);
    _newUsernameFocusNode.removeListener(_onFieldFocused);
    _newPasswordFocusNode.dispose();
    _newUsernameFocusNode.dispose();
    _newTitleFocusNode.dispose();
    _newUrlFocusNode.dispose();
    _newLoginScrollController.dispose();
    _newTitleController.dispose();
    _newUrlController.dispose();
    _newUsernameController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadAutofillMetadata() async {
    try {
      if (widget.kdbxBloc.openedFilesKdbx.isEmpty &&
          widget.kdbxBloc.canSilentQuickUnlock() &&
          mounted) {
        final loc = AppLocalizations.of(context);
        await widget.kdbxBloc.reopenQuickUnlock(loc, null, true);
      }
      final reqInfo = await AutofillService().getAutofillRequestInfo();
      final meta = await AutofillService().getAutofillMetadata();
      final reqs = <CredentialRequest>[];

      if (meta != null) {
        for (final domain in meta.webDomains) {
          if (domain.domain.isNotEmpty) {
            reqs.add(CredentialRequest.web('https://${domain.domain}'));
          }
        }

        for (final pkg in meta.packageNames) {
          if (pkg.isNotEmpty) {
            reqs.add(CredentialRequest.application(pkg));
          }
        }
      }

      if (mounted) {
        setState(() {
          _metadata = meta;
          _requests = reqs;
          _isLoading = false;
          if (reqInfo.forcePicker) {
            _viewMode = _AutofillViewMode.allLogins;
          }
        });
      }
    } catch (e, stack) {
      _logger.warning('Failed to load autofill metadata', e, stack);
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<
    ({
      KdbxEntry entry,
      CredentialMatchQuality? quality,
      int score,
      bool isCarryover,
    })
  >
  _getMatchingEntries() {
    final matcher = CredentialMatcher.instance;
    final results =
        <
          ({
            KdbxEntry entry,
            CredentialMatchQuality? quality,
            int score,
            bool isCarryover,
          })
        >[];

    final openFiles = widget.kdbxBloc.openedFilesKdbx;
    final targetContext = _formatTargetTitle();
    final remembered = KeyNestPendingLoginMemory.instance.getRemembered(
      targetContext,
    );

    for (final file in openFiles) {
      if (_selectedNavVault != null && file != _selectedNavVault) {
        continue;
      }
      if (_selectedNavGroup != null && _selectedNavGroup!.file != file) {
        continue;
      }
      final entries = _selectedNavGroup != null
          ? _selectedNavGroup!.getAllEntries()
          : file.body.rootGroup.getAllEntries();
      for (final entry in entries) {
        if (entry.isInRecycleBin()) {
          continue;
        }

        final autofillUrls = entry.autofillUrls;
        final rawUrl = entry.getString(KdbxKeyCommon.URL)?.getText()?.trim();
        final allUrls = <String>[...autofillUrls.map((u) => u.toString())];
        if (rawUrl != null && rawUrl.isNotEmpty && !allUrls.contains(rawUrl)) {
          allUrls.add(rawUrl);
        }

        CredentialMatchQuality? matchQuality;
        if (_requests.isNotEmpty) {
          matchQuality = matcher.matchBest(_requests, allUrls);
        }

        final search = _searchQuery.trim().toLowerCase();
        final title = entry.label?.toLowerCase() ?? '';
        final username =
            entry
                .getString(KdbxKeyCommon.USER_NAME)
                ?.getText()
                ?.toLowerCase() ??
            '';
        final url =
            entry.getString(KdbxKeyCommon.URL)?.getText()?.toLowerCase() ?? '';

        final matchesSearch =
            search.isEmpty ||
            title.contains(search) ||
            username.contains(search) ||
            url.contains(search);

        if (!matchesSearch) {
          continue;
        }

        final isCarryover =
            remembered != null &&
            (entry.uuid.uuid == remembered.entryUuid ||
                (username.isNotEmpty &&
                    username == remembered.username.toLowerCase()));

        if (matchQuality != null || isCarryover) {
          int score = 0;
          if (isCarryover) {
            score += 1000; // Step 2 multi-step carryover takes highest priority
          }
          if (matchQuality != null) {
            score += 100 - (matchQuality.index * 20);
          }
          if (search.isNotEmpty && title.startsWith(search)) {
            score += 15;
          }
          results.add((
            entry: entry,
            quality: matchQuality,
            score: score,
            isCarryover: isCarryover,
          ));
        }
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  List<
    ({
      KdbxEntry entry,
      CredentialMatchQuality? quality,
      int score,
      bool isCarryover,
    })
  >
  _getAllVaultEntries() {
    final matcher = CredentialMatcher.instance;
    final results =
        <
          ({
            KdbxEntry entry,
            CredentialMatchQuality? quality,
            int score,
            bool isCarryover,
          })
        >[];

    final openFiles = widget.kdbxBloc.openedFilesKdbx;
    final targetContext = _formatTargetTitle();
    final remembered = KeyNestPendingLoginMemory.instance.getRemembered(
      targetContext,
    );

    for (final file in openFiles) {
      if (_selectedNavVault != null && file != _selectedNavVault) {
        continue;
      }
      if (_selectedNavGroup != null && _selectedNavGroup!.file != file) {
        continue;
      }
      final entries = _selectedNavGroup != null
          ? _selectedNavGroup!.getAllEntries()
          : file.body.rootGroup.getAllEntries();
      for (final entry in entries) {
        if (entry.isInRecycleBin()) {
          continue;
        }

        final autofillUrls = entry.autofillUrls;
        final rawUrl = entry.getString(KdbxKeyCommon.URL)?.getText()?.trim();
        final allUrls = <String>[...autofillUrls.map((u) => u.toString())];
        if (rawUrl != null && rawUrl.isNotEmpty && !allUrls.contains(rawUrl)) {
          allUrls.add(rawUrl);
        }

        CredentialMatchQuality? matchQuality;
        if (_requests.isNotEmpty) {
          matchQuality = matcher.matchBest(_requests, allUrls);
        }

        final search = _searchQuery.trim().toLowerCase();
        final title = entry.label?.toLowerCase() ?? '';
        final username =
            entry
                .getString(KdbxKeyCommon.USER_NAME)
                ?.getText()
                ?.toLowerCase() ??
            '';
        final url =
            entry.getString(KdbxKeyCommon.URL)?.getText()?.toLowerCase() ?? '';

        final matchesSearch =
            search.isEmpty ||
            title.contains(search) ||
            username.contains(search) ||
            url.contains(search);

        if (!matchesSearch) {
          continue;
        }

        final isCarryover =
            remembered != null &&
            (entry.uuid.uuid == remembered.entryUuid ||
                (username.isNotEmpty &&
                    username == remembered.username.toLowerCase()));

        int score = 0;
        if (isCarryover) {
          score += 1000;
        }
        if (matchQuality != null) {
          score += 100 - (matchQuality.index * 20);
        }
        if (search.isNotEmpty && title.startsWith(search)) {
          score += 15;
        }

        results.add((
          entry: entry,
          quality: matchQuality,
          score: score,
          isCarryover: isCarryover,
        ));
      }
    }

    results.sort((a, b) {
      if (b.score != a.score) {
        return b.score.compareTo(a.score);
      }
      return (a.entry.label ?? '').toLowerCase().compareTo(
        (b.entry.label ?? '').toLowerCase(),
      );
    });
    return results;
  }

  Future<bool> _confirmOriginMismatch(KdbxEntry entry) async {
    final entryUrl =
        entry.getString(KdbxKeyCommon.URL)?.getText()?.trim() ??
        entry.label ??
        'this entry';
    final target = _formatTargetTitle();

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: KeyNestPalette.warning,
              size: 24,
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Website Mismatch Warning',
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(
            'This login is saved for "$entryUrl", but you are currently filling into "$target".\n\n'
            'Filling credentials into an unrelated website may expose your password to phishing or unintended recipients.\n\n'
            'Are you sure you want to fill this credential into $target?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: KeyNestPalette.warning,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Fill Anyway'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _fillEntry(KdbxEntry entry) async {
    // Check origin match: require explicit confirmation if credential belongs to a different website
    if (_requests.isNotEmpty) {
      final autofillUrls = entry.autofillUrls;
      final rawUrl = entry.getString(KdbxKeyCommon.URL)?.getText()?.trim();
      final allUrls = <String>[...autofillUrls];
      if (rawUrl != null && rawUrl.isNotEmpty && !allUrls.contains(rawUrl)) {
        allUrls.add(rawUrl);
      }

      final quality = CredentialMatcher.instance.matchBest(_requests, allUrls);
      final isMatchingOrigin =
          quality == CredentialMatchQuality.host ||
          quality == CredentialMatchQuality.registrableDomain ||
          quality == CredentialMatchQuality.application;

      if (!isMatchingOrigin) {
        final confirmed = await _confirmOriginMismatch(entry);
        if (!confirmed) {
          return;
        }
      }
    }

    final username = entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
    final email = entry.getString(KdbxKey('Email'))?.getText()?.trim() ?? '';
    final password = entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
    final otp = EntryTotpHelper.getLiveTotpCode(entry);

    final contextKey = _targetContextKey();
    final effectiveContext = contextKey.isNotEmpty
        ? contextKey
        : _formatTargetTitle();

    KeyNestPendingLoginMemory.instance.remember(
      entryUuid: entry.uuid.uuid,
      verifiedContext: effectiveContext,
      username: username.isNotEmpty ? username : email,
    );
    await AutofillService().rememberPendingLogin(
      entryId: entry.uuid.uuid,
      verifiedContext: effectiveContext,
      username: username.isNotEmpty ? username : email,
    );

    try {
      _hasFilled = true;
      QuickUnlockStorage.touchSession();
      unawaited(AutofillService().touchActive());
      await AutofillService().resultWithDataset(
        id: entry.uuid.uuid,
        label: entry.label,
        username: username,
        email: email.isNotEmpty ? email : null,
        password: password,
        otp: otp,
      );
    } catch (e, stack) {
      _logger.warning('Failed to fill credentials', e, stack);
      _hasFilled = false;
    } finally {
      if (mounted) {
        if (!_hasFilled) {
          widget.onClose?.call();
        } else {
          Navigator.of(context).pop();
        }
      }
    }
  }

  Future<void> _fillCredentialsDirect(
    String username,
    String password, [
    String? otp,
  ]) async {
    try {
      _hasFilled = true;
      QuickUnlockStorage.touchSession();
      unawaited(AutofillService().touchActive());
      await AutofillService().resultWithDataset(
        username: username,
        password: password,
        otp: otp,
      );
    } catch (e, stack) {
      _logger.warning('Failed to fill credentials direct', e, stack);
      _hasFilled = false;
    } finally {
      if (mounted) {
        if (!_hasFilled) {
          widget.onClose?.call();
        } else {
          Navigator.of(context).pop();
        }
      }
    }
  }

  String _formatTargetTitle() {
    final meta = _metadata;
    if (meta == null) {
      return 'KeyNest Autofill';
    }
    if (meta.webDomains.isNotEmpty) {
      final domain = meta.webDomains.first.domain;
      if (domain.isNotEmpty) {
        return domain;
      }
    }
    if (meta.packageNames.isNotEmpty) {
      final pkg = meta.packageNames.first;
      if (pkg.isNotEmpty) {
        final parts = pkg.split('.');
        if (parts.length >= 2) {
          final candidate = parts.last;
          return candidate[0].toUpperCase() + candidate.substring(1);
        }
        return pkg;
      }
    }
    return 'KeyNest Autofill';
  }

  String _targetContextKey() {
    final meta = _metadata;
    if (meta == null) {
      return '';
    }
    if (meta.webDomains.isNotEmpty) {
      final domain = meta.webDomains.first.domain;
      if (domain.isNotEmpty) {
        return domain;
      }
    }
    if (meta.packageNames.isNotEmpty) {
      final pkg = meta.packageNames.first;
      if (pkg.isNotEmpty) {
        return pkg;
      }
    }
    return '';
  }

  bool _isUnverifiedContext(
    List<
      ({
        KdbxEntry entry,
        CredentialMatchQuality? quality,
        int score,
        bool isCarryover,
      })
    >
    matches,
  ) {
    final meta = _metadata;
    if (meta == null) {
      return false;
    }
    if (meta.webDomains.isNotEmpty && matches.isNotEmpty) {
      final hasExactOrDomain = matches.any(
        (m) =>
            m.quality == CredentialMatchQuality.host ||
            m.quality == CredentialMatchQuality.registrableDomain,
      );
      return !hasExactOrDomain;
    }
    return false;
  }

  String _qualityLabel(CredentialMatchQuality? quality, bool isCarryover) {
    if (isCarryover) {
      return 'Continue Login';
    }
    switch (quality) {
      case CredentialMatchQuality.host:
        return 'Exact Match';
      case CredentialMatchQuality.registrableDomain:
        return 'Domain Match';
      case CredentialMatchQuality.application:
        return 'App Match';
      case CredentialMatchQuality.associatedApplication:
        return 'Associated App';
      case null:
        return 'Vault Login';
    }
  }

  Color _qualityColor(CredentialMatchQuality? quality, bool isCarryover) {
    if (isCarryover) {
      return KeyNestPalette.accent;
    }
    switch (quality) {
      case CredentialMatchQuality.host:
        return KeyNestPalette.success;
      case CredentialMatchQuality.registrableDomain:
        return KeyNestPalette.primary;
      case CredentialMatchQuality.application:
      case CredentialMatchQuality.associatedApplication:
        return KeyNestPalette.accent;
      case null:
        return KeyNestPalette.textSecondaryLight;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final suggestedMatches = _isCreatingNewLogin
        ? const <
            ({
              KdbxEntry entry,
              CredentialMatchQuality? quality,
              int score,
              bool isCarryover,
            })
          >[]
        : _getMatchingEntries();
    final allLogins = _isCreatingNewLogin
        ? const <
            ({
              KdbxEntry entry,
              CredentialMatchQuality? quality,
              int score,
              bool isCarryover,
            })
          >[]
        : _getAllVaultEntries();
    final targetTitle = _formatTargetTitle();
    final openedFiles = widget.kdbxBloc.openedFilesKdbx;
    final isUnverified =
        !_isCreatingNewLogin && _isUnverifiedContext(suggestedMatches);

    final hasDirectMatches = suggestedMatches.isNotEmpty;
    final effectiveMode = (hasDirectMatches && _searchQuery.isEmpty)
        ? _viewMode
        : _AutofillViewMode.allLogins;
    final displayEntries = effectiveMode == _AutofillViewMode.suggested
        ? suggestedMatches
        : allLogins;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_hasFilled) {
          AutofillService().cancelAutofill();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availableHeight = constraints.maxHeight;
              final dialogMaxHeight = math.min(
                680.0,
                math.max(260.0, availableHeight - 24.0),
              );

              return Center(
                child: Material(
                  color: Colors.transparent,
                  child: RepaintBoundary(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      constraints: BoxConstraints(
                        maxWidth: 520,
                        maxHeight: dialogMaxHeight,
                      ),
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? KeyNestPalette.cardDark
                            : KeyNestPalette.cardLight,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDark ? 0.5 : 0.2,
                            ),
                            blurRadius: 30,
                            offset: const Offset(0, 10),
                          ),
                        ],
                        border: Border.all(
                          color: isDark
                              ? KeyNestPalette.entryBorderDark
                              : KeyNestPalette.entryBorderLight,
                        ),
                      ),
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 240),
                        curve: KeyNestTokens.fastOutSlowIn,
                        alignment: Alignment.topCenter,
                        child: AnimatedSwitcher(
                          duration: KeyNestTokens.durationScreenEnter,
                          reverseDuration: KeyNestTokens.durationNormal,
                          switchInCurve: KeyNestTokens.fastOutSlowIn,
                          switchOutCurve: Curves.easeInCubic,
                          layoutBuilder: (currentChild, previousChildren) =>
                              Stack(
                                alignment: Alignment.topCenter,
                                children: <Widget>[
                                  ...previousChildren,
                                  ?currentChild,
                                ],
                              ),
                          transitionBuilder: (child, animation) {
                            return KeyNestScreenTransition(
                              animation: animation,
                              child: child,
                            );
                          },
                          child: _isCreatingNewLogin
                              ? KeyedSubtree(
                                  key: const ValueKey('new_login_view'),
                                  child: _buildNewLoginView(isDark, theme),
                                )
                              : KeyedSubtree(
                                  key: const ValueKey('sheet_main_view'),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Header
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          20,
                                          18,
                                          16,
                                          12,
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.all(8),
                                              decoration: BoxDecoration(
                                                color:
                                                    (isDark
                                                            ? KeyNestPalette
                                                                  .primaryDark
                                                            : KeyNestPalette
                                                                  .primary)
                                                        .withValues(
                                                          alpha: 0.12,
                                                        ),
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Icon(
                                                Icons.key_rounded,
                                                color: isDark
                                                    ? KeyNestPalette.primaryDark
                                                    : KeyNestPalette.primary,
                                                size: 22,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      Flexible(
                                                        child: Text(
                                                          targetTitle,
                                                          style: theme
                                                              .textTheme
                                                              .titleMedium
                                                              ?.copyWith(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                fontSize: 17,
                                                                decoration:
                                                                    TextDecoration
                                                                        .none,
                                                              ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 6),
                                                      Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 6,
                                                              vertical: 2,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color:
                                                              (isDark
                                                                      ? KeyNestPalette
                                                                            .primaryDark
                                                                      : KeyNestPalette
                                                                            .primary)
                                                                  .withValues(
                                                                    alpha: 0.12,
                                                                  ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                6,
                                                              ),
                                                        ),
                                                        child: Text(
                                                          'KeyNest',
                                                          style: TextStyle(
                                                            fontSize: 10,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            color: isDark
                                                                ? KeyNestPalette
                                                                      .primaryDark
                                                                : KeyNestPalette
                                                                      .primary,
                                                            decoration:
                                                                TextDecoration
                                                                    .none,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    openedFiles.isEmpty
                                                        ? 'No vaults unlocked'
                                                        : (hasDirectMatches
                                                              ? '${suggestedMatches.length} matching account${suggestedMatches.length == 1 ? '' : 's'}'
                                                              : '${allLogins.length} vault credential${allLogins.length == 1 ? '' : 's'}'),
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      decoration:
                                                          TextDecoration.none,
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
                                            IconButton(
                                              icon: const Icon(
                                                Icons.close_rounded,
                                              ),
                                              onPressed: () {
                                                if (!_hasFilled) {
                                                  AutofillService()
                                                      .cancelAutofill();
                                                }
                                                if (Navigator.of(
                                                  context,
                                                ).canPop()) {
                                                  Navigator.of(context).pop();
                                                } else {
                                                  final appData = widget
                                                      .kdbxBloc
                                                      .appDataBloc
                                                      .store
                                                      .cachedValue;
                                                  final hasPreviousFiles =
                                                      appData != null &&
                                                      appData
                                                          .previousFiles
                                                          .isNotEmpty;
                                                  final baseRoute =
                                                      (hasPreviousFiles
                                                              ? LockedScreen.route()
                                                              : SelectFileScreen.route())
                                                          as Route<dynamic>;
                                                  Navigator.of(
                                                    context,
                                                  ).pushReplacement(baseRoute);
                                                }
                                              },
                                              tooltip: 'Cancel',
                                            ),
                                          ],
                                        ),
                                      ),

                                      if (isUnverified)
                                        Container(
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 4,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: KeyNestPalette.warning
                                                .withValues(alpha: 0.12),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(
                                              color: KeyNestPalette.warning
                                                  .withValues(alpha: 0.3),
                                            ),
                                          ),
                                          child: const Row(
                                            children: [
                                              Icon(
                                                Icons.warning_amber_rounded,
                                                size: 18,
                                                color: KeyNestPalette.warning,
                                              ),
                                              SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Unverified origin: Please verify website before filling.',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color:
                                                        KeyNestPalette.warning,
                                                    decoration:
                                                        TextDecoration.none,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),

                                      const Divider(height: 1),

                                      // Search Bar
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                        child: TextField(
                                          controller: _searchController,
                                          decoration: InputDecoration(
                                            hintText: 'Search all logins...',
                                            prefixIcon: const Icon(
                                              Icons.search_rounded,
                                              size: 20,
                                            ),
                                            suffixIcon: _searchQuery.isNotEmpty
                                                ? IconButton(
                                                    icon: const Icon(
                                                      Icons.clear_rounded,
                                                      size: 18,
                                                    ),
                                                    onPressed: () {
                                                      setState(() {
                                                        _searchController
                                                            .clear();
                                                        _searchQuery = '';
                                                      });
                                                    },
                                                  )
                                                : null,
                                            isDense: true,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 14,
                                                  vertical: 10,
                                                ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: BorderSide(
                                                color: isDark
                                                    ? KeyNestPalette
                                                          .entryBorderDark
                                                    : KeyNestPalette
                                                          .entryBorderLight,
                                              ),
                                            ),
                                            filled: true,
                                            fillColor: isDark
                                                ? KeyNestPalette.surfaceDark
                                                : KeyNestPalette.surfaceLight,
                                          ),
                                          onChanged: (val) {
                                            setState(() {
                                              _searchQuery = val;
                                            });
                                          },
                                        ),
                                      ),

                                      // Mode Selector / Guidance Banner
                                      if (hasDirectMatches &&
                                          _searchQuery.isEmpty)
                                        _buildModeSelector(
                                          isDark: isDark,
                                          suggestedCount:
                                              suggestedMatches.length,
                                          allCount: allLogins.length,
                                        )
                                      else if (!hasDirectMatches &&
                                          _searchQuery.isEmpty &&
                                          allLogins.isNotEmpty)
                                        Container(
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 4,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                (isDark
                                                        ? KeyNestPalette
                                                              .primaryDark
                                                        : KeyNestPalette
                                                              .primary)
                                                    .withValues(
                                                      alpha: isDark
                                                          ? 0.16
                                                          : 0.08,
                                                    ),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.info_outline_rounded,
                                                size: 16,
                                                color: isDark
                                                    ? KeyNestPalette.primaryDark
                                                    : KeyNestPalette.primary,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'No direct match for "$targetTitle". Select any credential from your vault below:',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    decoration:
                                                        TextDecoration.none,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),

                                      // Vault & Folder Navigation Filter Bar
                                      _buildVaultAndFolderNavBar(
                                        isDark: isDark,
                                        theme: theme,
                                        openedFiles: openedFiles,
                                      ),

                                      // Content Area
                                      Flexible(
                                        child: _isLoading
                                            ? const Center(
                                                child: Padding(
                                                  padding: EdgeInsets.all(32),
                                                  child:
                                                      CircularProgressIndicator(),
                                                ),
                                              )
                                            : openedFiles.isEmpty
                                            ? _buildLockedVaultsView(
                                                isDark,
                                                theme,
                                              )
                                            : displayEntries.isEmpty
                                            ? _buildNoMatchesView(isDark, theme)
                                            : ListView.separated(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 8,
                                                    ),
                                                itemCount:
                                                    displayEntries.length,
                                                separatorBuilder: (ctx, idx) =>
                                                    const SizedBox(height: 8),
                                                itemBuilder: (context, index) {
                                                  final item =
                                                      displayEntries[index];
                                                  final entry = item.entry;
                                                  final quality = item.quality;
                                                  final isCarryover =
                                                      item.isCarryover;
                                                  final username =
                                                      entry
                                                          .getString(
                                                            KdbxKeyCommon
                                                                .USER_NAME,
                                                          )
                                                          ?.getText() ??
                                                      '';
                                                  final hasTotp =
                                                      EntryTotpHelper.hasTotp(
                                                        entry,
                                                      );

                                                  final cardBg = isCarryover
                                                      ? KeyNestPalette
                                                            .primaryDark
                                                            .withValues(
                                                              alpha: 0.12,
                                                            )
                                                      : (quality ==
                                                                CredentialMatchQuality
                                                                    .host
                                                            ? KeyNestPalette
                                                                  .primaryDark
                                                                  .withValues(
                                                                    alpha: 0.08,
                                                                  )
                                                            : (isDark
                                                                      ? KeyNestTokens
                                                                            .darkSurfaceVariant
                                                                      : const Color(
                                                                          0xFFF4F7FC,
                                                                        ))
                                                                  .withValues(
                                                                    alpha:
                                                                        isDark
                                                                        ? 0.85
                                                                        : 0.95,
                                                                  ));
                                                  final cardBorder = isCarryover
                                                      ? KeyNestPalette
                                                            .primaryDark
                                                            .withValues(
                                                              alpha: 0.6,
                                                            )
                                                      : (quality ==
                                                                CredentialMatchQuality
                                                                    .host
                                                            ? KeyNestPalette
                                                                  .primaryDark
                                                                  .withValues(
                                                                    alpha: 0.45,
                                                                  )
                                                            : (isDark
                                                                  ? KeyNestPalette
                                                                        .entryBorderDark
                                                                  : KeyNestPalette
                                                                        .entryBorderLight));

                                                  return InkWell(
                                                    onTap: () =>
                                                        _fillEntry(entry),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          16,
                                                        ),
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            12,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: cardBg,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              16,
                                                            ),
                                                        border: Border.all(
                                                          color: cardBorder,
                                                        ),
                                                      ),
                                                      child: Row(
                                                        children: [
                                                          _buildEntryLeadingIcon(
                                                            entry,
                                                            isCarryover,
                                                          ),
                                                          const SizedBox(
                                                            width: 12,
                                                          ),
                                                          Expanded(
                                                            child: Column(
                                                              crossAxisAlignment:
                                                                  CrossAxisAlignment
                                                                      .start,
                                                              children: [
                                                                Row(
                                                                  children: [
                                                                    Flexible(
                                                                      child: Text(
                                                                        entry.label ??
                                                                            'Entry',
                                                                        style: const TextStyle(
                                                                          fontWeight:
                                                                              FontWeight.bold,
                                                                          fontSize:
                                                                              14.5,
                                                                        ),
                                                                        maxLines:
                                                                            1,
                                                                        overflow:
                                                                            TextOverflow.ellipsis,
                                                                      ),
                                                                    ),
                                                                    const SizedBox(
                                                                      width: 6,
                                                                    ),
                                                                    if (quality !=
                                                                            null ||
                                                                        isCarryover)
                                                                      Container(
                                                                        padding: const EdgeInsets.symmetric(
                                                                          horizontal:
                                                                              7,
                                                                          vertical:
                                                                              2,
                                                                        ),
                                                                        decoration: BoxDecoration(
                                                                          color:
                                                                              _qualityColor(
                                                                                quality,
                                                                                isCarryover,
                                                                              ).withValues(
                                                                                alpha: 0.15,
                                                                              ),
                                                                          borderRadius:
                                                                              BorderRadius.circular(
                                                                                6,
                                                                              ),
                                                                        ),
                                                                        child: Text(
                                                                          _qualityLabel(
                                                                            quality,
                                                                            isCarryover,
                                                                          ),
                                                                          style: TextStyle(
                                                                            fontSize:
                                                                                10,
                                                                            fontWeight:
                                                                                FontWeight.w700,
                                                                            color: _qualityColor(
                                                                              quality,
                                                                              isCarryover,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                      ),
                                                                  ],
                                                                ),
                                                                const SizedBox(
                                                                  height: 3,
                                                                ),
                                                                Text(
                                                                  username.isNotEmpty
                                                                      ? username
                                                                      : 'No username',
                                                                  style: TextStyle(
                                                                    fontSize:
                                                                        13,
                                                                    color:
                                                                        isDark
                                                                        ? KeyNestPalette
                                                                              .textSecondaryDark
                                                                        : KeyNestPalette
                                                                              .textSecondaryLight,
                                                                  ),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                ),
                                                                if (hasTotp) ...[
                                                                  const SizedBox(
                                                                    height: 4,
                                                                  ),
                                                                  Row(
                                                                    children: [
                                                                      Icon(
                                                                        Icons
                                                                            .timer_outlined,
                                                                        size:
                                                                            13,
                                                                        color:
                                                                            isDark
                                                                            ? KeyNestPalette.primaryDark
                                                                            : KeyNestPalette.primary,
                                                                      ),
                                                                      const SizedBox(
                                                                        width:
                                                                            4,
                                                                      ),
                                                                      Text(
                                                                        '2FA Code ready',
                                                                        style: TextStyle(
                                                                          fontSize:
                                                                              11,
                                                                          fontWeight:
                                                                              FontWeight.w500,
                                                                          color:
                                                                              isDark
                                                                              ? KeyNestPalette.primaryDark
                                                                              : KeyNestPalette.primary,
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ],
                                                              ],
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                          Icon(
                                                            Icons
                                                                .arrow_forward_ios_rounded,
                                                            size: 13,
                                                            color: isDark
                                                                ? KeyNestPalette
                                                                      .textTertiaryDark
                                                                : KeyNestPalette
                                                                      .textTertiaryLight,
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                      ),

                                      const Divider(height: 1),

                                      // Bottom Actions (New Login + Password Generator + Close)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 12,
                                        ),
                                        child: Row(
                                          children: [
                                            FilledButton.icon(
                                              icon: const Icon(
                                                Icons.add_rounded,
                                                size: 16,
                                              ),
                                              label: const Text('New Login'),
                                              style: FilledButton.styleFrom(
                                                backgroundColor: isDark
                                                    ? KeyNestPalette.primaryDark
                                                    : KeyNestPalette.primary,
                                                foregroundColor: isDark
                                                    ? const Color(0xFF00315D)
                                                    : Colors.white,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        KeyNestShapes
                                                            .radiusPill,
                                                      ),
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 10,
                                                    ),
                                                textStyle: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              onPressed: openedFiles.isEmpty
                                                  ? null
                                                  : _startNewLoginFlow,
                                            ),
                                            const SizedBox(width: 8),
                                            OutlinedButton.icon(
                                              icon: const Icon(
                                                Icons.password_rounded,
                                                size: 16,
                                              ),
                                              label: const Text('Generate'),
                                              style: OutlinedButton.styleFrom(
                                                side: BorderSide(
                                                  color: isDark
                                                      ? Colors.white.withValues(
                                                          alpha: 0.15,
                                                        )
                                                      : Colors.black.withValues(
                                                          alpha: 0.12,
                                                        ),
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        KeyNestShapes
                                                            .radiusPill,
                                                      ),
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 14,
                                                      vertical: 10,
                                                    ),
                                                textStyle: const TextStyle(
                                                  fontWeight: FontWeight.w500,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              onPressed: () async {
                                                final generated =
                                                    await Navigator.of(
                                                      context,
                                                    ).push<String>(
                                                      PasswordGeneratorScreen.route(
                                                        finishButton:
                                                            FinishButtonStyle
                                                                .done,
                                                      ),
                                                    );
                                                if (generated != null &&
                                                    generated.isNotEmpty) {
                                                  await _fillCredentialsDirect(
                                                    '',
                                                    generated,
                                                  );
                                                }
                                              },
                                            ),
                                            const Spacer(),
                                            TextButton(
                                              style: TextButton.styleFrom(
                                                foregroundColor: isDark
                                                    ? KeyNestPalette
                                                          .textSecondaryDark
                                                    : KeyNestPalette
                                                          .textSecondaryLight,
                                              ),
                                              onPressed: () {
                                                widget.onClose?.call();
                                              },
                                              child: const Text('Close'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _startNewLoginFlow() {
    final openedFiles = widget.kdbxBloc.openedFilesKdbx;
    if (openedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please unlock your KeyNest vault first to create a new login.',
          ),
          backgroundColor: KeyNestPalette.warning,
        ),
      );
      return;
    }

    final meta = _metadata;
    String detectedUrl = '';
    String defaultTitle = '';
    if (meta != null &&
        meta.webDomains.isNotEmpty &&
        meta.webDomains.first.domain.isNotEmpty) {
      final domain = meta.webDomains.first.domain;
      detectedUrl = 'https://$domain';
      defaultTitle = domain;
    } else if (meta != null &&
        meta.packageNames.isNotEmpty &&
        meta.packageNames.first.isNotEmpty) {
      final pkg = meta.packageNames.first;
      detectedUrl = 'androidapp://$pkg';
      final parts = pkg.split('.');
      defaultTitle = parts.length >= 2
          ? parts.last[0].toUpperCase() + parts.last.substring(1)
          : pkg;
    } else {
      defaultTitle = _formatTargetTitle();
      detectedUrl = '';
    }

    _invalidateCaches();
    _newSelectedFile = _selectedNavVault ?? openedFiles.firstOrNull;
    _newSelectedGroup = _selectedNavGroup ?? _newSelectedFile?.body.rootGroup;
    _newTitleController.text = defaultTitle;
    _newUrlController.text = detectedUrl;
    _newUsernameController.clear();
    _newPasswordController.clear();
    _obscureNewPassword = true;
    _newLoginErrorMessage = null;
    setState(() {
      _isCreatingNewLogin = true;
    });
  }

  void _generateNewPassword() {
    const chars = CharacterSetCollection([
      CharacterSet.alphaNumeric,
      CharacterSet.specialCharacters,
    ]);
    final pass = PasswordGenerator.singleton().generatePassword(chars, 20);
    setState(() {
      _newPasswordController.text = pass;
      _obscureNewPassword = false;
    });
  }

  Set<String> _getAllUsernames() {
    if (_cachedAllUsernames != null) {
      return _cachedAllUsernames!;
    }
    final allUsernames = <String>{};
    for (final f in widget.kdbxBloc.openedFilesKdbx) {
      for (final e in f.body.rootGroup.getAllEntries()) {
        if (e.isInRecycleBin()) {
          continue;
        }
        final u = e.getString(KdbxKeyCommon.USER_NAME)?.getText()?.trim();
        if (u != null && u.isNotEmpty) {
          allUsernames.add(u);
        }
      }
    }
    _cachedAllUsernames = allUsernames;
    return allUsernames;
  }

  List<String> _getUsernameSuggestions(String query) {
    if (_cachedUsernameSuggestions != null &&
        _lastQueryForSuggestions == query) {
      return _cachedUsernameSuggestions!;
    }
    final allUsernames = _getAllUsernames();
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      final list = allUsernames.take(5).toList();
      _cachedUsernameSuggestions = list;
      _lastQueryForSuggestions = query;
      return list;
    }
    final matches = <String>[];
    for (final u in allUsernames) {
      if (u.toLowerCase() == q) {
        continue;
      }
      if (_fuzzyMatch(u, q)) {
        matches.add(u);
      }
    }
    matches.sort((a, b) {
      final aLower = a.toLowerCase();
      final bLower = b.toLowerCase();
      final aContains = aLower.contains(q);
      final bContains = bLower.contains(q);
      if (aContains && !bContains) {
        return -1;
      }
      if (!aContains && bContains) {
        return 1;
      }
      final aStarts = aLower.startsWith(q);
      final bStarts = bLower.startsWith(q);
      if (aStarts && !bStarts) {
        return -1;
      }
      if (!aStarts && bStarts) {
        return 1;
      }
      return aLower.compareTo(bLower);
    });
    final list = matches.take(5).toList();
    _cachedUsernameSuggestions = list;
    _lastQueryForSuggestions = query;
    return list;
  }

  bool _fuzzyMatch(String text, String query) {
    final t = text.toLowerCase();
    final q = query.toLowerCase();
    if (t.contains(q)) {
      return true;
    }
    int ti = 0;
    for (int qi = 0; qi < q.length; qi++) {
      final idx = t.indexOf(q[qi], ti);
      if (idx == -1) {
        return false;
      }
      ti = idx + 1;
    }
    return true;
  }

  List<({KdbxGroup group, String displayName})> _getFolderOptions(
    KdbxFile? file,
  ) {
    if (file == null) {
      return const [];
    }
    if (_cachedFolderOptionsFile == file && _cachedFolderOptions != null) {
      return _cachedFolderOptions!;
    }
    final results = <({KdbxGroup group, String displayName})>[];

    void traverse(KdbxGroup group, int depth) {
      if (KeyNestItemTypeHelper.isTrashOrRecycleBin(group)) {
        return;
      }
      final rawName = group.name.get()?.trim();
      final name = (rawName != null && rawName.isNotEmpty)
          ? rawName
          : (depth == 0
                ? (file.body.meta.databaseName.get() ?? 'Root')
                : 'Folder');
      final prefix = depth == 0 ? '' : '${'   ' * depth}↳ ';
      results.add((group: group, displayName: '$prefix$name'));

      final sortedChildren = KeyNestItemTypeHelper.sortGroupsWithTrashLast(
        group.groups,
      );
      for (final child in sortedChildren) {
        traverse(child, depth + 1);
      }
    }

    traverse(file.body.rootGroup, 0);
    _cachedFolderOptionsFile = file;
    _cachedFolderOptions = results;
    return results;
  }

  Widget _buildModeSelector({
    required bool isDark,
    required int suggestedCount,
    required int allCount,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: isDark
              ? KeyNestPalette.surfaceDark
              : KeyNestPalette.surfaceLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark
                ? KeyNestPalette.entryBorderDark
                : KeyNestPalette.entryBorderLight,
          ),
        ),
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            Expanded(
              child: _buildModeSegment(
                label: 'Suggested ($suggestedCount)',
                icon: Icons.auto_awesome_rounded,
                isSelected: _viewMode == _AutofillViewMode.suggested,
                isDark: isDark,
                onTap: () =>
                    setState(() => _viewMode = _AutofillViewMode.suggested),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _buildModeSegment(
                label: 'All Credentials ($allCount)',
                icon: Icons.list_alt_rounded,
                isSelected: _viewMode == _AutofillViewMode.allLogins,
                isDark: isDark,
                onTap: () =>
                    setState(() => _viewMode = _AutofillViewMode.allLogins),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSegment({
    required String label,
    required IconData icon,
    required bool isSelected,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected
                ? (isDark
                      ? KeyNestPalette.primaryDark.withValues(alpha: 0.22)
                      : KeyNestPalette.primary.withValues(alpha: 0.12))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: isSelected
                  ? (isDark
                        ? KeyNestPalette.primaryDark.withValues(alpha: 0.5)
                        : KeyNestPalette.primary.withValues(alpha: 0.35))
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: isSelected
                    ? (isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary)
                    : (isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected
                        ? (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary)
                        : (isDark
                              ? KeyNestPalette.textSecondaryDark
                              : KeyNestPalette.textSecondaryLight),
                    decoration: TextDecoration.none,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVaultAndFolderNavBar({
    required bool isDark,
    required ThemeData theme,
    required List<KdbxFile> openedFiles,
  }) {
    if (openedFiles.isEmpty) {
      return const SizedBox.shrink();
    }

    final currentVaultName = _selectedNavVault != null
        ? KeyNestVaultScope.cleanVaultName(widget.kdbxBloc, _selectedNavVault!)
        : 'All Vaults';
    final currentFolderName = _selectedNavGroup != null
        ? (_selectedNavGroup!.name.get() ?? 'Folder')
        : 'All Folders';
    final isFiltered = _selectedNavVault != null || _selectedNavGroup != null;

    final targetFileForFolders = _selectedNavVault ?? openedFiles.firstOrNull;
    final folderOptions = _getFolderOptions(targetFileForFolders);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Vault Selector Pill
              KeyNestPopupMenuButton<KdbxFile?>(
                tooltip: 'Select Vault',
                color: isDark
                    ? KeyNestPalette.cardDark
                    : KeyNestPalette.cardLight,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                onSelected: (file) {
                  setState(() {
                    _selectedNavVault = file;
                    _selectedNavGroup = null;
                  });
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem<KdbxFile?>(
                    value: null,
                    child: Row(
                      children: [
                        Icon(
                          Icons.all_inbox_rounded,
                          size: 16,
                          color: _selectedNavVault == null
                              ? (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary)
                              : (isDark
                                    ? KeyNestPalette.textSecondaryDark
                                    : KeyNestPalette.textSecondaryLight),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'All Vaults',
                          style: TextStyle(
                            fontWeight: _selectedNavVault == null
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: _selectedNavVault == null
                                ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  ...openedFiles.map((f) {
                    final isSel = _selectedNavVault == f;
                    final name = KeyNestVaultScope.cleanVaultName(
                      widget.kdbxBloc,
                      f,
                    );
                    return PopupMenuItem<KdbxFile?>(
                      value: f,
                      child: Row(
                        children: [
                          Icon(
                            Icons.inventory_2_outlined,
                            size: 16,
                            color: isSel
                                ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                : null,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            name,
                            style: TextStyle(
                              fontWeight: isSel
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSel
                                  ? (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _selectedNavVault != null
                        ? (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                              .withValues(alpha: isDark ? 0.2 : 0.1)
                        : (isDark
                              ? KeyNestPalette.surfaceDark
                              : KeyNestPalette.surfaceLight),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _selectedNavVault != null
                          ? (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary)
                                .withValues(alpha: isDark ? 0.5 : 0.4)
                          : (isDark
                                ? KeyNestPalette.entryBorderDark
                                : KeyNestPalette.entryBorderLight),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.inventory_2_outlined,
                        size: 14,
                        color: _selectedNavVault != null
                            ? (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                            : (isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(
                          currentVaultName,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: _selectedNavVault != null
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: _selectedNavVault != null
                                ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                : (isDark
                                      ? KeyNestPalette.textSecondaryDark
                                      : KeyNestPalette.textSecondaryLight),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.arrow_drop_down,
                        size: 16,
                        color: _selectedNavVault != null
                            ? (isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary)
                            : (isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Folder Selector Pill
              KeyNestPopupMenuButton<KdbxGroup?>(
                tooltip: 'Select Folder',
                color: isDark
                    ? KeyNestPalette.cardDark
                    : KeyNestPalette.cardLight,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                onSelected: (group) {
                  setState(() {
                    _selectedNavGroup = group;
                  });
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem<KdbxGroup?>(
                    value: null,
                    child: Row(
                      children: [
                        Icon(
                          Icons.folder_copy_outlined,
                          size: 16,
                          color: _selectedNavGroup == null
                              ? (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary)
                              : (isDark
                                    ? KeyNestPalette.textSecondaryDark
                                    : KeyNestPalette.textSecondaryLight),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'All Folders',
                          style: TextStyle(
                            fontWeight: _selectedNavGroup == null
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: _selectedNavGroup == null
                                ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  ...folderOptions.map((opt) {
                    final isSel = _selectedNavGroup == opt.group;
                    return PopupMenuItem<KdbxGroup?>(
                      value: opt.group,
                      child: Text(
                        opt.displayName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSel
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: isSel
                              ? (isDark
                                    ? KeyNestPalette.primaryDark
                                    : KeyNestPalette.primary)
                              : null,
                        ),
                      ),
                    );
                  }),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _selectedNavGroup != null
                        ? KeyNestPalette.accent.withValues(
                            alpha: isDark ? 0.2 : 0.1,
                          )
                        : (isDark
                              ? KeyNestPalette.surfaceDark
                              : KeyNestPalette.surfaceLight),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _selectedNavGroup != null
                          ? KeyNestPalette.accent.withValues(alpha: 0.4)
                          : (isDark
                                ? KeyNestPalette.entryBorderDark
                                : KeyNestPalette.entryBorderLight),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 14,
                        color: _selectedNavGroup != null
                            ? KeyNestPalette.accent
                            : (isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 130),
                        child: Text(
                          currentFolderName,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: _selectedNavGroup != null
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: _selectedNavGroup != null
                                ? KeyNestPalette.accent
                                : (isDark
                                      ? KeyNestPalette.textSecondaryDark
                                      : KeyNestPalette.textSecondaryLight),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.arrow_drop_down,
                        size: 16,
                        color: _selectedNavGroup != null
                            ? KeyNestPalette.accent
                            : (isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight),
                      ),
                    ],
                  ),
                ),
              ),

              const Spacer(),

              // Quick Tree Browse Action
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                tooltip: 'Browse Folder Hierarchy',
                onPressed: () async {
                  final initialF = _selectedNavVault ?? openedFiles.firstOrNull;
                  final initialG =
                      _selectedNavGroup ?? initialF?.body.rootGroup;
                  final dest = await KeyNestDestinationPickerSheet.show(
                    context,
                    initialFile: initialF,
                    initialGroup: initialG,
                  );
                  if (dest != null && mounted) {
                    setState(() {
                      _selectedNavVault = dest.file;
                      _selectedNavGroup = dest.group;
                    });
                  }
                },
              ),

              // Reset / Clear filter button
              if (isFiltered)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.clear_rounded,
                    size: 18,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                  ),
                  tooltip: 'Reset to All Credentials',
                  onPressed: () {
                    setState(() {
                      _selectedNavVault = null;
                      _selectedNavGroup = null;
                    });
                  },
                ),
            ],
          ),
          if (isFiltered) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.filter_list_rounded,
                  size: 13,
                  color:
                      (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary)
                          .withValues(alpha: 0.8),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Browsing: $currentVaultName • $currentFolderName',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                InkWell(
                  onTap: () {
                    setState(() {
                      _selectedNavVault = null;
                      _selectedNavGroup = null;
                    });
                  },
                  child: Text(
                    'Show All',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isDark
                          ? KeyNestPalette.primaryDark
                          : KeyNestPalette.primary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEntryLeadingIcon(KdbxEntry entry, bool isCarryover) {
    final rawUrl = entry.getString(KdbxKeyCommon.URL)?.getText()?.trim();
    final cachedBytes =
        entry.customIcon?.data ??
        KeyNestDynamicIconService.instance.getCachedIconSync(rawUrl) ??
        KeyNestDynamicIconService.instance.getCachedIconSync(entry.label);

    if (cachedBytes != null && cachedBytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          cachedBytes,
          width: 40,
          height: 40,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _buildLetterAvatar(entry, isCarryover),
        ),
      );
    }
    return _buildLetterAvatar(entry, isCarryover);
  }

  Widget _buildLetterAvatar(KdbxEntry entry, bool isCarryover) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CircleAvatar(
      radius: 20,
      backgroundColor: isDark
          ? (isCarryover
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primaryDark)
                .withValues(alpha: 0.20)
          : (isCarryover
                ? KeyNestTokens.lightPrimaryContainer
                : KeyNestPalette.primaryContainerLight),
      child: Text(
        (entry.label?.isNotEmpty ?? false)
            ? entry.label![0].toUpperCase()
            : '?',
        style: TextStyle(
          color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.lightIcon,
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
      ),
    );
  }

  Widget _buildDestinationSection(
    bool isDark,
    ThemeData theme,
    List<KdbxFile> openedFiles,
  ) {
    final currentFile = _newSelectedFile ?? openedFiles.firstOrNull;
    final currentGroup = _newSelectedGroup ?? currentFile?.body.rootGroup;
    final currentVaultName = currentFile != null
        ? KeyNestVaultScope.cleanVaultName(widget.kdbxBloc, currentFile)
        : 'Default Vault';
    final currentFolderName = (currentGroup?.parent == null)
        ? 'Root Folder'
        : (currentGroup?.name.get() ?? 'Root Folder');

    final folderOptions = _getFolderOptions(currentFile);
    final selectedGroupValue = folderOptions.any((f) => f.group == currentGroup)
        ? currentGroup
        : folderOptions.firstOrNull?.group;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.surfaceDark.withValues(alpha: 0.5)
            : KeyNestPalette.surfaceLight.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? KeyNestPalette.entryBorderDark
              : KeyNestPalette.entryBorderLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.folder_shared_outlined,
                size: 16,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
              const SizedBox(width: 6),
              Text(
                'Save Destination',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text(
                  'Browse / New',
                  style: TextStyle(fontSize: 12),
                ),
                onPressed: () async {
                  final dest = await KeyNestDestinationPickerSheet.show(
                    context,
                    initialFile: currentFile,
                    initialGroup: currentGroup,
                  );
                  if (dest != null && mounted) {
                    setState(() {
                      _newSelectedFile = dest.file;
                      _newSelectedGroup = dest.group;
                    });
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Prominent Vault and Folder Destination Pill
          InkWell(
            onTap: () async {
              final dest = await KeyNestDestinationPickerSheet.show(
                context,
                initialFile: currentFile,
                initialGroup: currentGroup,
              );
              if (dest != null && mounted) {
                setState(() {
                  _newSelectedFile = dest.file;
                  _newSelectedGroup = dest.group;
                });
              }
            },
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color:
                      (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary)
                          .withValues(alpha: isDark ? 0.45 : 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 15,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      currentVaultName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      '•',
                      style: TextStyle(
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.folder_outlined,
                    size: 15,
                    color: KeyNestPalette.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      currentFolderName,
                      style: const TextStyle(
                        fontSize: 12,
                        color: KeyNestPalette.accent,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.touch_app_outlined,
                    size: 15,
                    color: isDark
                        ? KeyNestPalette.primaryDark
                        : KeyNestPalette.primary,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Vault Selector (if multiple vaults available)
          if (openedFiles.length > 1) ...[
            Text(
              'Vault',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<KdbxFile>(
              initialValue: currentFile,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.inventory_2_outlined, size: 18),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              items: openedFiles.map((file) {
                final name = KeyNestVaultScope.cleanVaultName(
                  widget.kdbxBloc,
                  file,
                );
                return DropdownMenuItem<KdbxFile>(
                  value: file,
                  child: Text(name, style: const TextStyle(fontSize: 13)),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _newSelectedFile = val;
                    _newSelectedGroup = val.body.rootGroup;
                  });
                }
              },
            ),
            const SizedBox(height: 10),
          ],

          // Folder Selector
          Text(
            'Folder',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<KdbxGroup>(
            initialValue: selectedGroupValue,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.folder_outlined, size: 18),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            isExpanded: true,
            items: folderOptions.map((opt) {
              return DropdownMenuItem<KdbxGroup>(
                value: opt.group,
                child: Text(
                  opt.displayName,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),
            onChanged: (group) {
              if (group != null) {
                setState(() {
                  _newSelectedGroup = group;
                });
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _saveAndAutofillNewLogin() async {
    if (_isSavingNewLogin) {
      return;
    }

    final title = _newTitleController.text.trim();
    final username = _newUsernameController.text.trim();
    final password = _newPasswordController.text;
    final url = _newUrlController.text.trim();

    if (username.isEmpty && password.isEmpty && title.isEmpty) {
      setState(() {
        _newLoginErrorMessage = 'Please enter at least a username or password.';
      });
      return;
    }

    final targetFile =
        _newSelectedFile ?? widget.kdbxBloc.openedFilesKdbx.firstOrNull;
    if (targetFile == null) {
      setState(() {
        _newLoginErrorMessage =
            'No unlocked vault available to save credential.';
      });
      return;
    }

    final targetGroup = _newSelectedGroup ?? targetFile.body.rootGroup;

    setState(() {
      _isSavingNewLogin = true;
      _newLoginErrorMessage = null;
    });

    KdbxEntry? newEntry;
    try {
      newEntry = widget.kdbxBloc.createEntry(
        file: targetFile,
        group: targetGroup,
      );

      if (title.isNotEmpty) {
        newEntry.setString(KdbxKeyCommon.TITLE, PlainValue(title));
      } else if (url.isNotEmpty) {
        newEntry.setString(KdbxKeyCommon.TITLE, PlainValue(url));
      } else {
        newEntry.setString(KdbxKeyCommon.TITLE, PlainValue('New Login'));
      }

      if (username.isNotEmpty) {
        newEntry.setString(KdbxKeyCommon.USER_NAME, PlainValue(username));
      }
      if (password.isNotEmpty) {
        newEntry.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString(password),
        );
      }
      if (url.isNotEmpty) {
        newEntry.setString(KdbxKeyCommon.URL, PlainValue(url));
      }

      newEntry.times.creationTime.set(DateTime.now().toUtc());
      newEntry.times.lastModificationTime.set(DateTime.now().toUtc());

      // 1. Persist to KDBX
      await widget.kdbxBloc.saveFile(targetFile);

      // Pre-cache website icon for autofill suggestion (only if website icon fetching is enabled)
      if (url.isNotEmpty &&
          KeyNestDynamicIconService.instance.networkFetchEnabled) {
        try {
          await KeyNestDynamicIconService.instance.getOrFetchIcon(url);
        } catch (_) {}
      }

      // 2. Sync immediately to Android native AutofillCredentialStore
      await widget.kdbxBloc.syncAndroidAutofillStore(immediate: true);

      // 3. Fill the newly created entry into the browser form
      await _fillEntry(newEntry);
    } catch (e, stack) {
      _logger.warning('Failed to save and autofill new login', e, stack);
      // Clean up in-memory entry if saving to disk failed to prevent phantom entries
      if (newEntry != null) {
        try {
          targetFile.deleteEntry(newEntry);
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _isSavingNewLogin = false;
          _newLoginErrorMessage = 'Error saving credential: $e';
        });
      }
    }
  }

  Widget _buildNewLoginView(bool isDark, ThemeData theme) {
    final openedFiles = widget.kdbxBloc.openedFilesKdbx;
    final usernameSuggestions = _getUsernameSuggestions(
      _newUsernameController.text,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () {
                  setState(() {
                    _isCreatingNewLogin = false;
                    _newLoginErrorMessage = null;
                  });
                },
                tooltip: 'Back to logins',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'New Login',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Create and autofill into browser',
                      style: TextStyle(
                        fontSize: 12,
                        decoration: TextDecoration.none,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  if (!_hasFilled) {
                    AutofillService().cancelAutofill();
                  }
                  Navigator.of(context).pop();
                },
                tooltip: 'Cancel',
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Form Body with Keyboard Insets & Auto-Scrolling
        Flexible(
          child: RepaintBoundary(
            child: SingleChildScrollView(
              controller: _newLoginScrollController,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_newLoginErrorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: KeyNestPalette.error.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: KeyNestPalette.error.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: KeyNestPalette.error,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _newLoginErrorMessage!,
                              style: const TextStyle(
                                color: KeyNestPalette.error,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Destination: Vault and Folder Selection Pill & Dropdowns
                  _buildDestinationSection(isDark, theme, openedFiles),
                  const SizedBox(height: 12),

                  // Website Field (Pre-filled from detected request)
                  Text(
                    'Website / Domain',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _newUrlController,
                    focusNode: _newUrlFocusNode,
                    scrollPadding: const EdgeInsets.only(bottom: 72, top: 20),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor:
                          (isDark
                                  ? KeyNestTokens.darkSurfaceVariant
                                  : const Color(0xFFF4F7FC))
                              .withValues(alpha: 0.75),
                      hintText: 'https://example.com',
                      prefixIcon: Icon(
                        Icons.language_rounded,
                        size: 20,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestTokens.darkOutlineVariant.withValues(
                                  alpha: 0.7,
                                )
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestTokens.darkOutlineVariant.withValues(
                                  alpha: 0.7,
                                )
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Title Field
                  Text(
                    'Title / Service Name',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _newTitleController,
                    focusNode: _newTitleFocusNode,
                    scrollPadding: const EdgeInsets.only(bottom: 72, top: 20),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor:
                          (isDark
                                  ? KeyNestTokens.darkSurfaceVariant
                                  : const Color(0xFFF4F7FC))
                              .withValues(alpha: 0.75),
                      hintText: 'e.g. Google, GitHub, Proton',
                      prefixIcon: Icon(
                        Icons.badge_outlined,
                        size: 20,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestTokens.darkOutlineVariant.withValues(
                                  alpha: 0.7,
                                )
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestTokens.darkOutlineVariant.withValues(
                                  alpha: 0.7,
                                )
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Username / Email Field
                  Text(
                    'Username or Email',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _newUsernameController,
                    focusNode: _newUsernameFocusNode,
                    scrollPadding: const EdgeInsets.only(bottom: 72, top: 20),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor:
                          (isDark
                                  ? KeyNestTokens.darkSurfaceVariant
                                  : const Color(0xFFF4F7FC))
                              .withValues(alpha: 0.75),
                      hintText: 'name@example.com',
                      prefixIcon: Icon(
                        Icons.person_outline_rounded,
                        size: 20,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestTokens.darkOutlineVariant.withValues(
                                  alpha: 0.7,
                                )
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestTokens.darkOutlineVariant.withValues(
                                  alpha: 0.7,
                                )
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                    onChanged: (_) {
                      setState(() {});
                    },
                  ),

                  // Username suggestions (dynamic fuzzy matching)
                  if (usernameSuggestions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: usernameSuggestions.map((suggestion) {
                        return ActionChip(
                          visualDensity: VisualDensity.compact,
                          shape: const StadiumBorder(),
                          side: BorderSide(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.10)
                                : Colors.black.withValues(alpha: 0.08),
                          ),
                          backgroundColor:
                              (isDark
                                      ? const Color(0xFF1F2738)
                                      : const Color(0xFFEDF2FA))
                                  .withValues(alpha: 0.8),
                          avatar: Icon(
                            Icons.alternate_email_rounded,
                            size: 14,
                            color: isDark
                                ? KeyNestPalette.primaryDark
                                : KeyNestPalette.primary,
                          ),
                          label: Text(
                            suggestion,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          onPressed: () {
                            setState(() {
                              _newUsernameController.text = suggestion;
                              _newUsernameController.selection =
                                  TextSelection.fromPosition(
                                    TextPosition(offset: suggestion.length),
                                  );
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ],
                  const SizedBox(height: 14),

                  // Password Field
                  Text(
                    'Password',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? KeyNestPalette.textSecondaryDark
                          : KeyNestPalette.textSecondaryLight,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _newPasswordController,
                    focusNode: _newPasswordFocusNode,
                    scrollPadding: const EdgeInsets.only(bottom: 72, top: 20),
                    obscureText: _obscureNewPassword,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor:
                          (isDark
                                  ? KeyNestTokens.darkSurfaceVariant
                                  : const Color(0xFFF4F7FC))
                              .withValues(alpha: 0.75),
                      hintText: 'Enter or generate password',
                      prefixIcon: Icon(
                        Icons.lock_outline_rounded,
                        size: 20,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              _obscureNewPassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 20,
                              color: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscureNewPassword = !_obscureNewPassword;
                              });
                            },
                            tooltip: _obscureNewPassword ? 'Show' : 'Hide',
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.auto_awesome_rounded,
                              size: 20,
                              color: isDark
                                  ? KeyNestPalette.primaryDark
                                  : KeyNestPalette.primary,
                            ),
                            tooltip: 'Generate Strong Password',
                            onPressed: _generateNewPassword,
                          ),
                        ],
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestTokens.darkOutlineVariant.withValues(
                                  alpha: 0.7,
                                )
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestTokens.darkOutlineVariant.withValues(
                                  alpha: 0.7,
                                )
                              : Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const Divider(height: 1),

        // Action Buttons
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              TextButton(
                onPressed: _isSavingNewLogin
                    ? null
                    : () {
                        setState(() {
                          _isCreatingNewLogin = false;
                          _newLoginErrorMessage = null;
                        });
                      },
                style: TextButton.styleFrom(
                  foregroundColor: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              FilledButton.icon(
                icon: _isSavingNewLogin
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: isDark
                              ? const Color(0xFF00315D)
                              : Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_rounded, size: 18),
                label: Text(
                  _isSavingNewLogin ? 'Saving...' : 'Save & Autofill',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: isDark
                      ? KeyNestPalette.primaryDark
                      : KeyNestPalette.primary,
                  foregroundColor: isDark
                      ? const Color(0xFF00315D)
                      : Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      KeyNestShapes.radiusPill,
                    ),
                  ),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                onPressed: _isSavingNewLogin ? null : _saveAndAutofillNewLogin,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLockedVaultsView(bool isDark, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: KeyNestPalette.warning.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.lock_rounded,
              color: KeyNestPalette.warning,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Vault is Locked',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Unlock your KeyNest vault to access credentials for autofill.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            icon: const Icon(Icons.lock_open_rounded, size: 18),
            label: const Text('Unlock KeyNest'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              foregroundColor: isDark ? const Color(0xFF00315D) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            onPressed: () {
              widget.onClose?.call();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNoMatchesView(bool isDark, ThemeData theme) {
    final openedFiles = widget.kdbxBloc.openedFilesKdbx;
    final targetTitle = _formatTargetTitle();

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color:
                  (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary)
                      .withValues(alpha: isDark ? 0.16 : 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.search_off_rounded,
              color: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _searchQuery.isEmpty
                ? 'No credentials in vault'
                : 'No results found',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _searchQuery.isEmpty
                ? 'Your unlocked vault has no credentials to display.'
                : 'No logins found matching "$_searchQuery".',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              decoration: TextDecoration.none,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
          ),
          if (openedFiles.isNotEmpty) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(
                targetTitle != 'KeyNest Autofill'
                    ? 'New Login for $targetTitle'
                    : 'New Login',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: isDark
                    ? KeyNestPalette.primaryDark
                    : KeyNestPalette.primary,
                foregroundColor: isDark
                    ? const Color(0xFF00315D)
                    : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
              ),
              onPressed: _startNewLoginFlow,
            ),
          ],
        ],
      ),
    );
  }
}
