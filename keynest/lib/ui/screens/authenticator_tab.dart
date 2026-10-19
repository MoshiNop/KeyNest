import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/common_fields.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/add_two_factor_screen.dart';
import 'package:keynest/ui/screens/barcodescan_screen.dart';
import 'package:keynest/ui/screens/card_details.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/screens/note_details.dart';
import 'package:keynest/ui/widgets/keynest_card.dart';
import 'package:keynest/ui/widgets/keynest_empty_state.dart';
import 'package:keynest/ui/widgets/keynest_entry_count_header.dart';
import 'package:keynest/ui/widgets/keynest_search_highlight.dart';
import 'package:keynest/ui/widgets/keynest_tab_navigation_handler.dart';
import 'package:keynest/ui/widgets/keynest_top_chips_bar.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/totp_parser.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:provider/provider.dart';

class AuthenticatorTab extends StatefulWidget {
  const AuthenticatorTab({
    super.key,
    this.isActive,
    this.onCountChanged,
    this.onRegisterNavigationHandler,
  });

  final bool? isActive;
  final void Function(int count)? onCountChanged;
  final ValueChanged<KeyNestTabNavigationHandler>? onRegisterNavigationHandler;

  static Future<void> showAddOptions(
    BuildContext context, {
    KdbxFile? initialFile,
    KdbxGroup? initialGroup,
  }) async {
    final option = await KeyNestBottomSheet.show<String>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final isDark = theme.brightness == Brightness.dark;
        return KeyNestBottomSheet(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 14),
                child: Text(
                  'Add Two-Factor Account',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                  ),
                ),
              ),
              KeyNestCompactCard(
                onClick: () => Navigator.pop(ctx, 'scan'),
                child: Row(
                  children: [
                    KeyNestCompactIconTile(
                      child: Icon(
                        Icons.qr_code_scanner_rounded,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Scan QR Code',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Scan standard TOTP QR code',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: isDark
                          ? KeyNestPalette.textTertiaryDark
                          : KeyNestPalette.textTertiaryLight,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              KeyNestCompactCard(
                onClick: () => Navigator.pop(ctx, 'manual'),
                child: Row(
                  children: [
                    KeyNestCompactIconTile(
                      child: Icon(
                        Icons.keyboard_rounded,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Enter Key Manually',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Input secret key and account details',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? KeyNestPalette.textSecondaryDark
                                  : KeyNestPalette.textSecondaryLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: isDark
                          ? KeyNestPalette.textTertiaryDark
                          : KeyNestPalette.textTertiaryLight,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );

    if (option == null || !context.mounted) {
      return;
    }

    if (option == 'scan') {
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
      if (!context.mounted) {
        return;
      }

      TotpQrData? parsedData;
      if (barcodeResult case ScanResultValid(barcode: final barcode)) {
        final rawText = barcode.text.trim();
        if (rawText.isNotEmpty) {
          parsedData = TotpQrData.parse(rawText);
          if (parsedData == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Scanned code could not be fully parsed. You can edit the fields manually.',
                ),
                backgroundColor: Colors.orangeAccent,
              ),
            );
          }
        }
      }

      if (context.mounted) {
        Navigator.of(context).push(
          AddTwoFactorScreen.route(
            initialFile: initialFile,
            initialGroup: initialGroup,
            initialData: parsedData,
          ),
        );
      }
    } else if (option == 'manual') {
      Navigator.of(context).push(
        AddTwoFactorScreen.route(
          initialFile: initialFile,
          initialGroup: initialGroup,
        ),
      );
    }
  }

  @override
  State<AuthenticatorTab> createState() => _AuthenticatorTabState();
}

class _AuthenticatorTabState extends State<AuthenticatorTab>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _chipsScrollController = ScrollController();
  late final ValueNotifier<int> _clockNotifier;

  bool _isSearchExpanded = false;
  String _searchQuery = '';
  DateTime? _searchOpenedAt;
  bool _keyboardWasVisible = false;
  Timer? _timer;
  int? _lastReportedCount;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _clockNotifier = ValueNotifier<int>(clock.now().millisecondsSinceEpoch);
    WidgetsBinding.instance.addObserver(this);
    KeyNestVaultScope.instance.addListener(_onVaultScopeChanged);
    _checkTimerState();
    widget.onRegisterNavigationHandler?.call(
      KeyNestTabNavigationHandler(
        isSelectionActive: () => false,
        exitSelection: () {},
        isSearchActive: () => _isSearchExpanded || _searchQuery.isNotEmpty,
        clearSearch: () {
          _searchController.clear();
          _searchFocusNode.unfocus();
          if (mounted) {
            setState(() {
              _isSearchExpanded = false;
              _searchQuery = '';
            });
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    KeyNestVaultScope.instance.removeListener(_onVaultScopeChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _chipsScrollController.dispose();
    _stopTimer();
    _clockNotifier.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _lifecycleState = state;
    _checkTimerState();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottomInset =
        WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .firstOrNull
            ?.viewInsets
            .bottom ??
        0;

    if (bottomInset > 0) {
      _keyboardWasVisible = true;
    } else if (bottomInset == 0 && _isSearchExpanded && mounted) {
      final justOpened =
          _searchOpenedAt != null &&
          clock.now().difference(_searchOpenedAt!).inMilliseconds < 600;

      // Close only if the keyboard was previously visible and is now dismissed
      if (_keyboardWasVisible && !justOpened) {
        _keyboardWasVisible = false;
        if (_searchController.text.trim().isEmpty) {
          setState(() {
            _isSearchExpanded = false;
          });
          _searchFocusNode.unfocus();
        }
      }
    }
  }

  @override
  void didUpdateWidget(AuthenticatorTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _checkTimerState();
    }
  }

  void _onVaultScopeChanged() {
    _checkTimerState();
    if (mounted) {
      setState(() {});
    }
  }

  void _checkTimerState() {
    final isTabActive =
        (widget.isActive ??
        (KeyNestVaultScope.instance.activeTabIndex ==
            KeyNestTab.twoFactor.index));
    final isAppResumed = _lifecycleState == AppLifecycleState.resumed;

    if (isTabActive && isAppResumed) {
      _startTimer();
    } else {
      _stopTimer();
    }
  }

  void _startTimer() {
    _clockNotifier.value = clock.now().millisecondsSinceEpoch;
    if (_timer != null && _timer!.isActive) {
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        _clockNotifier.value = clock.now().millisecondsSinceEpoch;
      }
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _onAddTotp() => AuthenticatorTab.showAddOptions(context);

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = context.watch<KdbxBloc>();
    final commonFields = context.watch<CommonFields>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final scope = KeyNestVaultScope.instance;

    // Find all entries in open vault/folder that have TOTP configured
    final candidateEntries = scope.getScopedEntries(
      kdbxBloc,
      tab: KeyNestTab.twoFactor,
    );
    var allEntries = candidateEntries.where((e) {
      if (KeyNestItemTypeHelper.isEntryInTrash(e)) {
        return false;
      }
      return EntryTotpHelper.hasTotp(e);
    }).toList();

    // Favorites filtering
    if (scope.favoritesOnly) {
      allEntries = allEntries
          .where(
            (e) =>
                e.getString(KdbxKey('is_favorite'))?.getText() == 'true' ||
                e.getString(KdbxKey('IsFavorite'))?.getText() == 'true',
          )
          .toList();
    }

    final displayedEntries = allEntries.where((entry) {
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final title = entry.label?.toLowerCase() ?? '';
        final username =
            entry
                .getString(commonFields.userName.key)
                ?.getText()
                ?.toLowerCase() ??
            '';
        if (!title.contains(query) && !username.contains(query)) {
          return false;
        }
      }
      return true;
    }).toList();

    // Sort entries according to active VaultSortMode
    KeyNestTopChipsBar.sortEntries(
      displayedEntries,
      scope.getSortMode(KeyNestTab.twoFactor),
    );

    if (widget.onCountChanged != null &&
        _lastReportedCount != displayedEntries.length) {
      _lastReportedCount = displayedEntries.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onCountChanged!(displayedEntries.length);
        }
      });
    }

    final childContent = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            notification is UserScrollNotification) {
          if (_searchFocusNode.hasFocus) {
            _searchFocusNode.unfocus();
          }
        }
        return false;
      },
      child: Column(
        children: [
          // Consistent Top Chip Bar Across Tabs (No Category chip)
          KeyNestTopChipsBar(
            tab: KeyNestTab.twoFactor,
            searchController: _searchController,
            searchFocusNode: _searchFocusNode,
            isSearchExpanded: _isSearchExpanded,
            scrollController: _chipsScrollController,
            searchHintText: 'Search 2FA accounts...',
            showCategoryChip: false,
            onSearchExpandedChanged: (expanded) {
              if (expanded) {
                _searchOpenedAt = clock.now();
                _keyboardWasVisible = false;
              }
              setState(() {
                _isSearchExpanded = expanded;
                if (!expanded) {
                  _searchQuery = '';
                  _searchController.clear();
                  _searchFocusNode.unfocus();
                }
              });
            },
            onSearchChanged: (val) {
              setState(() {
                _searchQuery = val.trim();
              });
            },
          ),

          Expanded(
            child: allEntries.isEmpty && _searchQuery.isEmpty
                ? KeyNestEmptyState(
                    type: EmptyStateType.twoFactor,
                    actionLabel: 'Add Account',
                    onAction: _onAddTotp,
                  )
                : displayedEntries.isEmpty
                ? Center(
                    child: Text(
                      _searchQuery.isNotEmpty
                          ? 'No 2FA accounts found for "$_searchQuery"'
                          : (scope.favoritesOnly
                                ? 'No favorite 2FA accounts found'
                                : 'No 2FA accounts found'),
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                      ),
                    ),
                  )
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: KeyNestTokens.contentMaxWidth,
                      ),
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
                        itemCount: displayedEntries.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return KeyNestEntryCountHeader(
                              count: displayedEntries.length,
                              singularLabel: 'account',
                              pluralLabel: 'accounts',
                              padding: const EdgeInsets.fromLTRB(0, 4, 0, 10),
                            );
                          }
                          final entry = displayedEntries[index - 1];
                          return KeyNestTotpCardItem(
                            key: ValueKey(entry.uuid.uuid),
                            entry: entry,
                            clockNotifier: _clockNotifier,
                            searchQuery: _searchQuery,
                            commonFields: commonFields,
                            isDark: isDark,
                            theme: theme,
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );

    if (widget.onRegisterNavigationHandler != null) {
      return childContent;
    }

    return PopScope(
      canPop: !_isSearchExpanded && _searchQuery.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        if (_isSearchExpanded || _searchQuery.isNotEmpty) {
          _searchController.clear();
          _searchFocusNode.unfocus();
          setState(() {
            _isSearchExpanded = false;
            _searchQuery = '';
          });
        }
      },
      child: childContent,
    );
  }
}

class KeyNestTotpCardItem extends StatefulWidget {
  const KeyNestTotpCardItem({
    super.key,
    required this.entry,
    required this.clockNotifier,
    required this.searchQuery,
    required this.commonFields,
    required this.isDark,
    required this.theme,
  });

  final KdbxEntry entry;
  final ValueNotifier<int> clockNotifier;
  final String searchQuery;
  final CommonFields commonFields;
  final bool isDark;
  final ThemeData theme;

  @override
  State<KeyNestTotpCardItem> createState() => _KeyNestTotpCardItemState();
}

class _KeyNestTotpCardItemState extends State<KeyNestTotpCardItem> {
  int? _currentStep;
  String _cachedCode = '--- ---';
  int _cachedPeriod = 30;

  @override
  void initState() {
    super.initState();
    _recomputeCode(widget.clockNotifier.value);
  }

  @override
  void didUpdateWidget(KeyNestTotpCardItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry != widget.entry ||
        oldWidget.clockNotifier != widget.clockNotifier) {
      _currentStep = null;
      _recomputeCode(widget.clockNotifier.value);
    }
  }

  void _recomputeCode(int nowMs) {
    final nowSec = nowMs ~/ 1000;
    try {
      final totpInfo = EntryTotpHelper.getTotpInfo(
        widget.entry,
        timestampMs: nowMs,
      );
      final period = (totpInfo?.period != null && totpInfo!.period > 0)
          ? totpInfo.period
          : (EntryTotpHelper.getOtpAuth(widget.entry)?.period ?? 30);
      _cachedPeriod = period > 0 ? period : 30;
      _currentStep = nowSec ~/ _cachedPeriod;

      final rawCode =
          totpInfo?.code ??
          EntryTotpHelper.getLiveTotpCode(
            widget.entry,
            timestampMs: nowMs,
          );
      if (rawCode != null) {
        if (rawCode.length == 6) {
          _cachedCode = '${rawCode.substring(0, 3)} ${rawCode.substring(3)}';
        } else {
          _cachedCode = rawCode;
        }
      } else {
        _cachedCode = '--- ---';
      }
    } catch (_) {
      _cachedCode = '--- ---';
    }
  }

  void _openEntryEditor(BuildContext context) {
    final itemType = KeyNestItemTypeHelper.getItemType(widget.entry);
    if (itemType == KeyNestItemType.card) {
      Navigator.of(context).push(CardDetailsScreen.route(entry: widget.entry));
    } else if (itemType == KeyNestItemType.note) {
      Navigator.of(context).push(NoteDetailsScreen.route(entry: widget.entry));
    } else {
      Navigator.of(context).push(
        EntryDetailsScreen.route(
          entry: widget.entry,
          isEditing: true,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.entry.label ?? '2FA Account';
    final username =
        widget.entry.getString(widget.commonFields.userName.key)?.getText() ??
        '';

    return ValueListenableBuilder<int>(
      valueListenable: widget.clockNotifier,
      builder: (context, nowMs, child) {
        final nowSec = nowMs ~/ 1000;
        final step = nowSec ~/ _cachedPeriod;
        if (_currentStep != step) {
          _recomputeCode(nowMs);
        }

        final remaining = _cachedPeriod - (nowSec % _cachedPeriod);
        final percent = (remaining / _cachedPeriod).clamp(0.0, 1.0);

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: KeyNestCard(
            onTap: () {
              final cleanCode = _cachedCode.replaceAll(' ', '');
              if (cleanCode.isNotEmpty &&
                  cleanCode != '------' &&
                  cleanCode != '--- ---') {
                HapticFeedback.lightImpact();
                SecurityService.copySensitive(
                  context,
                  cleanCode,
                  label: 'OTP code',
                );
              }
            },
            child: Row(
              children: [
                // Circular Countdown indicator
                CircularPercentIndicator(
                  radius: 24.0,
                  lineWidth: 3.5,
                  percent: percent,
                  center: Text(
                    '$remaining',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: remaining <= 5
                          ? KeyNestPalette.error
                          : (widget.isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight),
                    ),
                  ),
                  progressColor: remaining <= 5
                      ? KeyNestPalette.error
                      : (widget.isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary),
                  backgroundColor: widget.isDark
                      ? KeyNestPalette.entryBorderDark
                      : KeyNestPalette.entryBorderLight,
                  circularStrokeCap: CircularStrokeCap.round,
                ),
                const SizedBox(width: 16),
                // Title & Subtitle & Code
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KeyNestSearchHighlight.text(
                        text: title,
                        query: widget.searchQuery,
                        isDark: widget.isDark,
                        style: widget.theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: widget.isDark
                              ? KeyNestPalette.textPrimaryDark
                              : KeyNestPalette.textPrimaryLight,
                        ),
                      ),
                      if (username.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        KeyNestSearchHighlight.text(
                          text: username,
                          query: widget.searchQuery,
                          isDark: widget.isDark,
                          style: widget.theme.textTheme.bodySmall?.copyWith(
                            color: widget.isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        _cachedCode,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2.0,
                          fontFamily: 'JetBrainsMono',
                          color: widget.isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                // Edit button
                KeyNestPressScale(
                  onTap: () => _openEntryEditor(context),
                  child: IconButton(
                    tooltip: 'Edit entry',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    color: widget.isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                    onPressed: () => _openEntryEditor(context),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
