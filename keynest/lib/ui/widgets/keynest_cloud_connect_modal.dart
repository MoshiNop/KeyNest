import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keynest/bloc/kdbx/file_source_ui.dart';
import 'package:keynest/cloud_storage/cloud_config_store.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_auth.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_provider.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/cloud_storage/google_drive/sync/gdrive_auth.dart';
import 'package:keynest/cloud_storage/webdav/webdav_provider.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/screens/keynest_cloud_management_screen.dart';
import 'package:keynest/ui/screens/keynest_cloud_vault_browser_screen.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/platform.dart';

class KeyNestCloudConnectModal extends StatefulWidget {
  const KeyNestCloudConnectModal({
    super.key,
    required this.provider,
  });

  final CloudStorageProvider provider;

  static Future<bool?> show(
    BuildContext context,
    CloudStorageProvider provider,
  ) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => KeyNestCloudConnectModal(provider: provider),
    );
  }

  @override
  State<KeyNestCloudConnectModal> createState() =>
      _KeyNestCloudConnectModalState();
}

class _KeyNestCloudConnectModalState extends State<KeyNestCloudConnectModal> {
  // WebDAV controllers
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  bool _obscurePass = true;

  // Dropbox controllers
  int _dropboxAuthMode = 0; // 0 = OAuth Redirect, 1 = Personal Access Token
  final _codeController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _obscurePat = true;

  // Dropbox PKCE session
  DropboxPkceSession? _pkceSession;

  bool _isLoading = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _loadStoredCredentials();
  }

  Future<void> _loadStoredCredentials() async {
    await CloudConfigStore.instance.load();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _tokenController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _connectWebDav() async {
    final url = _urlController.text.trim();
    final user = _userController.text.trim();
    final pass = _passController.text;

    if (url.isEmpty || user.isEmpty || pass.isEmpty) {
      setState(
        () => _errorMessage = 'Please fill in all server and login fields.',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final webDav = widget.provider as WebDavProvider;
      await webDav.connectWithCredentials(
        url: url,
        username: user,
        password: pass,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Connection failed: $e';
        });
      }
    }
  }

  Future<void> _startDropboxBrowserLogin() async {
    final dropbox = widget.provider as DropboxProvider;
    final effectiveKey = dropbox.configuredAppKey;

    if (effectiveKey.isEmpty) {
      setState(() {
        _errorMessage =
            'Cloud connection is not configured correctly. Please contact the app administrator.';
        _successMessage = null;
      });
      return;
    }

    try {
      final redirect = dropbox.configuredRedirectUri;
      _pkceSession = dropbox.createPkceSession(
        appKey: effectiveKey,
        redirectUri: redirect,
      );
      await DialogUtils.openUrl(_pkceSession!.authorizeUrl.toString());

      // If a loopback redirect URI is configured on desktop, start listening in background
      if (redirect != null &&
          (redirect.startsWith('http://127.0.0.1') ||
              redirect.startsWith('http://localhost'))) {
        final uri = Uri.parse(redirect);
        final port = uri.port != 0 ? uri.port : 8080;
        unawaited(
          dropbox.authService
              .captureLoopbackRedirect(
                port: port,
                session: _pkceSession!,
              )
              .then((code) async {
                if (code != null && mounted) {
                  _codeController.text = code;
                  await _connectDropbox();
                }
              })
              .catchError((_) {}),
        );
      }

      if (mounted) {
        setState(() {
          _errorMessage = null;
          _successMessage =
              'Dropbox opened in your browser. Log in and tap "Allow". Dropbox will display an authorization code on the screen.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to launch Dropbox authorization browser: $e';
          _successMessage = null;
        });
      }
    }
  }

  Future<void> _connectDropbox() async {
    final dropbox = widget.provider as DropboxProvider;
    if (_dropboxAuthMode == 0) {
      final rawInput = _codeController.text.trim();

      if (rawInput.isEmpty) {
        // If code field is empty, launch the browser flow first
        await _startDropboxBrowserLogin();
        return;
      }

      // Auto-extract code if the user pasted the entire redirected URL or code
      String code;
      try {
        code = DropboxAuthService.extractCodeOrUrl(
          rawInput,
          session: _pkceSession,
        );
      } on DropboxAuthException catch (e) {
        setState(() {
          _errorMessage = 'Dropbox authorization was cancelled: ${e.message}';
          _successMessage = null;
        });
        return;
      }

      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _successMessage = null;
      });

      try {
        final effectiveKey = dropbox.configuredAppKey;
        if (effectiveKey.isEmpty) {
          throw ArgumentError(
            'Cloud connection is not configured correctly. Please contact the app administrator.',
          );
        }

        _pkceSession ??= dropbox.createPkceSession(
          appKey: effectiveKey,
        );

        await dropbox.completePkceAuth(
          session: _pkceSession!,
          code: code,
        );
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connected to Dropbox successfully!'),
              duration: Duration(seconds: 2),
            ),
          );
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop(true);
          }
        }
      } catch (e) {
        if (mounted) {
          String msg = 'Dropbox authorization failed: $e';
          if (e.toString().contains('invalid_grant')) {
            msg =
                'Authorization code expired or invalid. Please click "Sign in with Dropbox" to get a fresh code.';
          }
          setState(() {
            _isLoading = false;
            _errorMessage = msg;
            _successMessage = null;
          });
        }
      }
    } else {
      final token = _tokenController.text.trim();
      if (token.isEmpty) {
        setState(
          () => _errorMessage = 'Please enter your Dropbox Access Token.',
        );
        return;
      }

      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      try {
        await dropbox.connectWithAccessToken(token);
        if (mounted) {
          Navigator.of(context).pop(true);
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Dropbox authentication failed: $e';
          });
        }
      }
    }
  }

  Future<void> _connectGoogleDrive() async {
    final google = widget.provider as GoogleDriveProvider;

    // Check platform-specific required configuration automatically from application config
    if (KeyNestPlatform.isWindows || KeyNestPlatform.isLinux) {
      final desktopId =
          CloudConfigStore.instance.effectiveGoogleDesktopClientId;
      if (desktopId.isEmpty) {
        setState(() {
          _errorMessage =
              'Cloud connection is not configured correctly. Please contact the app administrator.';
          _successMessage = null;
        });
        return;
      }
      final err = CloudConfigStore.validateGoogleClientId(
        desktopId,
        required: false,
      );
      if (err != null) {
        setState(() {
          _errorMessage =
              'Cloud connection is not configured correctly. Please contact the app administrator.';
          _successMessage = null;
        });
        return;
      }
    } else if (KeyNestPlatform.isAndroid) {
      final webId = CloudConfigStore.instance.effectiveGoogleWebClientId;
      if (webId.isEmpty) {
        setState(() {
          _errorMessage =
              'Cloud connection is not configured correctly. Please contact the app administrator.';
          _successMessage = null;
        });
        return;
      }
      final err = CloudConfigStore.validateGoogleClientId(
        webId,
        required: false,
      );
      if (err != null) {
        setState(() {
          _errorMessage =
              'Cloud connection is not configured correctly. Please contact the app administrator.';
          _successMessage = null;
        });
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final success = await google.tokenSource.signIn();
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      if (success) {
        google.isAuthorized = true;
        google.onAuthChanged?.call();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connected to Google Drive successfully!'),
              duration: Duration(seconds: 2),
            ),
          );
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop(true);
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Google Sign-In was cancelled.';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        String msg = e.toString();
        if (e is GoogleDriveAuthException) {
          msg = e.message;
        } else if (msg.contains('ApiException: 10') || msg.contains(': 10:')) {
          msg =
              'Google Cloud configuration error (Developer Error 10). The Android package name (com.moshinop.keynest) and SHA-1 signing fingerprint must be added to your Google Cloud Console OAuth client.';
        } else if (msg.contains('12500')) {
          msg =
              'Google Sign-In error (12500). Please check that the OAuth consent screen is configured and test users are added in Google Cloud Console.';
        } else if (e.toString().contains('serverClientId must be provided') ||
            e.toString().contains('KEYNEST_GOOGLE_WEB_CLIENT_ID') ||
            e.toString().contains('Google Web Client ID is not configured') ||
            e.toString().contains('KEYNEST_GOOGLE_DESKTOP_CLIENT_ID') ||
            e.toString().contains(
              'Google Desktop Client ID is not configured',
            )) {
          msg =
              'Cloud connection is not configured correctly. Please contact the app administrator.';
        }
        setState(() {
          _isLoading = false;
          _errorMessage = msg;
        });
      }
    }
  }

  Future<void> _disconnectGoogleDrive() async {
    final google = widget.provider as GoogleDriveProvider;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      await google.logout();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _successMessage =
              'Google Drive account disconnected successfully. Local vaults are preserved.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to disconnect Google Drive: $e';
        });
      }
    }
  }

  Future<void> _disconnectDropbox() async {
    final dropbox = widget.provider as DropboxProvider;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      await dropbox.logout();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _successMessage = 'Dropbox account disconnected successfully.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to disconnect Dropbox: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final provider = widget.provider;
    final isWebDav = provider is WebDavProvider;
    final isDropbox = provider is DropboxProvider;
    final isGoogle = provider is GoogleDriveProvider;
    final isConnected = provider.isAuthenticated;

    final Color iconColor;
    final String title;
    final String subtitle;

    if (isWebDav) {
      iconColor = const Color(0xFF0082C9);
      title = 'Connect WebDAV / Nextcloud';
      subtitle =
          'Synchronize your vault with Nextcloud, ownCloud, or custom WebDAV';
    } else if (isDropbox) {
      iconColor = const Color(0xFF0061FF);
      title = 'Connect Dropbox';
      subtitle = 'Synchronize your password vault with your Dropbox account';
    } else if (isGoogle) {
      iconColor = const Color(0xFF1EA362);
      title = 'Connect Google Drive';
      subtitle = 'Store and sync password databases directly in Google Drive';
    } else {
      iconColor = isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary;
      title = 'Connect ${provider.displayName}';
      subtitle = 'Setup cloud synchronization for ${provider.displayName}';
    }

    return Dialog(
      backgroundColor: isDark
          ? KeyNestPalette.cardDark
          : KeyNestPalette.cardLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: provider.displayIcon.iconData.widget(
                      color: iconColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? KeyNestPalette.textPrimaryDark
                                : KeyNestPalette.textPrimaryLight,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            height: 1.3,
                            color: isDark
                                ? KeyNestPalette.textSecondaryDark
                                : KeyNestPalette.textSecondaryLight,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Scrollable content body
              Flexible(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Error banner if any
                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: KeyNestPalette.error.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: KeyNestPalette.error.withValues(
                                alpha: 0.3,
                              ),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: KeyNestPalette.error,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    color: KeyNestPalette.error,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],

                      // Success message if any
                      if (_successMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: KeyNestPalette.accent.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: KeyNestPalette.accent.withValues(
                                alpha: 0.3,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.check_circle_outline_rounded,
                                color: KeyNestPalette.accent,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _successMessage!,
                                  style: const TextStyle(
                                    color: KeyNestPalette.accent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],

                      if (isConnected) ...[
                        _buildConnectedView(
                          context,
                          provider,
                          isDark,
                          isGoogle,
                          isDropbox,
                        ),
                      ] else ...[
                        // WebDAV Form
                        if (isWebDav) ...[
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _buildPresetChip(
                                  'Nextcloud',
                                  'https://your-domain.com/remote.php/dav/files/user/',
                                ),
                                const SizedBox(width: 6),
                                _buildPresetChip(
                                  'ownCloud',
                                  'https://your-domain.com/remote.php/webdav/',
                                ),
                                const SizedBox(width: 6),
                                _buildPresetChip(
                                  'pCloud',
                                  'https://webdav.pcloud.com/',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _urlController,
                            keyboardType: TextInputType.url,
                            decoration: InputDecoration(
                              labelText: 'Server WebDAV URL',
                              hintText:
                                  'https://cloud.example.com/remote.php/webdav/',
                              prefixIcon: const Icon(
                                Icons.link_rounded,
                                size: 20,
                              ),
                              filled: true,
                              fillColor: isDark
                                  ? KeyNestPalette.surfaceDark
                                  : KeyNestPalette.surfaceLight,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _userController,
                            decoration: InputDecoration(
                              labelText: 'Username / Email',
                              prefixIcon: const Icon(
                                Icons.person_outline_rounded,
                                size: 20,
                              ),
                              filled: true,
                              fillColor: isDark
                                  ? KeyNestPalette.surfaceDark
                                  : KeyNestPalette.surfaceLight,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _passController,
                            obscureText: _obscurePass,
                            decoration: InputDecoration(
                              labelText: 'Password / App Password',
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                                size: 20,
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePass
                                      ? Icons.visibility_rounded
                                      : Icons.visibility_off_rounded,
                                  size: 20,
                                ),
                                onPressed: () => setState(
                                  () => _obscurePass = !_obscurePass,
                                ),
                              ),
                              filled: true,
                              fillColor: isDark
                                  ? KeyNestPalette.surfaceDark
                                  : KeyNestPalette.surfaceLight,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: _isLoading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.check_rounded, size: 18),
                              label: const Text(
                                'Connect & Verify WebDAV',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0082C9),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: _isLoading ? null : _connectWebDav,
                            ),
                          ),
                        ] else if (isDropbox) ...[
                          // Mode selector - balanced equal-height tabs with clean typography
                          Container(
                            height: 40,
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? KeyNestPalette.surfaceDark
                                  : KeyNestPalette.surfaceLight,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () =>
                                        setState(() => _dropboxAuthMode = 0),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: _dropboxAuthMode == 0
                                            ? const Color(0xFF0061FF)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(7),
                                      ),
                                      child: Text(
                                        'OAuth 2.0 (Browser)',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: _dropboxAuthMode == 0
                                              ? FontWeight.bold
                                              : FontWeight.w600,
                                          color: _dropboxAuthMode == 0
                                              ? Colors.white
                                              : (isDark
                                                    ? Colors.white70
                                                    : Colors.black87),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () =>
                                        setState(() => _dropboxAuthMode = 1),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: _dropboxAuthMode == 1
                                            ? const Color(0xFF0061FF)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(7),
                                      ),
                                      child: Text(
                                        'Access Token',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: _dropboxAuthMode == 1
                                              ? FontWeight.bold
                                              : FontWeight.w600,
                                          color: _dropboxAuthMode == 1
                                              ? Colors.white
                                              : (isDark
                                                    ? Colors.white70
                                                    : Colors.black87),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),

                          if (_dropboxAuthMode == 0) ...[
                            if (_pkceSession == null) ...[
                              if ((widget.provider as DropboxProvider)
                                  .configuredAppKey
                                  .isEmpty) ...[
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: Colors.amber.withValues(
                                        alpha: 0.3,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Icon(
                                        Icons.warning_amber_rounded,
                                        color: Colors.amber,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'Cloud connection is not configured correctly. Please contact the app administrator.',
                                          style: TextStyle(
                                            fontSize: 12,
                                            height: 1.3,
                                            color: isDark
                                                ? Colors.white70
                                                : Colors.black87,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),
                              ] else ...[
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF0061FF,
                                    ).withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: const Color(
                                        0xFF0061FF,
                                      ).withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Row(
                                        children: [
                                          Icon(
                                            Icons.shield_outlined,
                                            color: Color(0xFF0061FF),
                                            size: 20,
                                          ),
                                          SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'OAuth 2.0 PKCE Authorization',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Connect your Dropbox account securely to sync your encrypted KDBX vaults. KeyNest opens Dropbox in your browser where you sign in and grant access.',
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.4,
                                          color: isDark
                                              ? KeyNestPalette.textSecondaryDark
                                              : KeyNestPalette
                                                    .textSecondaryLight,
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          icon: _isLoading
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white,
                                                      ),
                                                )
                                              : const Icon(
                                                  Icons.open_in_browser_rounded,
                                                  size: 18,
                                                ),
                                          label: const Text(
                                            'Connect with Dropbox',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(
                                              0xFF0061FF,
                                            ),
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                          ),
                                          onPressed: _isLoading
                                              ? null
                                              : _startDropboxBrowserLogin,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),
                              ],
                            ] else ...[
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF0061FF,
                                  ).withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(
                                      0xFF0061FF,
                                    ).withValues(alpha: 0.2),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Row(
                                      children: [
                                        Icon(
                                          Icons.check_circle_outline_rounded,
                                          color: Color(0xFF0061FF),
                                          size: 18,
                                        ),
                                        SizedBox(width: 8),
                                        Text(
                                          'Dropbox Opened in Browser',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '1. In your browser, log in and tap "Allow".\n'
                                      '2. Dropbox will display an authorization code on the screen.\n'
                                      '3. Copy the code and paste it below to complete connection:',
                                      style: TextStyle(
                                        fontSize: 12,
                                        height: 1.4,
                                        color: isDark
                                            ? KeyNestPalette.textSecondaryDark
                                            : KeyNestPalette.textSecondaryLight,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 14),
                              TextField(
                                controller: _codeController,
                                autofocus: true,
                                decoration: InputDecoration(
                                  labelText: 'Dropbox Authorization Code',
                                  hintText:
                                      'Paste authorization code from Dropbox...',
                                  prefixIcon: const Icon(
                                    Icons.vpn_key_rounded,
                                    size: 20,
                                  ),
                                  suffixIcon: IconButton(
                                    tooltip: 'Paste from clipboard',
                                    icon: const Icon(
                                      Icons.paste_rounded,
                                      size: 18,
                                    ),
                                    onPressed: () async {
                                      final data = await Clipboard.getData(
                                        Clipboard.kTextPlain,
                                      );
                                      if (data?.text != null &&
                                          data!.text!.trim().isNotEmpty) {
                                        _codeController.text = data.text!
                                            .trim();
                                        setState(() {});
                                      }
                                    },
                                  ),
                                  filled: true,
                                  fillColor: isDark
                                      ? KeyNestPalette.surfaceDark
                                      : KeyNestPalette.surfaceLight,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(
                                      Icons.open_in_browser_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Reopen Browser',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    onPressed: () => DialogUtils.openUrl(
                                      _pkceSession!.authorizeUrl.toString(),
                                    ),
                                  ),
                                  TextButton(
                                    child: const Text(
                                      'Cancel / Start Over',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _pkceSession = null;
                                        _codeController.clear();
                                        _errorMessage = null;
                                      });
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  icon: _isLoading
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.check_circle_rounded,
                                          size: 18,
                                        ),
                                  label: const Text(
                                    'Complete Connection',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0061FF),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  onPressed: _isLoading
                                      ? null
                                      : _connectDropbox,
                                ),
                              ),
                            ],
                          ] else ...[
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF0061FF,
                                ).withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    color: Color(0xFF0061FF),
                                    size: 18,
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Generate an access token in your Dropbox Developer Console (App Console -> Permissions -> Generate Token).',
                                      style: TextStyle(
                                        fontSize: 12,
                                        height: 1.3,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _tokenController,
                              obscureText: _obscurePat,
                              decoration: InputDecoration(
                                labelText: 'Dropbox Access Token',
                                hintText: 'sl.u...',
                                prefixIcon: const Icon(
                                  Icons.vpn_key_rounded,
                                  size: 20,
                                ),
                                suffixIcon: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: _obscurePat
                                          ? 'Show token'
                                          : 'Hide token',
                                      icon: Icon(
                                        _obscurePat
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                        size: 18,
                                      ),
                                      onPressed: () => setState(
                                        () => _obscurePat = !_obscurePat,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Paste from clipboard',
                                      icon: const Icon(
                                        Icons.paste_rounded,
                                        size: 18,
                                      ),
                                      onPressed: () async {
                                        final data = await Clipboard.getData(
                                          Clipboard.kTextPlain,
                                        );
                                        if (data?.text != null &&
                                            data!.text!.trim().isNotEmpty) {
                                          _tokenController.text = data.text!
                                              .trim();
                                          setState(() {});
                                        }
                                      },
                                    ),
                                  ],
                                ),
                                filled: true,
                                fillColor: isDark
                                    ? KeyNestPalette.surfaceDark
                                    : KeyNestPalette.surfaceLight,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                icon: const Icon(
                                  Icons.open_in_new_rounded,
                                  size: 14,
                                ),
                                label: const Text(
                                  'Open Dropbox App Console',
                                  style: TextStyle(fontSize: 12),
                                ),
                                onPressed: () => DialogUtils.openUrl(
                                  'https://www.dropbox.com/developers/apps',
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                icon: _isLoading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.check_rounded, size: 18),
                                label: const Text(
                                  'Connect with Access Token',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF0061FF),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onPressed: _isLoading ? null : _connectDropbox,
                              ),
                            ),
                          ],
                        ] else if (isGoogle) ...[
                          // Normal user connection card
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF1EA362,
                              ).withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(
                                  0xFF1EA362,
                                ).withValues(alpha: 0.2),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Row(
                                  children: [
                                    Icon(
                                      Icons.cloud_sync_rounded,
                                      color: Color(0xFF1EA362),
                                      size: 20,
                                    ),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Google Drive Synchronization',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Connect your Google Drive account to securely store and synchronize your encrypted password vaults across devices. Tapping connect will open Google\'s official sign-in screen to grant access.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.4,
                                    color: isDark
                                        ? KeyNestPalette.textSecondaryDark
                                        : KeyNestPalette.textSecondaryLight,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    icon: _isLoading
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.login_rounded,
                                            size: 18,
                                          ),
                                    label: const Text(
                                      'Connect Google Drive',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF1EA362),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    onPressed: _isLoading
                                        ? null
                                        : _connectGoogleDrive,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Action buttons footer - aligned consistently
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isConnected)
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                        foregroundColor: isDark
                            ? const Color(0xFF00315D)
                            : Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text(
                        'Done',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    )
                  else
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                      ),
                      onPressed: _isLoading
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPresetChip(String label, String urlTemplate) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      onPressed: () {
        setState(() {
          _urlController.text = urlTemplate;
        });
      },
    );
  }

  Widget _buildConnectedView(
    BuildContext context,
    CloudStorageProvider provider,
    bool isDark,
    bool isGoogle,
    bool isDropbox,
  ) {
    String? accountEmail;
    String? accountDisplayName;
    if (isGoogle) {
      final g = provider as GoogleDriveProvider;
      accountEmail = g.connectedAccountEmail;
      accountDisplayName = g.connectedDisplayName;
    } else if (isDropbox) {
      final d = provider as DropboxProvider;
      accountEmail = d.connectedAccountEmail;
      accountDisplayName = d.connectedDisplayName;
    }

    final hasAccountInfo =
        (accountEmail != null && accountEmail.isNotEmpty) ||
        (accountDisplayName != null && accountDisplayName.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Connected Status Card
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: (isDark
                    ? KeyNestPalette.successDark
                    : KeyNestPalette.success)
                .withValues(alpha: isDark ? 0.20 : 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: (isDark
                      ? KeyNestPalette.successDark
                      : KeyNestPalette.success)
                  .withValues(alpha: isDark ? 0.4 : 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: isDark
                        ? KeyNestPalette.successDark
                        : KeyNestPalette.success,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connected to ${provider.displayName}',
                          style: TextStyle(
                            color: isDark
                                ? KeyNestPalette.successDark
                                : KeyNestPalette.success,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        if (hasAccountInfo) ...[
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (accountDisplayName != null &&
                                  accountDisplayName.isNotEmpty)
                                accountDisplayName,
                              if (accountEmail != null &&
                                  accountEmail.isNotEmpty)
                                accountEmail,
                            ].join(' • '),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.link_off_rounded, size: 14),
                    label: const Text(
                      'Disconnect',
                      style: TextStyle(fontSize: 11),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: KeyNestPalette.error,
                      side: const BorderSide(color: KeyNestPalette.error),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _isLoading
                        ? null
                        : () {
                            if (isGoogle) {
                              _disconnectGoogleDrive();
                            } else if (isDropbox) {
                              _disconnectDropbox();
                            } else {
                              provider.logout().then((_) {
                                if (mounted) {
                                  setState(() {});
                                }
                              });
                            }
                          },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 14,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isGoogle
                          ? 'Storage Location: KeyNest/ in Google Drive'
                          : (isDropbox
                                ? 'Storage Location: /KeyNest/ in Dropbox'
                                : 'Ready to synchronize vaults'),
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Quick Navigation to Cloud Management & Browsing
        const Text(
          'Vault Management',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 10),

        // Card 1: Per-vault synchronization controls
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            Navigator.of(context).push(
              KeyNestCloudManagementScreen.route(provider),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark
                  ? KeyNestPalette.surfaceDark
                  : KeyNestPalette.surfaceLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? KeyNestPalette.cardBorderDark
                    : KeyNestPalette.cardBorderLight,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: KeyNestPalette.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.sync_alt_rounded,
                    color: KeyNestPalette.accent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Manage Vault Synchronization',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Choose which vaults sync and run manual sync',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.grey,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Card 2: Browse and Import Cloud Vaults
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            Navigator.of(context).push(
              KeyNestCloudVaultBrowserScreen.route(provider),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark
                  ? KeyNestPalette.surfaceDark
                  : KeyNestPalette.surfaceLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? KeyNestPalette.cardBorderDark
                    : KeyNestPalette.cardBorderLight,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0061FF).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.cloud_download_rounded,
                    color: Color(0xFF0061FF),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Browse & Import Cloud Vaults',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'View and import KDBX files stored in your cloud',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.grey,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
