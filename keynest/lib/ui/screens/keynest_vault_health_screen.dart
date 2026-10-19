// ignore_for_file: always_put_control_body_on_new_line
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/card_details.dart';
import 'package:keynest/ui/screens/entry_details.dart';
import 'package:keynest/ui/screens/keynest_duplicates_screen.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:provider/provider.dart';
import 'package:zxcvbn/zxcvbn.dart';

/// Item representing a weak password finding without holding plaintext secrets.
class WeakPasswordFinding {
  WeakPasswordFinding({
    required this.entry,
    required this.score,
    required this.label,
  });

  final KdbxEntry entry;
  final int score;
  final String label;
}

/// Cluster of entries sharing the same password without holding plaintext secrets.
class ReusedPasswordFinding {
  ReusedPasswordFinding({required this.entries});

  final List<KdbxEntry> entries;
  int get count => entries.length;
}

/// Item representing an expired payment card finding.
class ExpiredCardFinding {
  ExpiredCardFinding({
    required this.entry,
    required this.expiryString,
  });

  final KdbxEntry entry;
  final String expiryString;
}

/// Complete report of vault security health metrics.
class VaultHealthReport {
  VaultHealthReport({
    required this.totalEntries,
    required this.totalLogins,
    required this.totalCards,
    required this.weakPasswords,
    required this.reusedPasswordClusters,
    required this.missing2FaEntries,
    required this.expiredCardEntries,
    required this.healthScore,
  });

  final int totalEntries;
  final int totalLogins;
  final int totalCards;
  final List<WeakPasswordFinding> weakPasswords;
  final List<ReusedPasswordFinding> reusedPasswordClusters;
  final List<KdbxEntry> missing2FaEntries;
  final List<ExpiredCardFinding> expiredCardEntries;
  final int healthScore;

  int get totalIssues =>
      weakPasswords.length +
      reusedPasswordClusters.length +
      missing2FaEntries.length +
      expiredCardEntries.length;
}

/// Asynchronous scanner engine for computing vault health metrics.
/// Reuses existing strength, TOTP, duplicate, and card expiry heuristics.
/// Operates in non-blocking asynchronous chunks and never retains plaintext secrets.
class KeyNestVaultHealthScanner {
  KeyNestVaultHealthScanner._();

  static final _zxcvbn = Zxcvbn();

  static Future<VaultHealthReport> scanVaultAsync(
    KdbxFile file, {
    void Function(double progress)? onProgress,
    DateTime? currentTime,
  }) async {
    final allEntries = file.body.rootGroup
        .getAllEntries()
        .where((e) => !KeyNestItemTypeHelper.isEntryInTrash(e))
        .toList();

    if (allEntries.isEmpty) {
      onProgress?.call(1.0);
      return VaultHealthReport(
        totalEntries: 0,
        totalLogins: 0,
        totalCards: 0,
        weakPasswords: const [],
        reusedPasswordClusters: const [],
        missing2FaEntries: const [],
        expiredCardEntries: const [],
        healthScore: 100,
      );
    }

    final weakPasswords = <WeakPasswordFinding>[];
    final passwordBuckets = <String, List<KdbxEntry>>{};
    final missing2Fa = <KdbxEntry>[];
    final expiredCards = <ExpiredCardFinding>[];
    final now = currentTime ?? DateTime.now();
    var loginsCount = 0;
    var cardsCount = 0;

    for (int i = 0; i < allEntries.length; i++) {
      final entry = allEntries[i];
      final itemType = KeyNestItemTypeHelper.getItemType(entry);

      if (itemType == KeyNestItemType.login ||
          itemType == KeyNestItemType.twoFactor) {
        loginsCount++;
        final pass = entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
        if (pass.isEmpty) {
          weakPasswords.add(
            WeakPasswordFinding(
              entry: entry,
              score: 0,
              label: 'No Password',
            ),
          );
        } else {
          final res = _zxcvbn.evaluate(pass);
          final score = res.score?.toInt() ?? 0;
          if (score <= 2) {
            final label = score == 0
                ? 'Very Weak'
                : (score == 1 ? 'Weak' : 'Fair');
            weakPasswords.add(
              WeakPasswordFinding(
                entry: entry,
                score: score,
                label: label,
              ),
            );
          }
          passwordBuckets.putIfAbsent(pass, () => []).add(entry);
        }

        if (itemType == KeyNestItemType.login &&
            !EntryTotpHelper.hasTotp(entry)) {
          missing2Fa.add(entry);
        }
      } else if (itemType == KeyNestItemType.card) {
        cardsCount++;
        final expiryStr = entry.getString(KdbxKey('Expiry'))?.getText()?.trim();
        if (expiryStr != null && expiryStr.isNotEmpty) {
          if (isCardExpired(expiryStr, now: now)) {
            expiredCards.add(
              ExpiredCardFinding(
                entry: entry,
                expiryString: expiryStr,
              ),
            );
          }
        }
      }

      // Yield UI event loop periodically to prevent frame drops on large vaults
      if (i > 0 && i % 100 == 0) {
        onProgress?.call((i / allEntries.length) * 0.9);
        await Future<void>.delayed(Duration.zero);
      }
    }

    final reusedClusters = <ReusedPasswordFinding>[];
    for (final cluster in passwordBuckets.values) {
      if (cluster.length > 1) {
        reusedClusters.add(ReusedPasswordFinding(entries: cluster));
      }
    }
    // Clean up local password bucket immediately to ensure zero plaintext secrets remain
    passwordBuckets.clear();

    // Calculate overall health score: 100 baseline minus penalties
    final weakPenalty = (weakPasswords.length * 6).clamp(0, 40);
    final reusePenalty = (reusedClusters.length * 8).clamp(0, 30);
    final twoFaPenalty = (missing2Fa.length * 2).clamp(0, 20);
    final cardPenalty = (expiredCards.length * 5).clamp(0, 10);
    final score =
        (100 - weakPenalty - reusePenalty - twoFaPenalty - cardPenalty).clamp(
          0,
          100,
        );

    onProgress?.call(1.0);

    return VaultHealthReport(
      totalEntries: allEntries.length,
      totalLogins: loginsCount,
      totalCards: cardsCount,
      weakPasswords: weakPasswords,
      reusedPasswordClusters: reusedClusters,
      missing2FaEntries: missing2Fa,
      expiredCardEntries: expiredCards,
      healthScore: score,
    );
  }

  /// Parses card expiration date in MM/YY, MM/YYYY, or YYYY-MM format
  /// and checks if it is strictly before the current month/year.
  static bool isCardExpired(String raw, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final clean = raw.trim();
    if (clean.isEmpty) return false;

    // Handle YYYY-MM format
    if (clean.contains('-') && clean.length >= 7) {
      final parts = clean.split('-');
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (y != null && m != null && m >= 1 && m <= 12) {
        final fullYear = y < 100 ? 2000 + y : y;
        if (fullYear < current.year) return true;
        if (fullYear == current.year && m < current.month) return true;
        return false;
      }
    }

    // Handle MM/YY, MM.YY, MM-YY format
    final separator = clean.contains('/')
        ? '/'
        : (clean.contains('.') ? '.' : (clean.contains('-') ? '-' : null));
    if (separator != null) {
      final parts = clean.split(separator);
      if (parts.length >= 2) {
        final m = int.tryParse(parts[0].trim());
        var y = int.tryParse(parts[1].trim());
        if (m != null && y != null && m >= 1 && m <= 12) {
          if (y < 100) y = 2000 + y;
          if (y < current.year) return true;
          if (y == current.year && m < current.month) return true;
        }
      }
    }

    return false;
  }
}

/// Unified Vault Health Screen providing actionable overview of:
/// - Weak passwords
/// - Reused/duplicate credentials
/// - Missing two-factor authentication (2FA)
/// - Expired payment cards
class KeyNestVaultHealthScreen extends StatefulWidget {
  const KeyNestVaultHealthScreen({super.key});

  static Route<void> route() => MaterialPageRoute(
    settings: const RouteSettings(name: '/vaultHealth'),
    builder: (context) => const KeyNestVaultHealthScreen(),
  );

  @override
  State<KeyNestVaultHealthScreen> createState() =>
      _KeyNestVaultHealthScreenState();
}

class _KeyNestVaultHealthScreenState extends State<KeyNestVaultHealthScreen> {
  bool _isScanning = false;
  double _scanProgress = 0.0;
  VaultHealthReport? _report;
  KdbxFile? _scannedFile;
  KdbxFile? _selectedVaultFile;
  int _scanSessionId = 0;

  // Expanded categories state
  final Set<String> _expandedSections = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final kdbxBloc = context.read<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    if (openedFiles.isNotEmpty) {
      final defaultVault =
          KeyNestVaultScope.instance.getSelectedVault(kdbxBloc) ??
          openedFiles.first;
      final targetFile =
          (_selectedVaultFile != null &&
              openedFiles.contains(_selectedVaultFile))
          ? _selectedVaultFile!
          : defaultVault;

      if (_scannedFile != targetFile && !_isScanning) {
        _startScan(targetFile);
      }
    }
  }

  Future<void> _startScan(KdbxFile file) async {
    final currentSession = ++_scanSessionId;
    setState(() {
      _isScanning = true;
      _scanProgress = 0.0;
      _scannedFile = file;
    });

    try {
      final report = await KeyNestVaultHealthScanner.scanVaultAsync(
        file,
        onProgress: (p) {
          if (mounted && _scanSessionId == currentSession) {
            setState(() => _scanProgress = p);
          }
        },
      );
      if (mounted && _scanSessionId == currentSession) {
        setState(() {
          _report = report;
          _isScanning = false;
          _scanProgress = 1.0;
        });
      }
    } catch (e) {
      if (mounted && _scanSessionId == currentSession) {
        setState(() => _isScanning = false);
      }
    }
  }

  void _toggleSection(String key) {
    setState(() {
      if (_expandedSections.contains(key)) {
        _expandedSections.remove(key);
      } else {
        _expandedSections.add(key);
      }
    });
  }

  Color _scoreColor(int score, {bool isDark = false}) {
    if (score >= 80) {
      return isDark ? KeyNestPalette.successDark : KeyNestPalette.success;
    }
    if (score >= 60) return KeyNestPalette.info;
    if (score >= 40) return KeyNestPalette.warning;
    return KeyNestPalette.error;
  }

  String _scoreRating(int score) {
    if (score >= 80) return 'Strong Health';
    if (score >= 60) return 'Moderate Health';
    if (score >= 40) return 'Needs Attention';
    return 'Action Recommended';
  }

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = context.watch<KdbxBloc>();
    final openedFiles = kdbxBloc.openedFilesKdbx;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? KeyNestPalette.bgDark : KeyNestPalette.bgLight,
      appBar: AppBar(
        title: const Text('Vault Health Overview'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Rescan Vault',
            onPressed: (_scannedFile != null && !_isScanning)
                ? () => _startScan(_scannedFile!)
                : null,
          ),
        ],
      ),
      body: _buildBody(openedFiles, isDark),
    );
  }

  Widget _buildBody(List<KdbxFile> openedFiles, bool isDark) {
    if (openedFiles.isEmpty) {
      return const Center(
        child: Text('No vault open.'),
      );
    }

    if (_isScanning && _report == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Analyzing vault security (${(_scanProgress * 100).toInt()}%)...',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ],
        ),
      );
    }

    final report = _report;
    if (report == null) {
      return const Center(child: Text('No data available'));
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      children: [
        // Vault Selector (if multiple vaults open)
        if (openedFiles.length > 1) ...[
          _buildVaultSelector(openedFiles, isDark),
          const SizedBox(height: 16),
        ],

        // Health Score Summary Hero Card
        _buildHeroScoreCard(report, isDark),
        const SizedBox(height: 20),

        if (_isScanning)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(
              value: _scanProgress,
              backgroundColor: isDark
                  ? KeyNestPalette.entryBorderDark
                  : KeyNestPalette.entryBorderLight,
            ),
          ),

        // Section 1: Weak Passwords
        _buildCategoryCard(
          categoryKey: 'weak',
          title: 'Weak Passwords',
          subtitle: report.weakPasswords.isEmpty
              ? 'All passwords meet strength criteria'
              : '${report.weakPasswords.length} passwords need stronger complexity',
          count: report.weakPasswords.length,
          icon: Icons.shield_outlined,
          badgeColor: report.weakPasswords.isEmpty
              ? KeyNestPalette.success
              : KeyNestPalette.error,
          isExpanded: _expandedSections.contains('weak'),
          onToggle: () => _toggleSection('weak'),
          children: report.weakPasswords.map((item) {
            final title =
                item.entry.getString(KdbxKeyCommon.TITLE)?.getText() ??
                'Untitled';
            final user =
                item.entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
            return _buildEntryRow(
              title: title,
              subtitle: user.isNotEmpty ? user : 'No username',
              trailingBadge: item.label,
              badgeColor: item.score == 0
                  ? KeyNestPalette.error
                  : KeyNestPalette.warning,
              onTap: () async {
                await Navigator.of(
                  context,
                ).push(EntryDetailsScreen.route(entry: item.entry));
                if (mounted && _scannedFile != null) {
                  await _startScan(_scannedFile!);
                }
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 14),

        // Section 2: Reused Passwords
        _buildCategoryCard(
          categoryKey: 'reused',
          title: 'Reused Passwords',
          subtitle: report.reusedPasswordClusters.isEmpty
              ? 'No shared passwords detected'
              : '${report.reusedPasswordClusters.length} password sets shared across multiple accounts',
          count: report.reusedPasswordClusters.length,
          icon: Icons.repeat_rounded,
          badgeColor: report.reusedPasswordClusters.isEmpty
              ? KeyNestPalette.success
              : const Color(0xFF8B5CF6),
          isExpanded: _expandedSections.contains('reused'),
          onToggle: () => _toggleSection('reused'),
          extraAction: report.reusedPasswordClusters.isNotEmpty
              ? TextButton.icon(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(KeyNestDuplicatesScreen.route()),
                  icon: const Icon(Icons.copy_all_rounded, size: 18),
                  label: const Text('Open Duplicate Cleaner'),
                )
              : null,
          children: report.reusedPasswordClusters.expand((cluster) {
            return cluster.entries.map((entry) {
              final title =
                  entry.getString(KdbxKeyCommon.TITLE)?.getText() ?? 'Untitled';
              final user =
                  entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
              return _buildEntryRow(
                title: title,
                subtitle: user.isNotEmpty ? user : 'No username',
                trailingBadge: 'Reused (${cluster.count})',
                badgeColor: const Color(0xFF8B5CF6),
                onTap: () async {
                  await Navigator.of(
                    context,
                  ).push(EntryDetailsScreen.route(entry: entry));
                  if (mounted && _scannedFile != null) {
                    await _startScan(_scannedFile!);
                  }
                },
              );
            });
          }).toList(),
        ),
        const SizedBox(height: 14),

        // Section 3: Missing 2FA
        _buildCategoryCard(
          categoryKey: 'twoFa',
          title: 'Missing Two-Factor (2FA)',
          subtitle: report.missing2FaEntries.isEmpty
              ? 'All logins have active TOTP / 2FA protection'
              : '${report.missing2FaEntries.length} accounts without one-time codes',
          count: report.missing2FaEntries.length,
          icon: Icons.phonelink_lock_rounded,
          badgeColor: report.missing2FaEntries.isEmpty
              ? KeyNestPalette.success
              : KeyNestPalette.warning,
          isExpanded: _expandedSections.contains('twoFa'),
          onToggle: () => _toggleSection('twoFa'),
          children: report.missing2FaEntries.map((entry) {
            final title =
                entry.getString(KdbxKeyCommon.TITLE)?.getText() ?? 'Untitled';
            final user =
                entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
            return _buildEntryRow(
              title: title,
              subtitle: user.isNotEmpty ? user : 'No username',
              trailingBadge: 'No 2FA',
              badgeColor: KeyNestPalette.warning,
              onTap: () async {
                await Navigator.of(
                  context,
                ).push(EntryDetailsScreen.route(entry: entry));
                if (mounted && _scannedFile != null) {
                  await _startScan(_scannedFile!);
                }
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 14),

        // Section 4: Expired Cards
        _buildCategoryCard(
          categoryKey: 'cards',
          title: 'Expired Payment Cards',
          subtitle: report.expiredCardEntries.isEmpty
              ? 'No expired credit or debit cards'
              : '${report.expiredCardEntries.length} cards passed their expiration date',
          count: report.expiredCardEntries.length,
          icon: Icons.credit_card_off_rounded,
          badgeColor: report.expiredCardEntries.isEmpty
              ? KeyNestPalette.success
              : KeyNestPalette.error,
          isExpanded: _expandedSections.contains('cards'),
          onToggle: () => _toggleSection('cards'),
          children: report.expiredCardEntries.map((item) {
            final title =
                item.entry.getString(KdbxKeyCommon.TITLE)?.getText() ??
                'Payment Card';
            final holder =
                item.entry.getString(KdbxKey('Cardholder'))?.getText() ?? '';
            return _buildEntryRow(
              title: title,
              subtitle: holder.isNotEmpty
                  ? '$holder • Exp: ${item.expiryString}'
                  : 'Exp: ${item.expiryString}',
              trailingBadge: 'Expired',
              badgeColor: KeyNestPalette.error,
              onTap: () async {
                await Navigator.of(
                  context,
                ).push(CardDetailsScreen.route(entry: item.entry));
                if (mounted && _scannedFile != null) {
                  await _startScan(_scannedFile!);
                }
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 28),
      ],
    );
  }

  Widget _buildVaultSelector(List<KdbxFile> openedFiles, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? KeyNestPalette.surfaceDark
            : KeyNestPalette.surfaceLight,
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusChip),
        border: Border.all(
          color: isDark
              ? KeyNestPalette.entryBorderDark
              : KeyNestPalette.entryBorderLight,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<KdbxFile>(
          isExpanded: true,
          value: _selectedVaultFile ?? _scannedFile,
          items: openedFiles.map((file) {
            final name =
                file.body.meta.customData['keynest_display_name'] ??
                file.body.meta.databaseName.get() ??
                'Vault';
            return DropdownMenuItem<KdbxFile>(
              value: file,
              child: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            );
          }).toList(),
          onChanged: (newFile) {
            if (newFile != null && newFile != _selectedVaultFile) {
              setState(() {
                _selectedVaultFile = newFile;
              });
              _startScan(newFile);
            }
          },
        ),
      ),
    );
  }

  Widget _buildHeroScoreCard(VaultHealthReport report, bool isDark) {
    final scoreColor = _scoreColor(report.healthScore, isDark: isDark);
    final rating = _scoreRating(report.healthScore);

    return KeyNestSurfaceCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          Row(
            children: [
              // Circular Score Indicator
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 76,
                    height: 76,
                    child: CircularProgressIndicator(
                      value: report.healthScore / 100.0,
                      strokeWidth: 8,
                      backgroundColor: scoreColor.withValues(alpha: 0.16),
                      valueColor: AlwaysStoppedAnimation(scoreColor),
                    ),
                  ),
                  Text(
                    '${report.healthScore}%',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: scoreColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 20),
              // Rating and summary text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rating,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: scoreColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      report.totalIssues == 0
                          ? 'Zero security issues found across ${report.totalEntries} vault items.'
                          : '${report.totalIssues} item${report.totalIssues == 1 ? '' : 's'} need attention across ${report.totalEntries} vault items.',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? KeyNestTokens.textSecondaryDark
                            : KeyNestTokens.textSecondaryLight,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Divider(
            height: 1,
            color: isDark
                ? KeyNestTokens.borderDark
                : KeyNestTokens.borderLight,
          ),
          const SizedBox(height: 14),
          // Quick Stat Chips
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildMiniStat(
                'Weak',
                report.weakPasswords.length,
                KeyNestTokens.error,
              ),
              _buildMiniStat(
                'Reused',
                report.reusedPasswordClusters.length,
                const Color(0xFF8B5CF6),
              ),
              _buildMiniStat(
                'No 2FA',
                report.missing2FaEntries.length,
                KeyNestTokens.warning,
              ),
              _buildMiniStat(
                'Expired',
                report.expiredCardEntries.length,
                KeyNestTokens.info,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniStat(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: count > 0 ? color : Colors.grey,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildCategoryCard({
    required String categoryKey,
    required String title,
    required String subtitle,
    required int count,
    required IconData icon,
    required Color badgeColor,
    required bool isExpanded,
    required VoidCallback onToggle,
    required List<Widget> children,
    Widget? extraAction,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = isDark
        ? KeyNestTokens.primaryAccent
        : KeyNestTokens.lightPrimary;

    return KeyNestSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: SizedBox(
                width: 28,
                height: 28,
                child: Center(
                  child: Icon(
                    icon,
                    size: 24,
                    color: accentColor,
                  ),
                ),
              ),
              title: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              subtitle: Text(
                subtitle,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: count == 0
                          ? (isDark
                                    ? KeyNestTokens.darkSuccess
                                    : KeyNestTokens.lightSuccess)
                                .withValues(alpha: isDark ? 0.20 : 0.15)
                          : badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(
                        KeyNestTokens.radiusPill,
                      ),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: count == 0
                            ? (isDark
                                  ? KeyNestTokens.darkSuccess
                                  : KeyNestTokens.lightSuccess)
                            : badgeColor,
                      ),
                    ),
                  ),
                  if (count > 0)
                    IconButton(
                      icon: Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                      ),
                      onPressed: onToggle,
                    ),
                ],
              ),
              onTap: count > 0 ? onToggle : null,
            ),
          ),
          if (extraAction != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(alignment: Alignment.centerLeft, child: extraAction),
            ),
          if (isExpanded && count > 0) ...[
            const Divider(height: 1),
            ...children,
          ],
        ],
      ),
    );
  }

  Widget _buildEntryRow({
    required String title,
    required String subtitle,
    required String trailingBadge,
    required Color badgeColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: ListTile(
        dense: true,
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                trailingBadge,
                style: TextStyle(
                  color: badgeColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: Colors.grey,
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
