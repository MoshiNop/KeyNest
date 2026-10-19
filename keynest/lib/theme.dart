import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('theme');

class KeyNestPalette {
  // Brand Colors
  static const Color primary = KeyNestTokens.lightPrimary;
  static const Color primaryHover = Color(0xFF2B355E);
  static const Color primaryLight = KeyNestTokens.lightPrimary;
  static const Color primaryContainerLight =
      KeyNestTokens.lightPrimaryContainer;
  static const Color onPrimaryContainerLight =
      KeyNestTokens.lightOnPrimaryContainer;
  static const Color accent = KeyNestTokens.brandBlue;
  static const Color primaryAccent = KeyNestTokens.primaryAccent;
  static const Color lightIcon = KeyNestTokens.lightIcon;

  // Backgrounds & Surfaces (Soft Light Scheme)
  static const Color bgLight = KeyNestTokens.lightBackground;
  static const Color surfaceLight = KeyNestTokens.lightSurface;
  static const Color surfaceContainerLight = KeyNestTokens.lightSurfaceVariant;
  static const Color cardLight = KeyNestTokens.lightSurface;
  static const Color cardBorderLight = KeyNestTokens.entryBorderLight;
  static const Color entryBorderLight = KeyNestTokens.entryBorderLight;
  static const Color dividerLight = KeyNestTokens.entryBorderLight;

  // Dark Mode (Slate Dark Scheme)
  static const Color bgDark = KeyNestTokens.darkBackground;
  static const Color surfaceDark = KeyNestTokens.darkSurface;
  static const Color surfaceContainerDark = KeyNestTokens.darkSurfaceVariant;
  static const Color cardDark = KeyNestTokens.darkSurface;
  static const Color cardBorderDark = KeyNestTokens.darkOutlineVariant;
  static const Color entryBorderDark = KeyNestTokens.entryBorderDark;
  static const Color primaryDark = KeyNestTokens.darkPrimary;
  static const Color primaryContainerDark = KeyNestTokens.darkPrimaryContainer;
  static const Color onPrimaryContainerDark =
      KeyNestTokens.darkOnPrimaryContainer;

  // Functional / Status Semantic Tones
  static const Color success = KeyNestTokens.lightSuccess;
  static const Color successDark = KeyNestTokens.darkSuccess;
  static const Color successContainer = KeyNestTokens.lightSuccessContainer;
  static const Color successContainerDark = KeyNestTokens.darkSuccessContainer;
  static const Color warning = KeyNestTokens.lightWarning;
  static const Color warningContainer = KeyNestTokens.lightWarningContainer;
  static const Color error = KeyNestTokens.lightError;
  static const Color errorContainer = KeyNestTokens.lightErrorContainer;
  static const Color info = KeyNestTokens.brandBlue;
  static const Color infoContainer = KeyNestTokens.lightPrimaryContainer;

  /// Theme-aware success foreground color providing high contrast in light and dark modes.
  static Color successColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? KeyNestTokens.darkSuccess
        : KeyNestTokens.lightSuccess;
  }

  static Color successColorFor(bool isDark) {
    return isDark ? KeyNestTokens.darkSuccess : KeyNestTokens.lightSuccess;
  }

  // Text
  static const Color textPrimaryLight = KeyNestTokens.lightOnBackground;
  static const Color textSecondaryLight = KeyNestTokens.lightOnSurfaceVariant;
  static const Color textTertiaryLight = KeyNestTokens.lightOutline;

  static const Color textPrimaryDark = KeyNestTokens.darkOnBackground;
  static const Color textSecondaryDark = KeyNestTokens.darkOnSurfaceVariant;
  static const Color textTertiaryDark = KeyNestTokens.darkOutline;
}

class KeyNestShapes {
  static const double radiusPill = KeyNestTokens.radiusPill;
  static const double radiusSheet = KeyNestTokens.radiusSheet;
  static const double radiusDialog = KeyNestTokens.radiusDialog;
  static const double radiusCard = KeyNestTokens.radiusCard;
  static const double radiusCompact = KeyNestTokens.radiusCompact;
  static const double radiusSection = KeyNestTokens.radiusSection;
  static const double radiusInput = KeyNestTokens.radiusCompact;
  static const double radiusButton = KeyNestTokens.radiusCard;
  static const double radiusChip = KeyNestTokens.radiusCompact;
  static const double radiusIcon = KeyNestTokens.radiusCompact;
}

class KeyNestTheme {
  @NonNls
  static const monoFontFamily = 'JetBrainsMono';

  static const int _primaryColorValue = 0xFF4D65D9;
  static const Color primaryColor = KeyNestPalette.primary;
  static const Color linkColor = primaryColor;
  static const MaterialColor primarySwatch = MaterialColor(
    _primaryColorValue,
    <int, Color>{
      50: Color(0xFFEEF2FF),
      100: Color(0xFFDFE4FF),
      200: Color(0xFFC3CDFE),
      300: Color(0xFFA1B2FD),
      400: Color(0xFF778DF0),
      500: Color(0xFF4D65D9),
      600: Color(0xFF3E54C4),
      700: Color(0xFF3244AF),
      800: Color(0xFF263595),
      900: Color(0xFF1A267A),
    },
  );

  static const defaultFileColors = [
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    primaryColor,
    Colors.teal,
    Colors.green,
    Colors.lightGreen,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
    Colors.deepOrange,
    Colors.brown,
    Colors.grey,
    Colors.blueGrey,
    Colors.black,
  ];
  static const defaultColorOrder = [
    Colors.teal,
    Colors.orange,
    Colors.blueGrey,
    Colors.deepPurple,
  ];
}

abstract class Breakpoints {
  static const TABLET_WIDTH = 720;
}

final keyNestLightTheme = createTheme();
final keyNestDarkTheme = createDarkTheme();

ThemeData _customize(ThemeData base) {
  final pageTransitionBuilders = {...const PageTransitionsTheme().builders};
  pageTransitionBuilders[TargetPlatform.macOS] =
      const FadeUpwardsPageTransitionsBuilder();
  return base.copyWith(
    // androidOverscrollIndicator: AndroidOverscrollIndicator.stretch,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: pageTransitionBuilders,
    ),
  );
}

bool _addedInterLicense = false;

Typography _getTypography() {
  if (defaultTargetPlatform == TargetPlatform.macOS &&
      // macos 10.15 -> darwin 19.0
      // https://en.wikipedia.org/wiki/MacOS_Mojave#Release_history
      // https://en.wikipedia.org/wiki/MacOS_Catalina#Release_history
      !_isDarwinVersion(minimumMajor: 19, minimumMinor: 0)) {
    if (!_addedInterLicense) {
      LicenseRegistry.addLicense(() async* {
        final license = await rootBundle.loadString(
          nonNls('assets/fonts/Inter-LICENSE.txt'),
        );
        yield LicenseEntryWithLineBreaks([nonNls('fonts_inter')], license);
      });
      _addedInterLicense = true;
    }
    return Typography.material2018(
      platform: defaultTargetPlatform,
      black: Typography.blackCupertino.apply(fontFamily: nonNls('Inter')),
      white: Typography.whiteCupertino.apply(fontFamily: nonNls('Inter')),
    );
  } else {
    _logger.info(
      'using default theme $defaultTargetPlatform -- ${KeyNestPlatform.operatingSystemVersion}',
    );
    return Typography.material2021(platform: defaultTargetPlatform);
  }
}

final macOsVersionPattern = RegExp(r'Darwin (\d+)\.(\d+)');

bool _isDarwinVersion({required int minimumMajor, required int minimumMinor}) {
  final match = macOsVersionPattern.firstMatch(
    KeyNestPlatform.operatingSystemVersion,
  );
  if (match == null) {
    _logger.severe(
      'Unable to parse mac os version ${KeyNestPlatform.operatingSystemVersion}',
    );
    return false;
  }
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  _logger.info(
    'Parsed ${KeyNestPlatform.operatingSystemVersion} as $major.$minor',
  );
  _logger.finest(
    'Parsed ${KeyNestPlatform.operatingSystemVersion} as $major.$minor',
  );
  return major > minimumMajor ||
      (major == minimumMajor && minor >= minimumMinor);
}

ThemeData createTheme() {
  final colorScheme = ColorScheme.light(
    primary: KeyNestPalette.primary,
    onPrimary: Colors.white,
    primaryContainer: KeyNestPalette.primaryContainerLight,
    onPrimaryContainer: KeyNestPalette.onPrimaryContainerLight,
    surface: KeyNestPalette.surfaceLight,
    onSurface: KeyNestPalette.textPrimaryLight,
    outline: KeyNestPalette.cardBorderLight,
    outlineVariant: KeyNestPalette.dividerLight,
    error: KeyNestPalette.error,
    onError: Colors.white,
  );
  return _customize(
    ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      primarySwatch: KeyNestTheme.primarySwatch,
      primaryColor: KeyNestPalette.primary,
      scaffoldBackgroundColor: KeyNestPalette.bgLight,
      typography: _getTypography(),
      iconTheme: const IconThemeData(
        color: KeyNestPalette.lightIcon,
      ),
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        backgroundColor: KeyNestTokens.lightPrimaryContainer,
        labelStyle: const TextStyle(
          color: KeyNestTokens.lightOnPrimaryContainer,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusChip),
        ),
      ),
      cardTheme: CardThemeData(
        color: KeyNestPalette.surfaceLight,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
          side: const BorderSide(
            color: KeyNestPalette.cardBorderLight,
            width: 1,
          ),
        ),
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: KeyNestPalette.textPrimaryLight,
        centerTitle: false,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: KeyNestPalette.primary,
        foregroundColor: Colors.white,
        elevation: 3,
        shape: CircleBorder(),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: KeyNestPalette.surfaceLight.withValues(alpha: 0.90),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusDialog),
          side: const BorderSide(
            color: KeyNestPalette.entryBorderLight,
            width: 1,
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white.withValues(alpha: 0.88),
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
          side: const BorderSide(
            color: KeyNestPalette.entryBorderLight,
            width: 1,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: KeyNestPalette.surfaceLight.withValues(alpha: 0.90),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(KeyNestShapes.radiusSheet),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
        ),
        elevation: 4,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        showCloseIcon: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: KeyNestTokens.lightSurfaceVariant.withValues(alpha: 0.35),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        hintStyle: TextStyle(
          color: KeyNestTokens.lightOnSurface.withValues(alpha: 0.38),
          fontSize: 14.5,
          fontWeight: FontWeight.normal,
        ),
        labelStyle: TextStyle(
          color: KeyNestTokens.lightOnSurface.withValues(alpha: 0.65),
          fontSize: 14.5,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusInput),
          borderSide: const BorderSide(
            color: KeyNestPalette.cardBorderLight,
            width: 1,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusInput),
          borderSide: const BorderSide(
            color: KeyNestPalette.cardBorderLight,
            width: 1,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusInput),
          borderSide: const BorderSide(
            color: KeyNestPalette.primary,
            width: 1.5,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((states) {
          if (states.contains(WidgetState.selected)) {
            return const Icon(
              Icons.check_rounded,
              size: 14,
              color: Colors.white,
            );
          }
          return const Icon(
            Icons.close_rounded,
            size: 14,
            color: Color(0xFF73777F),
          );
        }),
        thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return const Color(0xFF73777F);
        }),
        trackColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) {
            return KeyNestPalette.primary;
          }
          return const Color(0xFFE2E6EF);
        }),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: KeyNestPalette.primary,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KeyNestShapes.radiusButton),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: KeyNestPalette.primary,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KeyNestShapes.radiusButton),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: KeyNestPalette.primary,
          side: const BorderSide(color: KeyNestPalette.primary, width: 1.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KeyNestShapes.radiusButton),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: KeyNestPalette.primary,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        checkColor: WidgetStateProperty.all(Colors.white),
        fillColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.disabled)) {
            return const Color(0xFFC3C6CF);
          }
          if (states.contains(WidgetState.selected)) {
            return KeyNestPalette.primary;
          }
          return null;
        }),
        side: const BorderSide(
          color: KeyNestPalette.cardBorderLight,
          width: 1.5,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.disabled)) {
            return const Color(0xFFC3C6CF);
          }
          if (states.contains(WidgetState.selected)) {
            return KeyNestPalette.primary;
          }
          return const Color(0xFF73777F);
        }),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: KeyNestPalette.primary,
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: KeyNestPalette.primary,
        thumbColor: KeyNestPalette.primary,
      ),
    ),
  );
}

ThemeData createDarkTheme() {
  final colorScheme = ColorScheme.dark(
    primary: KeyNestPalette.primaryDark,
    onPrimary: const Color(0xFF00315D),
    primaryContainer: KeyNestPalette.primaryContainerDark,
    onPrimaryContainer: KeyNestPalette.onPrimaryContainerDark,
    surface: KeyNestPalette.surfaceDark,
    onSurface: KeyNestPalette.textPrimaryDark,
    outline: KeyNestPalette.cardBorderDark,
    outlineVariant: KeyNestPalette.cardBorderDark,
    error: KeyNestPalette.error,
    onError: Colors.white,
  );
  return _customize(
    ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      primarySwatch: KeyNestTheme.primarySwatch,
      primaryColor: KeyNestPalette.primaryDark,
      scaffoldBackgroundColor: KeyNestPalette.bgDark,
      typography: _getTypography(),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: KeyNestPalette.primaryDark,
        selectionColor: Color(0x55A8C7FA),
        selectionHandleColor: KeyNestPalette.primaryDark,
      ),
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        backgroundColor: KeyNestTokens.darkSecondaryContainer,
        labelStyle: const TextStyle(
          color: KeyNestTokens.primaryAccent,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusChip),
        ),
      ),
      cardTheme: CardThemeData(
        color: KeyNestPalette.surfaceDark,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
          side: const BorderSide(
            color: KeyNestPalette.entryBorderDark,
            width: 1,
          ),
        ),
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: KeyNestPalette.textPrimaryDark,
        centerTitle: false,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: KeyNestPalette.primaryDark,
        foregroundColor: Color(0xFF00315D),
        elevation: 3,
        shape: CircleBorder(),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: KeyNestPalette.surfaceDark.withValues(alpha: 0.86),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusDialog),
          side: const BorderSide(
            color: KeyNestPalette.entryBorderDark,
            width: 1,
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: KeyNestPalette.surfaceDark.withValues(alpha: 0.84),
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
          side: const BorderSide(
            color: KeyNestPalette.entryBorderDark,
            width: 1,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: KeyNestPalette.surfaceDark.withValues(alpha: 0.86),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(KeyNestShapes.radiusSheet),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusCard),
        ),
        elevation: 4,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        showCloseIcon: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: KeyNestTokens.darkSurfaceVariant.withValues(alpha: 0.28),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        hintStyle: TextStyle(
          color: KeyNestTokens.darkOnSurface.withValues(alpha: 0.38),
          fontSize: 14.5,
          fontWeight: FontWeight.normal,
        ),
        labelStyle: TextStyle(
          color: KeyNestTokens.darkOnSurface.withValues(alpha: 0.65),
          fontSize: 14.5,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusInput),
          borderSide: const BorderSide(
            color: KeyNestPalette.entryBorderDark,
            width: 1,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusInput),
          borderSide: const BorderSide(
            color: KeyNestPalette.entryBorderDark,
            width: 1,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestShapes.radiusInput),
          borderSide: const BorderSide(
            color: KeyNestPalette.primaryDark,
            width: 1.5,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: KeyNestPalette.primaryDark,
          foregroundColor: const Color(0xFF00315D),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KeyNestShapes.radiusButton),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: KeyNestPalette.primaryDark,
          foregroundColor: const Color(0xFF00315D),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KeyNestShapes.radiusButton),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: KeyNestPalette.primaryDark,
          side: const BorderSide(color: KeyNestPalette.primaryDark, width: 1.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KeyNestShapes.radiusButton),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: KeyNestPalette.primaryDark,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        checkColor: WidgetStateProperty.all(const Color(0xFF00315D)),
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return const Color(0xFF2E384D);
          }
          if (states.contains(WidgetState.selected)) {
            return KeyNestPalette.primaryDark;
          }
          return null;
        }),
        side: const BorderSide(
          color: KeyNestPalette.cardBorderDark,
          width: 1.5,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return const Color(0xFF2E384D);
          }
          if (states.contains(WidgetState.selected)) {
            return KeyNestPalette.primaryDark;
          }
          return const Color(0xFF94A3B8);
        }),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: KeyNestPalette.primaryDark,
        linearTrackColor: Color(0xFF1F2636),
        circularTrackColor: Color(0xFF1F2636),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: KeyNestPalette.primaryDark,
        inactiveTrackColor: const Color(0xFF2E384D),
        thumbColor: KeyNestPalette.primaryDark,
        overlayColor: const Color(0xFFA8C7FA).withValues(alpha: 0.15),
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((states) {
          if (states.contains(WidgetState.selected)) {
            return const Icon(
              Icons.check_rounded,
              size: 14,
              color: Color(0xFF00315D),
            );
          }
          return const Icon(
            Icons.close_rounded,
            size: 14,
            color: Color(0xFF161B26),
          );
        }),
        thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) {
            return const Color(0xFF00315D);
          }
          return const Color(0xFF8D9199);
        }),
        trackColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) {
            return KeyNestPalette.primaryDark;
          }
          return const Color(0xFF242C3D);
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.transparent;
          }
          return const Color(0xFF38435C);
        }),
      ),
    ),
  );
}
