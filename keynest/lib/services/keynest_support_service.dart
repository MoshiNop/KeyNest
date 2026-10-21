import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/about.dart';
import 'package:keynest/utils/logging_utils.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

final _logger = Logger('keynest_support_service');

class KeyNestSupportService {
  static const String officialUserGuideUrl =
      'https://github.com/MoshiNop/KeyNest/blob/main/docs/user-guide/README.md';
  static const String repositoryUrl =
      'https://github.com/MoshiNop/KeyNest';
  static const String supportEmail = 'moshidevs@gmail.com';
  static const String supportSubject = 'KeyNest Support';

  static bool _isNavigatingAbout = false;
  static DateTime? _lastContactLaunch;

  /// Opens the official KeyNest GitHub user guide safely in external browser.
  static Future<void> openUserGuide(BuildContext context) async {
    try {
      final analytics = Provider.of<Analytics>(context, listen: false);
      analytics.events.trackActionPressed(action: 'help');
    } catch (_) {}

    final uri = Uri.parse(officialUserGuideUrl);
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        // Fallback to default launcher
        await launchUrl(uri);
      }
    } catch (e, stack) {
      _logger.warning('Failed to open user guide URL: $e', e, stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Could not open browser. Link copied to clipboard.'),
            action: SnackBarAction(
              label: 'Copy',
              onPressed: () {
                Clipboard.setData(const ClipboardData(text: officialUserGuideUrl));
              },
            ),
          ),
        );
      }
    }
  }

  /// Navigates to the GitHub-powered About page with debouncing protection.
  static Future<void> openAbout(BuildContext context) async {
    if (_isNavigatingAbout) {
      return;
    }
    _isNavigatingAbout = true;

    try {
      final analytics = Provider.of<Analytics>(context, listen: false);
      analytics.events.trackActionPressed(action: 'about');
    } catch (_) {}

    try {
      await Navigator.of(context).push(AboutScreen.route());
    } finally {
      // Release debounce lock after navigation completes
      _isNavigatingAbout = false;
    }
  }

  /// Opens platform email client addressed to moshidevs@gmail.com with fallback.
  static Future<void> contactSupport(BuildContext context) async {
    // Debounce rapid repeated taps
    final now = DateTime.now();
    if (_lastContactLaunch != null &&
        now.difference(_lastContactLaunch!) < const Duration(seconds: 1)) {
      return;
    }
    _lastContactLaunch = now;

    try {
      final analytics = Provider.of<Analytics>(context, listen: false);
      analytics.events.trackActionPressed(action: 'contact');
    } catch (_) {}

    final emailUri = Uri(
      scheme: 'mailto',
      path: supportEmail,
      queryParameters: {
        'subject': supportSubject,
      },
    );

    bool launched = false;
    try {
      if (await canLaunchUrl(emailUri)) {
        launched = await launchUrl(emailUri);
      }
    } catch (e) {
      _logger.warning('Failed to launch email uri directly: $e');
    }

    if (!launched && context.mounted) {
      await _showContactFallbackDialog(context);
    }
  }

  static Future<void> _showContactFallbackDialog(BuildContext context) async {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.mail_outline_rounded,
              color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
            ),
            const SizedBox(width: 10),
            const Text('Contact Support'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No default email application was detected. You can reach out directly at:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: (isDark ? KeyNestPalette.cardDark : KeyNestPalette.cardLight)
                    .withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      supportEmail,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 20),
                    tooltip: 'Copy Email',
                    onPressed: () {
                      Clipboard.setData(const ClipboardData(text: supportEmail));
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Support email copied to clipboard.'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy Address'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              foregroundColor: isDark ? const Color(0xFF00315D) : Colors.white,
            ),
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: supportEmail));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Support email copied to clipboard.'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Sanitizes raw log text to ensure no secrets, passwords, or keys are exposed.
  static String sanitizeLogContent(String raw) {
    var sanitized = raw;

    // Redact password fields and values
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'(password|passphrase|secret|token|bearer|key|masterPassword)[\s:=]+([^\s,;]+)',
          caseSensitive: false),
      (match) => '${match.group(1)}: [REDACTED]',
    );

    // Redact Bearer tokens
    sanitized = sanitized.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9_\-\.]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );

    // Redact refresh/access tokens
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'(refresh_token|access_token|client_secret)[\s:=]+([^\s,;]+)',
          caseSensitive: false),
      (match) => '${match.group(1)}: [REDACTED]',
    );

    // Redact potential 32/64 char hex/base64 crypto keys in logging statements
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'(keyData|kdbxKey|encryptionKey)[\s:=]+([A-Fa-f0-9]{32,64})',
          caseSensitive: false),
      (match) => '${match.group(1)}: [REDACTED_KEY]',
    );

    return sanitized;
  }

  /// Prepares diagnostic logs safely and dispatches via sharing/email workflow.
  static Future<void> sendLogs(
    BuildContext context, {
    String errorDescription = '',
  }) async {
    try {
      final analytics = Provider.of<Analytics>(context, listen: false);
      analytics.events.trackActionPressed(action: 'sendLogs');
    } catch (_) {}

    final env = Provider.of<Env>(context, listen: false);
    final appInfo = await env.getAppInfo();
    final loggingUtil = LoggingUtils();

    // 1. Determine existing log files
    List<io.File> logFiles = [];
    try {
      logFiles = loggingUtil.rotatingFileLoggerFiles;
    } catch (_) {}

    // Check fallback log directory if rotatingFileLoggerFiles is empty
    if (logFiles.isEmpty && !KeyNestPlatform.isWeb) {
      try {
        final logsDir = await PathUtils().getLogDirectory();
        final defaultLog = logsDir.childFile('app.log.txt');
        if (defaultLog.existsSync()) {
          logFiles = [io.File(defaultLog.path)];
        }
      } catch (_) {}
    }

    // 2. Read and sanitize logs
    final rawBuffer = StringBuffer();
    final deviceInfo = await LoggingUtils.getDebugDeviceInfo();

    rawBuffer.writeln('=== KeyNest Diagnostic Report ===');
    rawBuffer.writeln('App Version: ${appInfo.versionLabel} (${appInfo.buildNumber})');
    rawBuffer.writeln('Platform: ${KeyNestPlatform.operatingSystem} ${KeyNestPlatform.operatingSystemVersion}');
    rawBuffer.writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}');
    rawBuffer.writeln('Device Info: ${jsonEncode(deviceInfo)}');
    if (errorDescription.isNotEmpty) {
      rawBuffer.writeln('Context / Error Details: $errorDescription');
    }
    rawBuffer.writeln('==================================\n');

    if (logFiles.isNotEmpty) {
      for (final file in logFiles) {
        try {
          if (file.existsSync()) {
            final content = await file.readAsString();
            rawBuffer.writeln('--- Log Source: ${p.basename(file.path)} ---');
            rawBuffer.writeln(content);
          }
        } catch (e) {
          rawBuffer.writeln('Error reading log file ${file.path}: $e');
        }
      }
    } else {
      rawBuffer.writeln('No persistent log file found on device.');
    }

    final sanitizedContent = sanitizeLogContent(rawBuffer.toString());

    // 3. Write sanitized log to temporary file
    io.File? sanitizedFile;
    if (!KeyNestPlatform.isWeb) {
      try {
        final appData = await PathUtils().getAppDataDirectory();
        sanitizedFile = io.File(p.join(appData.path, 'keynest_sanitized_diagnostic.txt'));
        await sanitizedFile.writeAsString(sanitizedContent);
      } catch (e) {
        _logger.warning('Failed to write temporary sanitized log file: $e');
      }
    }

    final subject = 'KeyNest Diagnostic Logs - ${appInfo.versionLabel} (${KeyNestPlatform.operatingSystem})';
    final emailBody =
        'KeyNest Diagnostic Information\n'
        'App: ${appInfo.versionLabel} (${appInfo.buildNumber})\n'
        'Platform: ${KeyNestPlatform.operatingSystem} ${KeyNestPlatform.operatingSystemVersion}\n'
        'Generated: ${DateTime.now().toUtc().toIso8601String()}\n\n'
        'Attached are the sanitized diagnostic logs.\n'
        'Please describe the issue or behavior you observed below:\n\n';

    // 4. Try FlutterEmailSender on supported mobile platforms
    bool emailSenderDispatched = false;
    if ((KeyNestPlatform.isAndroid || KeyNestPlatform.isIOS) && sanitizedFile != null) {
      try {
        final email = Email(
          subject: subject,
          body: emailBody,
          recipients: [supportEmail],
          attachmentPaths: [sanitizedFile.path],
        );
        await FlutterEmailSender.send(email);
        emailSenderDispatched = true;
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Email composer opened with diagnostic logs attached.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        _logger.info('FlutterEmailSender unavailable or cancelled: $e');
      }
    }

    // 5. Fallback dialog on desktop or if email sender did not dispatch
    if (!emailSenderDispatched && context.mounted) {
      await _showLogsFallbackDialog(
        context,
        sanitizedContent,
        sanitizedFile?.path,
        subject,
        emailBody,
      );
    }
  }

  static Future<void> _showLogsFallbackDialog(
    BuildContext context,
    String sanitizedContent,
    String? filePath,
    String subject,
    String body,
  ) async {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.article_outlined,
              color: isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary,
            ),
            const SizedBox(width: 10),
            const Text('Diagnostic Logs Prepared'),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Diagnostic logs have been sanitized (all secrets and passwords redacted). You can copy the logs or email them to support:',
                style: TextStyle(fontSize: 13.5),
              ),
              if (filePath != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Saved file: ${p.basename(filePath)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Container(
                height: 120,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (isDark ? Colors.black26 : Colors.grey.shade100),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark ? Colors.white12 : Colors.black12,
                  ),
                ),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    child: Text(
                      sanitizedContent.length > 2500
                          ? '${sanitizedContent.substring(0, 2500)}\n\n[...truncated in preview...]'
                          : sanitizedContent,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy Logs'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: sanitizedContent));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Sanitized diagnostic logs copied to clipboard.'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.mail_outline_rounded, size: 16),
            label: const Text('Send via Email'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark
                  ? KeyNestPalette.primaryDark
                  : KeyNestPalette.primary,
              foregroundColor: isDark ? const Color(0xFF00315D) : Colors.white,
            ),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final mailUri = Uri(
                scheme: 'mailto',
                path: supportEmail,
                queryParameters: {
                  'subject': subject,
                  'body': '$body\n--- Logs ---\n${sanitizedContent.length > 1800 ? sanitizedContent.substring(0, 1800) : sanitizedContent}',
                },
              );
              try {
                await launchUrl(mailUri);
              } catch (_) {
                if (context.mounted) {
                  await Clipboard.setData(ClipboardData(text: sanitizedContent));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not open email client. Logs copied to clipboard.'),
                      ),
                    );
                  }
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
