// ignore_for_file: always_put_control_body_on_new_line, unawaited_futures
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:http/http.dart' as http;
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';

final _logger = Logger('keynest.dynamic_icon_service');

/// Dedicated service for fetching and caching dynamic website icons (favicons)
/// without exposing sensitive vault or path data.
class KeyNestDynamicIconService {
  KeyNestDynamicIconService._();
  static final KeyNestDynamicIconService instance =
      KeyNestDynamicIconService._();

  static final Map<String, Uint8List> _memoryCache = <String, Uint8List>{};
  static final Map<String, DateTime> _failedDomains = <String, DateTime>{};
  static final Set<String> _diskMissDomains = <String>{};
  static final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};
  static const Duration _failedDomainTtl = Duration(minutes: 5);
  static Directory? _cachedDiskDirectory;
  bool _networkFetchEnabled = false;

  /// Controls whether network requests for website icons are permitted.
  /// Defaults to false. When disabled, only cached icons are served.
  bool get networkFetchEnabled => _networkFetchEnabled;
  set networkFetchEnabled(bool value) {
    _networkFetchEnabled = value;
    if (!value) {
      _inFlight.clear();
    } else {
      _failedDomains.clear();
    }
  }

  static bool _isFailedDomain(String domain) {
    final failedAt = _failedDomains[domain];
    if (failedAt == null) {
      return false;
    }
    if (DateTime.now().difference(failedAt) > _failedDomainTtl) {
      _failedDomains.remove(domain);
      return false;
    }
    return true;
  }

  /// Ensures disk cache directory is initialized and cached for fast synchronous checks.
  Future<void> initDiskCache() async {
    if (_cachedDiskDirectory != null || KeyNestPlatform.isWeb) {
      return;
    }
    try {
      final docDir = await PathUtils().getAppDocDirectory(ensureCreated: true);
      final cacheDir = docDir.childDirectory('icon_cache');
      if (!cacheDir.existsSync()) {
        await cacheDir.create(recursive: true);
      }
      _cachedDiskDirectory = cacheDir;
    } catch (_) {}
  }

  /// Extracts and normalizes the public root domain from a given URL or host string.
  /// Never transmits full paths, queries, or credentials to third-party services.
  static String? extractDomain(String? rawUrl) {
    if (rawUrl == null) {
      return null;
    }
    var trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    // Reject URLs with line breaks or suspicious content
    if (trimmed.contains('\n') || trimmed.contains('\r')) {
      return null;
    }

    if (!trimmed.contains('://')) {
      trimmed = 'https://$trimmed';
    }

    try {
      final uri = Uri.tryParse(trimmed);
      if (uri == null || uri.host.isEmpty) {
        return null;
      }

      var host = uri.host.toLowerCase().trim();

      // Remove port if present in host
      if (host.contains(':')) {
        host = host.split(':').first;
      }

      // Ignore local or loopback domains
      if (host == 'localhost' ||
          host == '127.0.0.1' ||
          host.startsWith('192.168.') ||
          host.startsWith('10.') ||
          !host.contains('.')) {
        return null;
      }

      // Normalize www.
      if (host.startsWith('www.')) {
        host = host.substring(4);
      }

      return host.isNotEmpty ? host : null;
    } catch (_) {
      return null;
    }
  }

  /// Synchronously returns cached icon bytes from in-memory cache or initialized disk cache if available.
  Uint8List? getCachedIconSync(String? rawUrl) {
    final domain = extractDomain(rawUrl);
    if (domain == null) {
      return null;
    }
    final inMem = _memoryCache[domain];
    if (inMem != null && inMem.isNotEmpty) {
      return inMem;
    }
    if (!KeyNestPlatform.isWeb &&
        _cachedDiskDirectory != null &&
        !_diskMissDomains.contains(domain)) {
      try {
        final file = _cachedDiskDirectory!.childFile(_diskFileName(domain));
        if (file.existsSync()) {
          final bytes = file.readAsBytesSync();
          if (bytes.isNotEmpty) {
            _memoryCache[domain] = bytes;
            return bytes;
          }
        } else {
          // Negative cache to prevent repeated synchronous disk stat checks during fast list scrolling
          _diskMissDomains.add(domain);
        }
      } catch (_) {}
    }
    return null;
  }

  /// Asynchronously returns cached icon bytes from in-memory cache or disk cache
  /// without triggering network calls.
  Future<Uint8List?> getCachedIcon(String? rawUrl) async {
    final domain = extractDomain(rawUrl);
    if (domain == null) {
      return null;
    }
    if (_memoryCache.containsKey(domain)) {
      return _memoryCache[domain];
    }
    if (!KeyNestPlatform.isWeb) {
      try {
        final diskBytes = await _readFromDiskCache(domain);
        if (diskBytes != null && diskBytes.isNotEmpty) {
          _memoryCache[domain] = diskBytes;
          _diskMissDomains.remove(domain);
          return diskBytes;
        }
      } catch (_) {}
    }
    return null;
  }

  /// Retrieves icon bytes for [rawUrl], checking cache first, and attempting a
  /// fast network fetch only if [networkFetchEnabled] is true and not found within [timeout].
  Future<Uint8List?> getOrFetchIcon(
    String? rawUrl, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final cached = await getCachedIcon(rawUrl);
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    if (!_networkFetchEnabled) {
      return null;
    }
    try {
      return await getIcon(rawUrl).timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  /// Asynchronously retrieves icon bytes for [rawUrl], checking memory cache,
  /// disk cache, and remote favicon services (only if network fetching is enabled).
  Future<Uint8List?> getIcon(String? rawUrl) async {
    final domain = extractDomain(rawUrl);
    if (domain == null) {
      return null;
    }

    // 1. Fast in-memory cache hit
    final inMem = _memoryCache[domain];
    if (inMem != null && inMem.isNotEmpty) {
      return inMem;
    }

    // 2. Already known failed domain within TTL (avoid repeated failed network calls)
    if (_isFailedDomain(domain)) {
      return null;
    }

    // 3. Deduplicate concurrent requests for the same domain
    if (_inFlight.containsKey(domain)) {
      return _inFlight[domain];
    }

    final future = _loadIconForDomain(domain);
    _inFlight[domain] = future;
    try {
      final bytes = await future;
      return bytes;
    } finally {
      _inFlight.remove(domain);
    }
  }

  Future<Uint8List?> _loadIconForDomain(String domain) async {
    // 1. Check disk cache if not on web (always serve cached icons even if network is disabled)
    if (!KeyNestPlatform.isWeb) {
      try {
        final diskBytes = await _readFromDiskCache(domain);
        if (diskBytes != null && diskBytes.isNotEmpty) {
          _memoryCache[domain] = diskBytes;
          _diskMissDomains.remove(domain);
          return diskBytes;
        }
      } catch (e) {
        _logger.fine('Disk cache read error for $domain: $e');
      }
    }

    // If network fetching is disabled, do NOT make remote calls
    if (!_networkFetchEnabled) {
      return null;
    }

    // 2. Fetch from remote favicon services (Google S2, DuckDuckGo, direct favicon)
    final remoteBytes = await _fetchFromRemoteServices(domain);
    if (remoteBytes != null && remoteBytes.isNotEmpty) {
      _memoryCache[domain] = remoteBytes;
      _diskMissDomains.remove(domain);
      _failedDomains.remove(domain);
      if (!KeyNestPlatform.isWeb) {
        unawaited(_saveToDiskCache(domain, remoteBytes));
      }
      return remoteBytes;
    }

    // 3. Negative cache with timestamp
    _failedDomains[domain] = DateTime.now();
    return null;
  }

  Future<Uint8List?> _fetchFromRemoteServices(String domain) async {
    if (!_networkFetchEnabled) {
      return null;
    }
    final client = http.Client();
    const headers = {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept':
          'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
    };

    try {
      // Primary: Google S2 Favicon service (128px PNG)
      final s2Url = Uri.parse(
        'https://www.google.com/s2/favicons?domain=$domain&sz=128',
      );
      final s2Response = await client
          .get(s2Url, headers: headers)
          .timeout(const Duration(seconds: 4));
      if (!_networkFetchEnabled) {
        return null;
      }
      if (s2Response.statusCode == 200 &&
          _isValidImageBytes(s2Response.bodyBytes)) {
        return s2Response.bodyBytes;
      }

      // Secondary fallback: DuckDuckGo favicon service
      final ddgUrl = Uri.parse('https://icons.duckduckgo.com/ip3/$domain.ico');
      final ddgResponse = await client
          .get(ddgUrl, headers: headers)
          .timeout(const Duration(seconds: 4));
      if (!_networkFetchEnabled) {
        return null;
      }
      if (ddgResponse.statusCode == 200 &&
          _isValidImageBytes(ddgResponse.bodyBytes)) {
        return ddgResponse.bodyBytes;
      }

      // Tertiary fallback: Direct website root favicon
      final directUrl = Uri.parse('https://$domain/favicon.ico');
      final directResponse = await client
          .get(directUrl, headers: headers)
          .timeout(const Duration(seconds: 4));
      if (!_networkFetchEnabled) {
        return null;
      }
      if (directResponse.statusCode == 200 &&
          _isValidImageBytes(directResponse.bodyBytes)) {
        return directResponse.bodyBytes;
      }
    } catch (e) {
      _logger.fine('Network error fetching favicon for $domain: $e');
    } finally {
      client.close();
    }
    return null;
  }

  bool _isValidImageBytes(Uint8List bytes) {
    if (bytes.length < 32) {
      return false;
    }

    // Check PNG header (0x89, 'P', 'N', 'G')
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // Check ICO header (0x00, 0x00, 0x01, 0x00)
    if (bytes[0] == 0x00 &&
        bytes[1] == 0x00 &&
        bytes[2] == 0x01 &&
        bytes[3] == 0x00) {
      return true;
    }
    // Check JPEG header (0xFF, 0xD8, 0xFF)
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }
    // Check GIF header (GIF87a or GIF89a: 'G', 'I', 'F')
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return true;
    }
    // Check WebP header (RIFF ... WEBP)
    if (bytes.length > 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return true;
    }

    return false;
  }

  String _diskFileName(String domain) {
    final hash = md5.convert(utf8.encode(domain)).toString();
    return 'favicon_$hash.png';
  }

  Future<Uint8List?> _readFromDiskCache(String domain) async {
    try {
      final docDir = await PathUtils().getAppDocDirectory(ensureCreated: true);
      final cacheDir = docDir.childDirectory('icon_cache');
      _cachedDiskDirectory = cacheDir;
      if (!cacheDir.existsSync()) {
        return null;
      }

      final file = cacheDir.childFile(_diskFileName(domain));
      if (file.existsSync()) {
        return await file.readAsBytes();
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveToDiskCache(String domain, Uint8List bytes) async {
    try {
      final docDir = await PathUtils().getAppDocDirectory(ensureCreated: true);
      final cacheDir = docDir.childDirectory('icon_cache');
      _cachedDiskDirectory = cacheDir;
      if (!cacheDir.existsSync()) {
        await cacheDir.create(recursive: true);
      }
      final file = cacheDir.childFile(_diskFileName(domain));
      await file.writeAsBytes(bytes, flush: true);
      _diskMissDomains.remove(domain);
    } catch (_) {}
  }

  /// Clears in-memory and failed domains caches.
  static void clearMemoryCache() {
    _memoryCache.clear();
    _failedDomains.clear();
    _diskMissDomains.clear();
    _inFlight.clear();
  }
}
