import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:logging/logging.dart';
import 'package:mobile_scanner/mobile_scanner.dart' as scanner;
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';
import 'package:url_launcher/url_launcher.dart';

final _logger = Logger('barcodescan_screen');
const MethodChannel _miscChannel = MethodChannel('app.keynest/misc');

class BarcodeScanHelper {
  static Future<ScanResult> scanBarcode(
    BuildContext context, {
    String? titleText,
    List<BarcodeFormat>? formats,
    String? Function(String rawText)? validator,
  }) async {
    final ret = await Navigator.of(context).push(
      BarcodeScanScreen.route(
        titleText: titleText ?? nonNls('Scan Barcode'),
        formats: formats ?? BarcodeFormat.any,
        validator: validator,
      ),
    );
    return ret ?? ScanResultInvalid();
  }

  static final _barcodeMapping = Map.fromEntries(
    scanner.BarcodeFormat.values
        .map((e) => _toBarcodeFormat(e).let((f) => MapEntry(f, e)))
        .whereNotNull(),
  );

  static BarcodeFormat _toBarcodeFormat(scanner.BarcodeFormat format) =>
      switch (format) {
        scanner.BarcodeFormat.qrCode => BarcodeFormat.qrCode,
        scanner.BarcodeFormat.aztec => BarcodeFormat.aztec,
        scanner.BarcodeFormat.code39 => BarcodeFormat.code39,
        scanner.BarcodeFormat.code93 => BarcodeFormat.code93,
        scanner.BarcodeFormat.ean8 => BarcodeFormat.ean8,
        scanner.BarcodeFormat.ean13 => BarcodeFormat.ean13,
        scanner.BarcodeFormat.code128 => BarcodeFormat.code128,
        scanner.BarcodeFormat.dataMatrix => BarcodeFormat.dataMatrix,
        // ignore: deprecated_member_use
        scanner.BarcodeFormat.itf => BarcodeFormat.itf,
        scanner.BarcodeFormat.itf14 => BarcodeFormat.itf,
        scanner.BarcodeFormat.upcE => BarcodeFormat.upce,
        scanner.BarcodeFormat.upcA => .upca,
        scanner.BarcodeFormat.pdf417 => BarcodeFormat.pdf417,
        // TODO: Handle this case.
        scanner.BarcodeFormat.unknown || .all || .codabar => .unknown,
        scanner.BarcodeFormat.itf2of5 => .unknown,
        scanner.BarcodeFormat.itf2of5WithChecksum => .unknown,
      };
}

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({
    super.key,
    required this.titleText,
    required this.formats,
    this.validator,
  });

  final String titleText;
  final List<BarcodeFormat> formats;
  final String? Function(String rawText)? validator;

  static Route<ScanResult> route({
    required String titleText,
    List<BarcodeFormat> formats = BarcodeFormat.any,
    String? Function(String rawText)? validator,
  }) => MaterialPageRoute(
    builder: (context) => BarcodeScanScreen(
      titleText: titleText,
      formats: formats,
      validator: validator,
    ),
  );

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen>
    with WidgetsBindingObserver {
  late final scanner.MobileScannerController controller =
      scanner.MobileScannerController(
        formats: widget.formats
            .map((e) => BarcodeScanHelper._barcodeMapping[e])
            .nonNulls
            .toList(),
        torchEnabled: false,
        autoStart: false,
      );

  bool _isProcessing = false;
  bool _isStartingCamera = false;
  bool _isPermissionDenied = false;
  bool _hasCameraError = false;
  bool _openedSettings = false;
  String? _errorMessage;
  String? _validationError;
  Timer? _validationErrorTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _startScanner();
      }
    });
  }

  Future<void> _startScanner({bool isRetry = false}) async {
    if (!mounted || _isProcessing) {
      return;
    }
    if (_isStartingCamera || controller.value.isRunning) {
      return;
    }
    if (_isPermissionDenied && !isRetry) {
      return;
    }

    setState(() {
      _isStartingCamera = true;
      if (isRetry) {
        _isPermissionDenied = false;
        _hasCameraError = false;
        _errorMessage = null;
      }
    });

    try {
      await controller.start();
      if (mounted) {
        setState(() {
          _isPermissionDenied = false;
          _hasCameraError = false;
          _errorMessage = null;
        });
      }
    } on scanner.MobileScannerException catch (e) {
      _logger.warning(
        'MobileScannerException starting camera: ${e.errorCode}',
        e,
      );
      try {
        await controller.stop();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _isPermissionDenied =
              (e.errorCode == scanner.MobileScannerErrorCode.permissionDenied);
          _hasCameraError = true;
          _errorMessage = e.errorCode.name;
        });
      }
    } catch (e, stack) {
      _logger.warning('Failed to start camera', e, stack);
      try {
        await controller.stop();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _hasCameraError = true;
          _errorMessage = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isStartingCamera = false;
        });
      } else {
        _isStartingCamera = false;
      }
    }
  }

  Future<void> _stopScanner() async {
    if (controller.value.isRunning) {
      try {
        await controller.stop();
      } catch (e) {
        _logger.warning('Failed to stop camera', e);
      }
    }
  }

  Future<bool> _openAppSettings() async {
    // 1. Try native platform channel first (works reliably on Android via MainActivity)
    try {
      final opened = await _miscChannel.invokeMethod<bool>('openAppSettings');
      if (opened == true) {
        return true;
      }
    } catch (e) {
      _logger.finer('Native openAppSettings channel not handled: $e');
    }

    // 2. Try URL schemes for iOS / other platforms
    final schemes = ['app-settings:', 'package:com.moshinop.keynest'];
    for (final scheme in schemes) {
      try {
        final uri = Uri.parse(scheme);
        if (await canLaunchUrl(uri)) {
          final success = await launchUrl(uri);
          if (success) {
            return true;
          }
        }
      } catch (_) {}
    }

    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) {
      return;
    }

    switch (state) {
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        return;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        _stopScanner();
        break;
      case AppLifecycleState.resumed:
        if (_openedSettings) {
          _openedSettings = false;
          _startScanner(isRetry: true);
        } else if (!_isPermissionDenied &&
            !_hasCameraError &&
            !controller.value.isRunning &&
            !_isStartingCamera) {
          _startScanner();
        }
        break;
    }
  }

  void _handleBarcodeDetected(scanner.BarcodeCapture barcodes) {
    _logger.fine('detected bar code. ${barcodes.barcodes.length}');
    if (_isProcessing || barcodes.barcodes.isEmpty) {
      return;
    }

    final barcode = barcodes.barcodes.first;
    final rawText = (barcode.rawValue != null && barcode.rawValue!.isNotEmpty)
        ? barcode.rawValue!
        : (barcode.displayValue ?? CharConstants.empty);

    if (widget.validator != null) {
      final validationError = widget.validator!(rawText);
      if (validationError != null) {
        // Keep camera preview active! Do NOT close or exit.
        setState(() {
          _validationError = validationError;
        });
        _validationErrorTimer?.cancel();
        _validationErrorTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() {
              _validationError = null;
            });
          }
        });
        return;
      }
    }

    _isProcessing = true;
    unawaited(controller.stop());
    final scanResult = ScanResultValid(
      barcode: (
        isValid: true,
        format: BarcodeScanHelper._toBarcodeFormat(barcode.format),
        text: rawText,
      ),
    );
    Navigator.of(context).pop(scanResult);
  }

  Widget _buildPermissionOrErrorBody(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    final isPermissionDenied = _isPermissionDenied;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Card(
          color: isDark ? const Color(0xFF1E212B) : Colors.white,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: isPermissionDenied
                  ? (isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary)
                        .withValues(alpha: 0.5)
                  : Colors.grey.withValues(alpha: 0.3),
              width: 1.5,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color:
                        (isPermissionDenied
                                ? (isDark
                                      ? KeyNestPalette.primaryDark
                                      : KeyNestPalette.primary)
                                : Colors.grey)
                            .withValues(alpha: isDark ? 0.20 : 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isPermissionDenied
                        ? Icons.no_photography_rounded
                        : Icons.videocam_off_rounded,
                    size: 32,
                    color: isPermissionDenied
                        ? (isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary)
                        : Colors.grey,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  isPermissionDenied
                      ? 'Camera Permission Required'
                      : 'Camera Unavailable (${_errorMessage ?? "Error"})',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  isPermissionDenied
                      ? 'KeyNest needs camera access to scan QR codes. Please allow camera permissions in your device settings, or tap "Try Again".'
                      : 'Could not access device camera. You can enter the secret key or paste the QR code URI manually.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isDark
                        ? KeyNestPalette.textSecondaryDark
                        : KeyNestPalette.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Enter Manually'),
                    ),
                    if (isPermissionDenied) ...[
                      ElevatedButton.icon(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final opened = await _openAppSettings();
                          if (opened) {
                            _openedSettings = true;
                          } else {
                            if (!mounted) {
                              return;
                            }
                            messenger
                              ..clearSnackBars()
                              ..showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Could not open settings automatically. Please enable camera permission in device Settings.',
                                  ),
                                  duration: Duration(milliseconds: 3000),
                                ),
                              );
                          }
                        },
                        icon: const Icon(Icons.settings_rounded, size: 18),
                        label: const Text('Open Settings'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isDark
                              ? KeyNestPalette.primaryDark
                              : KeyNestPalette.primary,
                          foregroundColor: isDark
                              ? const Color(0xFF00315D)
                              : Colors.white,
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isStartingCamera
                            ? null
                            : () => _startScanner(isRetry: true),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Try Again'),
                      ),
                    ] else ...[
                      OutlinedButton.icon(
                        onPressed: _isStartingCamera
                            ? null
                            : () => _startScanner(isRetry: true),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Try Again'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isCameraRunning = controller.value.isRunning;
    final showScanner = !_isPermissionDenied && !_hasCameraError;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.titleText),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on_rounded),
            tooltip: 'Toggle Flashlight',
            onPressed: isCameraRunning ? () => controller.toggleTorch() : null,
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch_rounded),
            tooltip: 'Switch Camera',
            onPressed: isCameraRunning ? () => controller.switchCamera() : null,
          ),
        ],
      ),
      body: showScanner
          ? Stack(
              fit: StackFit.expand,
              children: [
                scanner.MobileScanner(
                  controller: controller,
                  errorBuilder: (context, error) {
                    final isPermissionDenied =
                        error.errorCode ==
                        scanner.MobileScannerErrorCode.permissionDenied;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        unawaited(_stopScanner());
                        setState(() {
                          _isPermissionDenied = isPermissionDenied;
                          _hasCameraError = true;
                          _errorMessage = error.errorCode.name;
                        });
                      }
                    });
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  },
                  onDetect: _handleBarcodeDetected,
                  onDetectError: (error, stackTrace) {
                    _logger.severe(
                      'Error while detecting barcodes.',
                      error,
                      stackTrace,
                    );
                  },
                ),

                if (_isStartingCamera && !isCameraRunning)
                  Container(
                    color: Colors.black,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: isDark
                            ? KeyNestPalette.primaryDark
                            : KeyNestPalette.primary,
                      ),
                    ),
                  ),

                // Viewfinder Frame and Guide Text - ONLY show when camera has no error and permission is not denied
                IgnorePointer(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 260,
                          height: 260,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: _validationError != null
                                  ? KeyNestPalette.error
                                  : (isDark
                                        ? KeyNestPalette.primaryDark
                                        : KeyNestPalette.primary),
                              width: 3,
                            ),
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'Align QR code within the frame',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Non-closing validation warning banner
                if (_validationError != null)
                  Positioned(
                    bottom: 40,
                    left: 24,
                    right: 24,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: KeyNestPalette.error.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 8,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _validationError!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            )
          : _buildPermissionOrErrorBody(context, isDark),
    );
  }

  @override
  void dispose() {
    _validationErrorTimer?.cancel();
    // Stop listening to lifecycle changes.
    WidgetsBinding.instance.removeObserver(this);
    // Dispose the widget itself.
    super.dispose();
    // Finally, dispose of the controller.
    controller.dispose();
  }
}

enum BarcodeFormat {
  unknown(),
  aztec(),
  codabar(),
  code39(),
  code93(),
  code128(),
  dataBar(),
  dataBarExpanded(),
  dataMatrix(),
  ean8(),
  ean13(),
  itf(),
  maxiCode(),
  pdf417(),
  qrCode(),
  upca(),
  upce(),
  microQRCode();

  const BarcodeFormat();

  static const any = BarcodeFormat.values;
}

sealed class ScanResult {}

class ScanResultInvalid extends ScanResult {}

class ScanResultValid extends ScanResult {
  ScanResultValid({required this.barcode});

  final ScanResultBarcode barcode;
}

typedef ScanResultBarcode = ({bool isValid, String text, BarcodeFormat format});
