import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/keynest_github_service.dart';
import 'package:keynest/services/keynest_support_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Redesigned, dynamic, GitHub-powered About screen for KeyNest.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  static MaterialPageRoute<void> route() => MaterialPageRoute(
        settings: const RouteSettings(name: '/about'),
        builder: (context) => const AboutScreen(),
      );

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  late Future<KeyNestAboutData> _aboutDataFuture;
  PackageInfo? _packageInfo;
  bool _isRefreshing = false;

  static const Color _accentColor = Color(0xFFA8C7FA);

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
    _aboutDataFuture = KeyNestGitHubService.fetchAboutData();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _packageInfo = info;
        });
      }
    } catch (_) {}
  }

  Future<void> _handleRefresh() async {
    setState(() {
      _isRefreshing = true;
      _aboutDataFuture = KeyNestGitHubService.fetchAboutData(forceRefresh: true);
    });
    try {
      await _aboutDataFuture;
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _safeLaunchUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        await launchUrl(uri);
      }
    } catch (_) {
      if (mounted) {
        await Clipboard.setData(ClipboardData(text: url));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not open browser. Link copied: $url'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isDark ? KeyNestTokens.darkBackground : KeyNestTokens.lightBackground;
    final cardBg = (isDark ? const Color(0xFF161B26) : Colors.white).withValues(
      alpha: isDark ? 0.90 : 0.96,
    );
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: const Text(
          'About KeyNest',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: _isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(_accentColor),
                    ),
                  )
                : const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Repository Info',
            onPressed: _isRefreshing ? null : _handleRefresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: _accentColor,
        onRefresh: _handleRefresh,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // App Identity Card
                  _buildAppIdentityCard(isDark, cardBg, borderColor),
                  const SizedBox(height: 16),

                  // Dynamic GitHub Content
                  FutureBuilder<KeyNestAboutData>(
                    future: _aboutDataFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting &&
                          !snapshot.hasData) {
                        return _buildLoadingState(isDark);
                      }

                      final data = snapshot.data ?? KeyNestAboutData.fallback;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (data.isRateLimited) ...[
                            _buildNoticeBanner(
                              icon: Icons.speed_rounded,
                              title: 'GitHub API Rate Limit',
                              message:
                                  'Showing cached repository details. Rate limit resets shortly.',
                              isDark: isDark,
                            ),
                            const SizedBox(height: 14),
                          ] else if (data.errorMessage != null) ...[
                            _buildNoticeBanner(
                              icon: Icons.wifi_off_rounded,
                              title: 'Offline / Cached View',
                              message: data.errorMessage!,
                              isDark: isDark,
                            ),
                            const SizedBox(height: 14),
                          ],

                          // Project Information
                          _buildProjectInfoCard(data.repo, isDark, cardBg, borderColor),
                          const SizedBox(height: 16),

                          // Latest Release
                          if (data.latestRelease != null) ...[
                            _buildReleaseCard(data.latestRelease!, isDark, cardBg, borderColor),
                            const SizedBox(height: 16),
                          ],

                          // Contributors
                          _buildContributorsCard(data.contributors, isDark, cardBg, borderColor),
                          const SizedBox(height: 16),

                          // Acknowledgements & AuthPass Credits
                          _buildAcknowledgementsCard(isDark, cardBg, borderColor),
                          const SizedBox(height: 16),

                          // Open-Source Licenses & Legal
                          _buildLicensesCard(data.repo, isDark, cardBg, borderColor),
                          const SizedBox(height: 16),

                          // Contact & Support
                          _buildSupportCard(isDark, cardBg, borderColor),
                          const SizedBox(height: 28),

                          // Footer
                          Center(
                            child: Text(
                              'KeyNest • Secure KeePass Password Manager\nZero-Knowledge Architecture',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: isDark
                                    ? KeyNestPalette.textTertiaryDark
                                    : KeyNestPalette.textTertiaryLight,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppIdentityCard(bool isDark, Color cardBg, Color borderColor) {
    final versionStr = _packageInfo != null
        ? 'v${_packageInfo!.version} (Build ${_packageInfo!.buildNumber})'
        : 'v1.0.0 (Build 1)';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusSection),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (isDark ? const Color(0xFF1E2638) : const Color(0xFFEBF2FD)),
              shape: BoxShape.circle,
              border: Border.all(
                color: _accentColor.withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
            child: Image.asset(
              'assets/images/logo_icon.png',
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(
                Icons.shield_rounded,
                size: 38,
                color: _accentColor,
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'KeyNest',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: _accentColor.withValues(alpha: isDark ? 0.16 : 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              versionStr,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isDark ? _accentColor : const Color(0xFF185ABC),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Free, open-source, cross-platform password manager powered by the KeePass KDBX format.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.4,
              color: isDark
                  ? KeyNestPalette.textSecondaryDark
                  : KeyNestPalette.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeBanner({
    required IconData icon,
    required String title,
    required String message,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: (isDark ? const Color(0xFF262015) : const Color(0xFFFFF9E6)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (isDark ? Colors.amber.shade700 : Colors.amber.shade400).withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.amber.shade600),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.amber.shade200 : Colors.amber.shade900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.amber.shade100 : Colors.amber.shade800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProjectInfoCard(
    GitHubRepoInfo repo,
    bool isDark,
    Color cardBg,
    Color borderColor,
  ) {
    return _buildSectionCard(
      title: 'Project Information',
      icon: Icons.folder_open_rounded,
      isDark: isDark,
      cardBg: cardBg,
      borderColor: borderColor,
      children: [
        _buildListRow(
          icon: FontAwesomeIcons.github,
          title: 'GitHub Repository',
          subtitle: repo.fullName,
          onTap: () => _safeLaunchUrl(repo.htmlUrl),
        ),
        _buildDivider(isDark),
        _buildListRow(
          icon: Icons.menu_book_rounded,
          title: 'User Guide & Documentation',
          subtitle: 'Read the official handbook',
          onTap: () => _safeLaunchUrl(KeyNestSupportService.officialUserGuideUrl),
        ),
        _buildDivider(isDark),
        _buildListRow(
          icon: Icons.bug_report_outlined,
          title: 'Issue Tracker',
          subtitle: 'Report bugs and feature requests',
          onTap: () => _safeLaunchUrl('${repo.htmlUrl}/issues'),
        ),
        _buildDivider(isDark),
        _buildListRow(
          icon: Icons.volunteer_activism_outlined,
          title: 'Contribution Guidelines',
          subtitle: 'Learn how to contribute to KeyNest',
          onTap: () => _safeLaunchUrl('${repo.htmlUrl}/blob/main/CONTRIBUTING.md'),
        ),
      ],
    );
  }

  Widget _buildReleaseCard(
    GitHubRelease release,
    bool isDark,
    Color cardBg,
    Color borderColor,
  ) {
    return _buildSectionCard(
      title: 'Latest Release',
      icon: Icons.new_releases_outlined,
      isDark: isDark,
      cardBg: cardBg,
      borderColor: borderColor,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      release.name.isNotEmpty ? release.name : release.tagName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _accentColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      release.tagName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? _accentColor : const Color(0xFF185ABC),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                release.body.trim().isNotEmpty
                    ? release.body.split('\n').first.replaceAll(RegExp(r'^[#*\s]+'), '')
                    : 'Initial production release for Android and Desktop.',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Release Notes'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: isDark ? _accentColor : const Color(0xFF185ABC),
                      side: BorderSide(
                        color: isDark ? Colors.white24 : Colors.black12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => _safeLaunchUrl(release.htmlUrl),
                  ),
                  if (release.apkDownloadUrl != null) ...[
                    const SizedBox(width: 10),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.download_rounded, size: 16),
                      label: const Text('APK Asset'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark ? _accentColor : const Color(0xFF185ABC),
                        foregroundColor: isDark ? const Color(0xFF00315D) : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () => _safeLaunchUrl(release.apkDownloadUrl!),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContributorsCard(
    List<GitHubContributor> contributors,
    bool isDark,
    Color cardBg,
    Color borderColor,
  ) {
    return _buildSectionCard(
      title: 'Repository Contributors',
      icon: Icons.people_outline_rounded,
      isDark: isDark,
      cardBg: cardBg,
      borderColor: borderColor,
      children: [
        if (contributors.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text('No contributors loaded.'),
          )
        else
          ...contributors.asMap().entries.map((entry) {
            final index = entry.key;
            final contributor = entry.value;
            return Column(
              children: [
                if (index > 0) _buildDivider(isDark),
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: CircleAvatar(
                      radius: 20,
                      backgroundColor: isDark ? Colors.white10 : Colors.black12,
                      backgroundImage: contributor.avatarUrl.isNotEmpty
                          ? NetworkImage(contributor.avatarUrl)
                          : null,
                      onBackgroundImageError: contributor.avatarUrl.isNotEmpty
                          ? (_, _) {}
                          : null,
                      child: contributor.avatarUrl.isEmpty
                          ? const Icon(Icons.person, size: 20)
                          : null,
                    ),
                    title: Text(
                      contributor.login,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                    ),
                    subtitle: Text(
                      '${contributor.contributions} ${contributor.contributions == 1 ? "contribution" : "contributions"}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark
                            ? KeyNestPalette.textSecondaryDark
                            : KeyNestPalette.textSecondaryLight,
                      ),
                    ),
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                    onTap: () => _safeLaunchUrl(contributor.htmlUrl),
                  ),
                ),
              ],
            );
          }),
      ],
    );
  }

  Widget _buildAcknowledgementsCard(bool isDark, Color cardBg, Color borderColor) {
    return _buildSectionCard(
      title: 'Acknowledgements & Credits',
      icon: Icons.favorite_border_rounded,
      isDark: isDark,
      cardBg: cardBg,
      borderColor: borderColor,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'KeyNest builds upon and acknowledges the open-source work and foundations created by the AuthPass project and the KeePass community.',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: isDark
                      ? KeyNestPalette.textSecondaryDark
                      : KeyNestPalette.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const FaIcon(FontAwesomeIcons.github, size: 14),
                label: const Text('AuthPass Project'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: isDark ? _accentColor : const Color(0xFF185ABC),
                  side: BorderSide(
                    color: isDark ? Colors.white24 : Colors.black12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () => _safeLaunchUrl('https://github.com/authpass'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLicensesCard(
    GitHubRepoInfo repo,
    bool isDark,
    Color cardBg,
    Color borderColor,
  ) {
    return _buildSectionCard(
      title: 'Open-Source Licenses',
      icon: Icons.policy_outlined,
      isDark: isDark,
      cardBg: cardBg,
      borderColor: borderColor,
      children: [
        _buildListRow(
          icon: Icons.shield_outlined,
          title: 'Project License',
          subtitle: repo.licenseName,
          onTap: () => _safeLaunchUrl('${repo.htmlUrl}/blob/main/LICENSE'),
        ),
        _buildDivider(isDark),
        _buildListRow(
          icon: Icons.source_outlined,
          title: 'Third-Party Dependency Licenses',
          subtitle: 'View bundled open-source package licenses',
          onTap: () {
            showLicensePage(
              context: context,
              applicationName: 'KeyNest',
              applicationVersion: _packageInfo != null
                  ? 'v${_packageInfo!.version} (Build ${_packageInfo!.buildNumber})'
                  : 'v1.0.0',
              applicationIcon: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Image.asset(
                  'assets/images/logo_icon.png',
                  width: 48,
                  height: 48,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.shield_rounded,
                    size: 36,
                    color: _accentColor,
                  ),
                ),
              ),
              applicationLegalese: '© KeyNest • GPL-3.0',
            );
          },
        ),
      ],
    );
  }

  Widget _buildSupportCard(bool isDark, Color cardBg, Color borderColor) {
    return _buildSectionCard(
      title: 'Help & Contact',
      icon: Icons.support_agent_rounded,
      isDark: isDark,
      cardBg: cardBg,
      borderColor: borderColor,
      children: [
        _buildListRow(
          icon: Icons.mail_outline_rounded,
          title: 'Email KeyNest Support',
          subtitle: KeyNestSupportService.supportEmail,
          onTap: () => KeyNestSupportService.contactSupport(context),
        ),
        _buildDivider(isDark),
        _buildListRow(
          icon: Icons.article_outlined,
          title: 'Send Diagnostic Logs',
          subtitle: 'Safely prepare and share diagnostic info',
          onTap: () => KeyNestSupportService.sendLogs(context),
        ),
        _buildDivider(isDark),
        _buildListRow(
          icon: Icons.help_outline_rounded,
          title: 'Official GitHub User Guide',
          subtitle: 'Step-by-step documentation',
          onTap: () => KeyNestSupportService.openUserGuide(context),
        ),
      ],
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required bool isDark,
    required Color cardBg,
    required Color borderColor,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusSection),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.03),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: isDark ? _accentColor : const Color(0xFF185ABC),
                ),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.1,
                    color: isDark
                        ? KeyNestPalette.textPrimaryDark
                        : KeyNestPalette.textPrimaryLight,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.05),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildListRow({
    required dynamic icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Widget iconWidget;
    final color = isDark ? _accentColor : const Color(0xFF185ABC);
    if (icon is IconData) {
      iconWidget = Icon(icon, size: 20, color: color);
    } else if (icon is FaIconData) {
      iconWidget = FaIcon(icon, size: 18, color: color);
    } else {
      iconWidget = const SizedBox();
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              SizedBox(width: 26, child: Center(child: iconWidget)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
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
                color: isDark ? Colors.white38 : Colors.black38,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDivider(bool isDark) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 56,
      endIndent: 16,
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.05),
    );
  }

  Widget _buildLoadingState(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(
          children: [
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(_accentColor),
              strokeWidth: 2.5,
            ),
            const SizedBox(height: 16),
            Text(
              'Loading KeyNest project data from GitHub...',
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? KeyNestPalette.textSecondaryDark
                    : KeyNestPalette.textSecondaryLight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Backwards-compatibility wrapper for any legacy callers of KeyNestAboutDialog.
class KeyNestAboutDialog extends StatelessWidget {
  const KeyNestAboutDialog({super.key, required this.env});

  final Env env;

  @override
  Widget build(BuildContext context) {
    return const AboutScreen();
  }

  static void openDialog(BuildContext context) {
    KeyNestSupportService.openAbout(context);
  }

  static PopupMenuItem<VoidCallback> createAboutMenuItem(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return PopupMenuItem<VoidCallback>(
      value: () {
        KeyNestSupportService.openAbout(context);
      },
      child: ListTile(
        leading: const ImageIcon(AssetImage('assets/images/logo_icon.png')),
        title: Text(loc.menuItemAbout),
      ),
    );
  }
}
