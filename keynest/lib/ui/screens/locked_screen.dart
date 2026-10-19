import 'package:autofill_service/autofill_service.dart';
import 'package:flutter/material.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/autofill_resume_helper.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/screens/main_app_scaffold.dart';
import 'package:keynest/ui/screens/onboarding/onboarding.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/ui/widgets/primary_button.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

final _logger = Logger('locked_screen');

class LockedScreen extends StatefulWidget {
  const LockedScreen({super.key, this.isAutofill = false});

  final bool isAutofill;

  static MaterialPageRoute<void> route({bool isAutofill = false}) =>
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/lock'),
        builder: (context) => LockedScreen(isAutofill: isAutofill),
      );

  @override
  State<LockedScreen> createState() => _LockedScreenState();
}

class _LockedScreenState extends State<LockedScreen> {
  bool _isUnlocking = false;
  bool _hasFilled = false;
  String? _errorMessage;
  bool _supportsBiometrics = false;

  @override
  void initState() {
    super.initState();
    final kdbxBloc = context.read<KdbxBloc>();
    final appData = kdbxBloc.appDataBloc.store.cachedValue;
    if (appData != null && appData.previousFiles.isEmpty) {
      _logger.warning(
        'LockedScreen opened with no previous files. Redirecting to onboarding.',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pushReplacement(
            OnboardingScreen.route(),
          );
        }
      });
      return;
    }

    kdbxBloc.quickUnlockStorage.supportsBiometricKeyStore().then((supported) {
      if (mounted) {
        setState(() => _supportsBiometrics = supported);
      }
    });

    final hasBiometricsEnrolled = KdbxBloc.hasVaultWithBiometricsEnrolled(
      appData,
    );

    if (hasBiometricsEnrolled) {
      if (widget.isAutofill) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _attemptQuickUnlock();
          }
        });
      } else {
        // Slight delay so route transition and window focus settle completely
        // before presenting the native biometric authentication dialog
        Future.delayed(const Duration(milliseconds: 350), () {
          if (mounted) {
            _attemptQuickUnlock();
          }
        });
      }
    }
  }

  Future<void> _attemptQuickUnlock() async {
    if (_isUnlocking) {
      return;
    }
    final loc = AppLocalizations.of(context);
    final kdbxBloc = context.read<KdbxBloc>();
    final appData =
        kdbxBloc.appDataBloc.store.cachedValue ??
        await kdbxBloc.appDataBloc.store.load();
    if (appData.previousFiles.isEmpty) {
      _logger.info('No existing previous files. Redirecting to onboarding.');
      if (mounted) {
        Navigator.of(context).pushReplacement(
          OnboardingScreen.route(),
        );
      }
      return;
    }
    if (!KdbxBloc.hasVaultWithBiometricsEnrolled(appData)) {
      _logger.fine('No vaults have biometric quick unlock enrolled.');
      return;
    }
    setState(() {
      _isUnlocking = true;
      _errorMessage = null;
    });

    try {
      var isSilentValid = kdbxBloc.canSilentQuickUnlock();
      if (!isSilentValid && KeyNestPlatform.isAndroid) {
        await kdbxBloc.trySilentRestoreAndUnlock(loc);
        isSilentValid =
            kdbxBloc.canSilentQuickUnlock() ||
            kdbxBloc.openedFilesKdbx.isNotEmpty;
      }
      final opened = kdbxBloc.openedFilesKdbx.isNotEmpty
          ? kdbxBloc.openedFilesKdbx.length
          : await kdbxBloc.reopenQuickUnlock(loc, null, isSilentValid);
      _logger.info(
        'Quick unlock completed: opened=$opened, silent=$isSilentValid, hasOpenedFiles=${kdbxBloc.openedFilesKdbx.isNotEmpty}',
      );
      if ((opened > 0 || kdbxBloc.openedFilesKdbx.isNotEmpty) && mounted) {
        final isAutofillFlow =
            widget.isAutofill ||
            await AutofillService().hasPendingAutofillRequest();
        if (isAutofillFlow && mounted) {
          _hasFilled = true;
          await AutofillResumeHelper.resumeAutofill(context, kdbxBloc);
          if (mounted) {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              Navigator.of(context).pushReplacement(MainAppScaffold.route());
            }
          }
          return;
        }
        if (mounted) {
          await Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
            MainAppScaffold.route(),
            (_) => false,
          );
        }
        return;
      }
    } catch (e) {
      _logger.warning('Quick unlock failed: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Biometric authentication was cancelled or failed.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isUnlocking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final kdbxBloc = context.watch<KdbxBloc>();
    final hasQuick = kdbxBloc.hasQuickUnlockOpen() || _supportsBiometrics;

    final primaryColor = isDark
        ? KeyNestTokens.darkPrimary
        : KeyNestTokens.lightPrimary;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && widget.isAutofill && !_hasFilled) {
          AutofillService().cancelAutofill();
        }
      },
      child: Scaffold(
        backgroundColor: isDark
            ? KeyNestTokens.darkBackground
            : KeyNestTokens.lightBackground,
        appBar: AppBar(
          title: const Text(
            AppConstants.keyNest,
            style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
          ),
          centerTitle: true,
          automaticallyImplyLeading: false,
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: KeyNestTokens.contentMaxWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 16,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const SizedBox(height: 32),
                          // Hero Vault Lock Icon
                          AnimatedContainer(
                            duration: KeyNestTokens.durationNormal,
                            curve: KeyNestTokens.fastOutSlowIn,
                            width: 104,
                            height: 104,
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(
                                alpha: isDark ? 0.16 : 0.1,
                              ),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: primaryColor.withValues(
                                  alpha: isDark ? 0.35 : 0.25,
                                ),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: primaryColor.withValues(
                                    alpha: isDark ? 0.25 : 0.08,
                                  ),
                                  blurRadius: 28,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Center(
                              child: _isUnlocking
                                  ? SizedBox(
                                      width: 38,
                                      height: 38,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        valueColor: AlwaysStoppedAnimation(
                                          primaryColor,
                                        ),
                                      ),
                                    )
                                  : Icon(
                                      Icons.lock_rounded,
                                      size: 50,
                                      color: primaryColor,
                                    ),
                            ),
                          ),
                          const SizedBox(height: 28),
                          Text(
                            'Vault is Locked',
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              'Authenticate to access your encrypted credentials and items.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color:
                                    (isDark
                                            ? KeyNestTokens.darkOnSurfaceVariant
                                            : KeyNestTokens
                                                  .lightOnSurfaceVariant)
                                        .withValues(alpha: 0.85),
                                height: 1.4,
                              ),
                            ),
                          ),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 20),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (isDark
                                            ? KeyNestTokens.darkErrorContainer
                                            : KeyNestTokens.lightErrorContainer)
                                        .withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(
                                  KeyNestTokens.radiusCompact,
                                ),
                                border: Border.all(
                                  color:
                                      (isDark
                                              ? KeyNestTokens.darkError
                                              : KeyNestTokens.lightError)
                                          .withValues(alpha: 0.4),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.error_outline_rounded,
                                    size: 18,
                                    color: isDark
                                        ? KeyNestTokens.darkError
                                        : KeyNestTokens.lightError,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      _errorMessage!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: isDark
                                            ? KeyNestTokens.darkError
                                            : KeyNestTokens.lightError,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 36),
                          // Action buttons
                          if (hasQuick) ...[
                            SizedBox(
                              width: double.infinity,
                              child: PrimaryButton(
                                onPressed: _isUnlocking
                                    ? null
                                    : _attemptQuickUnlock,
                                icon: const Icon(
                                  Icons.fingerprint_rounded,
                                  size: 24,
                                ),
                                child: const Text('Unlock with Biometrics'),
                              ),
                            ),
                            const SizedBox(height: 12),
                            KeyNestPressScale(
                              onTap: _openMasterPassword,
                              child: Container(
                                width: double.infinity,
                                height: KeyNestTokens.buttonHeightNormal,
                                decoration: BoxDecoration(
                                  color:
                                      (isDark
                                              ? KeyNestTokens.darkSurfaceVariant
                                              : KeyNestTokens
                                                    .lightSurfaceVariant)
                                          .withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(
                                    KeyNestTokens.radiusCard,
                                  ),
                                  border: Border.all(
                                    color: isDark
                                        ? KeyNestTokens.darkOutline.withValues(
                                            alpha: 0.4,
                                          )
                                        : KeyNestTokens.lightOutline.withValues(
                                            alpha: 0.5,
                                          ),
                                    width: 1,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.key_rounded,
                                      size: 18,
                                      color: isDark
                                          ? KeyNestTokens.darkOnSurface
                                          : KeyNestTokens.lightOnSurface,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Enter Master Password',
                                      style: theme.textTheme.labelLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ] else ...[
                            SizedBox(
                              width: double.infinity,
                              child: PrimaryButton(
                                onPressed: _openMasterPassword,
                                icon: const Icon(Icons.lock_open_rounded),
                                child: Text(loc.unlock),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  // Bottom switch vault action pill
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                    child: Center(
                      child: KeyNestActionPillButton(
                        icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                        label: 'Switch Vault or Open File',
                        onClick: () async {
                          await kdbxBloc.closeAllFiles(clearQuickUnlock: true);
                          if (context.mounted) {
                            await SelectFileScreen.navigate(context);
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openMasterPassword() {
    final appData = context.read<AppData>();
    final cloudBloc = context.read<CloudStorageBloc>();
    if (appData.previousFiles.isNotEmpty) {
      final mostRecent = appData.previousFiles.last.toFileSource(cloudBloc);
      Navigator.of(context).push(CredentialsScreen.route(mostRecent));
    } else {
      SelectFileScreen.navigate(context, skipQuickUnlock: true);
    }
  }
}
