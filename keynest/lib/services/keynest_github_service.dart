import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('keynest_github_service');

class GitHubRepoInfo {
  const GitHubRepoInfo({
    required this.name,
    required this.fullName,
    required this.htmlUrl,
    required this.description,
    required this.licenseName,
    required this.licenseSpdx,
    required this.starsCount,
    required this.forksCount,
    required this.openIssuesCount,
    required this.defaultBranch,
  });

  factory GitHubRepoInfo.fromJson(Map<String, dynamic> json) {
    final licenseMap = json['license'] as Map<String, dynamic>?;
    return GitHubRepoInfo(
      name: json['name'] as String? ?? 'KeyNest',
      fullName: json['full_name'] as String? ?? 'MoshiNop/KeyNest',
      htmlUrl: json['html_url'] as String? ?? 'https://github.com/MoshiNop/KeyNest',
      description: (json['description'] as String?)?.isNotEmpty == true
          ? json['description'] as String
          : 'Free, open-source, cross-platform password manager powered by the KeePass KDBX format.',
      licenseName: licenseMap?['name'] as String? ?? 'GNU General Public License v3.0',
      licenseSpdx: licenseMap?['spdx_id'] as String? ?? 'GPL-3.0',
      starsCount: json['stargazers_count'] as int? ?? 0,
      forksCount: json['forks_count'] as int? ?? 0,
      openIssuesCount: json['open_issues_count'] as int? ?? 0,
      defaultBranch: json['default_branch'] as String? ?? 'main',
    );
  }

  final String name;
  final String fullName;
  final String htmlUrl;
  final String description;
  final String licenseName;
  final String licenseSpdx;
  final int starsCount;
  final int forksCount;
  final int openIssuesCount;
  final String defaultBranch;

  Map<String, dynamic> toJson() => {
    'name': name,
    'full_name': fullName,
    'html_url': htmlUrl,
    'description': description,
    'license': {
      'name': licenseName,
      'spdx_id': licenseSpdx,
    },
    'stargazers_count': starsCount,
    'forks_count': forksCount,
    'open_issues_count': openIssuesCount,
    'default_branch': defaultBranch,
  };

  static const defaultRepo = GitHubRepoInfo(
    name: 'KeyNest',
    fullName: 'MoshiNop/KeyNest',
    htmlUrl: 'https://github.com/MoshiNop/KeyNest',
    description: 'Free, open-source, cross-platform password manager powered by the KeePass KDBX format.',
    licenseName: 'GNU General Public License v3.0',
    licenseSpdx: 'GPL-3.0',
    starsCount: 0,
    forksCount: 0,
    openIssuesCount: 0,
    defaultBranch: 'main',
  );
}

class GitHubContributor {
  const GitHubContributor({
    required this.login,
    required this.avatarUrl,
    required this.htmlUrl,
    required this.contributions,
  });

  factory GitHubContributor.fromJson(Map<String, dynamic> json) {
    return GitHubContributor(
      login: json['login'] as String? ?? 'Contributor',
      avatarUrl: json['avatar_url'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? 'https://github.com/MoshiNop',
      contributions: json['contributions'] as int? ?? 1,
    );
  }

  final String login;
  final String avatarUrl;
  final String htmlUrl;
  final int contributions;

  Map<String, dynamic> toJson() => {
    'login': login,
    'avatar_url': avatarUrl,
    'html_url': htmlUrl,
    'contributions': contributions,
  };

  static const defaultContributors = [
    GitHubContributor(
      login: 'MoshiNop',
      avatarUrl: 'https://avatars.githubusercontent.com/u/212212047?v=4',
      htmlUrl: 'https://github.com/MoshiNop',
      contributions: 20,
    ),
  ];
}

class GitHubRelease {
  const GitHubRelease({
    required this.tagName,
    required this.name,
    required this.publishedAt,
    required this.htmlUrl,
    required this.body,
    this.apkAssetName,
    this.apkDownloadUrl,
  });

  factory GitHubRelease.fromJson(Map<String, dynamic> json) {
    String? assetName;
    String? downloadUrl;
    final assets = json['assets'] as List<dynamic>?;
    if (assets != null && assets.isNotEmpty) {
      final firstAsset = assets.first as Map<String, dynamic>?;
      assetName = firstAsset?['name'] as String?;
      downloadUrl = firstAsset?['browser_download_url'] as String?;
    }

    return GitHubRelease(
      tagName: json['tag_name'] as String? ?? 'v1.0.0',
      name: json['name'] as String? ?? 'KeyNest v1.0.0',
      publishedAt: json['published_at'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? 'https://github.com/MoshiNop/KeyNest/releases',
      body: json['body'] as String? ?? 'Initial production release of KeyNest.',
      apkAssetName: assetName,
      apkDownloadUrl: downloadUrl,
    );
  }

  final String tagName;
  final String name;
  final String publishedAt;
  final String htmlUrl;
  final String body;
  final String? apkAssetName;
  final String? apkDownloadUrl;

  Map<String, dynamic> toJson() => {
    'tag_name': tagName,
    'name': name,
    'published_at': publishedAt,
    'html_url': htmlUrl,
    'body': body,
    'assets': [
      if (apkAssetName != null)
        {
          'name': apkAssetName,
          'browser_download_url': apkDownloadUrl,
        },
    ],
  };

  static const defaultRelease = GitHubRelease(
    tagName: 'v1.0.0',
    name: 'KeyNest v1.0.0',
    publishedAt: '2026-10-20T00:59:14Z',
    htmlUrl: 'https://github.com/MoshiNop/KeyNest/releases/tag/v1.0.0',
    body: 'Initial production release of KeyNest, an open-source password manager based on the KeePass KDBX format.',
    apkAssetName: 'Keynest-release-arm64-v8a.apk',
    apkDownloadUrl: 'https://github.com/MoshiNop/KeyNest/releases/download/v1.0.0/Keynest-release-arm64-v8a.apk',
  );
}

class KeyNestAboutData {
  const KeyNestAboutData({
    required this.repo,
    required this.contributors,
    this.latestRelease,
    this.isFromCache = false,
    this.isRateLimited = false,
    this.errorMessage,
  });

  factory KeyNestAboutData.fromJson(Map<String, dynamic> json, {bool isFromCache = true}) {
    final repoJson = json['repo'] as Map<String, dynamic>? ?? {};
    final contribListJson = json['contributors'] as List<dynamic>? ?? [];
    final releaseJson = json['release'] as Map<String, dynamic>?;

    return KeyNestAboutData(
      repo: GitHubRepoInfo.fromJson(repoJson),
      contributors: contribListJson
          .map((c) => GitHubContributor.fromJson(c as Map<String, dynamic>))
          .toList(),
      latestRelease: releaseJson != null ? GitHubRelease.fromJson(releaseJson) : null,
      isFromCache: isFromCache,
    );
  }

  final GitHubRepoInfo repo;
  final List<GitHubContributor> contributors;
  final GitHubRelease? latestRelease;
  final bool isFromCache;
  final bool isRateLimited;
  final String? errorMessage;

  Map<String, dynamic> toJson() => {
    'repo': repo.toJson(),
    'contributors': contributors.map((c) => c.toJson()).toList(),
    'release': latestRelease?.toJson(),
  };

  static const fallback = KeyNestAboutData(
    repo: GitHubRepoInfo.defaultRepo,
    contributors: GitHubContributor.defaultContributors,
    latestRelease: GitHubRelease.defaultRelease,
    isFromCache: false,
  );
}

class KeyNestGitHubService {
  static const String owner = 'MoshiNop';
  static const String repoName = 'KeyNest';
  static const String apiBase = 'https://api.github.com/repos/$owner/$repoName';
  static const String _cacheFileName = 'keynest_github_about_cache.json';

  static Map<String, dynamic>? _memoryCache;
  static KeyNestAboutData? _mockData;

  /// Sets mock data for tests.
  static void setMockData(KeyNestAboutData? data) {
    _mockData = data;
  }

  /// Fetches project data from GitHub API with disk caching and rate-limit fallbacks.
  static Future<KeyNestAboutData> fetchAboutData({bool forceRefresh = false}) async {
    if (_mockData != null) {
      return _mockData!;
    }
    // 1. Try reading disk cache first if not force-refreshing
    if (!forceRefresh) {
      final cached = await _loadCache();
      if (cached != null) {
        return cached;
      }
    }

    try {
      final headers = {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'KeyNest-App',
      };

      final client = http.Client();
      try {
        final repoResponseFuture = client.get(Uri.parse(apiBase), headers: headers);
        final contribResponseFuture = client.get(Uri.parse('$apiBase/contributors'), headers: headers);
        final releasesResponseFuture = client.get(Uri.parse('$apiBase/releases'), headers: headers);

        final results = await Future.wait([
          repoResponseFuture,
          contribResponseFuture,
          releasesResponseFuture,
        ]).timeout(const Duration(seconds: 12));

        final repoResp = results[0];
        final contribResp = results[1];
        final releasesResp = results[2];

        final isRateLimited = repoResp.statusCode == 403 ||
            repoResp.statusCode == 429 ||
            contribResp.statusCode == 403 ||
            contribResp.statusCode == 429;

        if (isRateLimited) {
          _logger.warning('GitHub API rate limit hit.');
          final cached = await _loadCache();
          if (cached != null) {
            return KeyNestAboutData(
              repo: cached.repo,
              contributors: cached.contributors,
              latestRelease: cached.latestRelease,
              isFromCache: true,
              isRateLimited: true,
            );
          }
          return const KeyNestAboutData(
            repo: GitHubRepoInfo.defaultRepo,
            contributors: GitHubContributor.defaultContributors,
            latestRelease: GitHubRelease.defaultRelease,
            isFromCache: false,
            isRateLimited: true,
          );
        }

        GitHubRepoInfo repoInfo = GitHubRepoInfo.defaultRepo;
        if (repoResp.statusCode == 200) {
          final decoded = jsonDecode(repoResp.body) as Map<String, dynamic>;
          repoInfo = GitHubRepoInfo.fromJson(decoded);
        }

        List<GitHubContributor> contributors = GitHubContributor.defaultContributors;
        if (contribResp.statusCode == 200) {
          final decodedList = jsonDecode(contribResp.body) as List<dynamic>;
          if (decodedList.isNotEmpty) {
            contributors = decodedList
                .map((item) => GitHubContributor.fromJson(item as Map<String, dynamic>))
                .toList();
          }
        }

        GitHubRelease? latestRelease = GitHubRelease.defaultRelease;
        if (releasesResp.statusCode == 200) {
          final decodedList = jsonDecode(releasesResp.body) as List<dynamic>;
          if (decodedList.isNotEmpty) {
            latestRelease = GitHubRelease.fromJson(decodedList.first as Map<String, dynamic>);
          }
        }

        final freshData = KeyNestAboutData(
          repo: repoInfo,
          contributors: contributors,
          latestRelease: latestRelease,
          isFromCache: false,
        );

        // Save to cache asynchronously
        await _saveCache(freshData);

        return freshData;
      } finally {
        client.close();
      }
    } catch (e, stack) {
      _logger.warning('Failed to fetch from GitHub API: $e', e, stack);
      final cached = await _loadCache();
      if (cached != null) {
        return KeyNestAboutData(
          repo: cached.repo,
          contributors: cached.contributors,
          latestRelease: cached.latestRelease,
          isFromCache: true,
          errorMessage: 'Offline or network unavailable. Showing cached data.',
        );
      }
      return KeyNestAboutData(
        repo: GitHubRepoInfo.defaultRepo,
        contributors: GitHubContributor.defaultContributors,
        latestRelease: GitHubRelease.defaultRelease,
        isFromCache: false,
        errorMessage: 'Unable to reach GitHub. Showing offline project details.',
      );
    }
  }

  static Future<KeyNestAboutData?> _loadCache() async {
    if (_memoryCache != null) {
      return KeyNestAboutData.fromJson(_memoryCache!, isFromCache: true);
    }
    if (KeyNestPlatform.isWeb) {
      return null;
    }
    try {
      final appDataDir = await PathUtils().getAppDataDirectory();
      final cacheFile = io.File(p.join(appDataDir.path, _cacheFileName));
      if (cacheFile.existsSync()) {
        final content = await cacheFile.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          _memoryCache = decoded;
          return KeyNestAboutData.fromJson(decoded, isFromCache: true);
        }
      }
    } catch (e) {
      _logger.warning('Error reading GitHub cache file: $e');
    }
    return null;
  }

  static Future<void> _saveCache(KeyNestAboutData data) async {
    _memoryCache = data.toJson();
    if (KeyNestPlatform.isWeb) {
      return;
    }
    try {
      final appDataDir = await PathUtils().getAppDataDirectory();
      final cacheFile = io.File(p.join(appDataDir.path, _cacheFileName));
      await cacheFile.writeAsString(jsonEncode(data.toJson()));
    } catch (e) {
      _logger.warning('Error saving GitHub cache file: $e');
    }
  }
}
