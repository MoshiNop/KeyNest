import 'package:flutter/material.dart';

/// KeyNest Design Tokens defining cohesive colors, spacing, corner radii,
/// and motion physics across the application.
class KeyNestTokens {
  // Brand Colors
  static const Color brandBlue = Color(0xFF384476);
  static const Color brandTeal = Color(0xFF384476);

  // Light Theme Colors
  static const Color lightPrimary = Color(0xFF384476);
  static const Color lightOnPrimary = Color(0xFFFFFFFF);
  static const Color lightPrimaryContainer = Color(0xFFDFE1F6);
  static const Color lightOnPrimaryContainer = Color(0xFF434657);
  static const Color lightSecondary = Color(0xFF434657);
  static const Color lightOnSecondary = Color(0xFFFFFFFF);
  static const Color lightSecondaryContainer = Color(0xFFDFE1F6);
  static const Color lightOnSecondaryContainer = Color(0xFF434657);
  static const Color lightIcon = Color(0xFF384476);
  static const Color lightTertiary = Color(0xFF6D5677);
  static const Color lightOnTertiary = Color(0xFFFFFFFF);
  static const Color lightTertiaryContainer = Color(0xFFF6D9FF);
  static const Color lightOnTertiaryContainer = Color(0xFF271430);
  static const Color lightError = Color(0xFFBA1A1A);
  static const Color lightErrorContainer = Color(0xFFFFDAD6);
  static const Color lightOnError = Color(0xFFFFFFFF);
  static const Color lightOnErrorContainer = Color(0xFF410002);
  static const Color lightWarning = Color(0xFF7C5800);
  static const Color lightWarningContainer = Color(0xFFFFDEA8);
  static const Color lightOnWarningContainer = Color(0xFF271900);
  static const Color lightSuccess = Color(0xFF286C2A);
  static const Color lightSuccessContainer = Color(0xFFABF5A3);
  static const Color lightOnSuccessContainer = Color(0xFF002204);
  static const Color lightBackground = Color(0xFFFDFCFF);
  static const Color lightOnBackground = Color(0xFF1A1C1E);
  static const Color lightSurface = Color(0xFFFDFCFF);
  static const Color lightOnSurface = Color(0xFF1A1C1E);
  static const Color lightSurfaceVariant = Color(0xFFDFE2EB);
  static const Color lightOnSurfaceVariant = Color(0xFF43474E);
  static const Color lightOutline = Color(0xFF73777F);
  static const Color lightOutlineVariant = Color(0x0F000000);
  static const Color lightInverseSurface = Color(0xFF2F3033);
  static const Color lightInverseOnSurface = Color(0xFFF1F0F4);
  static const Color lightInversePrimary = Color(0xFFA8C7FA);

  // Primary Accent Color (#A8C7FA)
  static const Color primaryAccent = Color(0xFFA8C7FA);

  // Dark Theme Colors
  static const Color darkPrimary = Color(0xFFA8C7FA);
  static const Color darkOnPrimary = Color(0xFF00315D);
  static const Color darkPrimaryContainer = Color(0xFF004884);
  static const Color darkOnPrimaryContainer = Color(0xFFD4E3FF);
  static const Color darkSecondary = Color(0xFFBCC7DB);
  static const Color darkOnSecondary = Color(0xFF263141);
  static const Color darkSecondaryContainer = Color(0xFF434657);
  static const Color darkOnSecondaryContainer = Color(0xFFDFE1F6);
  static const Color darkTertiary = Color(0xFFD9BDE3);
  static const Color darkOnTertiary = Color(0xFF3D2946);
  static const Color darkTertiaryContainer = Color(0xFF543F5E);
  static const Color darkOnTertiaryContainer = Color(0xFFF6D9FF);
  static const Color darkError = Color(0xFFFFB4AB);
  static const Color darkErrorContainer = Color(0xFF93000A);
  static const Color darkOnError = Color(0xFF690005);
  static const Color darkOnErrorContainer = Color(0xFFFFDAD6);
  static const Color darkWarning = Color(0xFFF5BD48);
  static const Color darkWarningContainer = Color(0xFF5F4100);
  static const Color darkOnWarningContainer = Color(0xFFFFDEA8);
  static const Color darkSuccess = Color(0xFF90D889);
  static const Color darkSuccessContainer = Color(0xFF0D5316);
  static const Color darkOnSuccessContainer = Color(0xFFABF5A3);
  static const Color darkBackground = Color(0xFF0E121A);
  static const Color darkOnBackground = Color(0xFFE4E6EC);
  static const Color darkSurface = Color(0xFF161B26);
  static const Color darkOnSurface = Color(0xFFE4E6EC);
  static const Color darkSurfaceVariant = Color(0xFF1F2636);
  static const Color darkOnSurfaceVariant = Color(0xFF94A3B8);
  static const Color darkOutline = Color(0xFF64748B);
  static const Color darkOutlineVariant = Color(0xFF2E384D);
  static const Color darkInverseSurface = Color(0xFFE4E6EC);
  static const Color darkInverseOnSurface = Color(0xFF0E121A);
  static const Color darkInversePrimary = Color(0xFF005FAC);

  // Entry & Container Outlines
  static const Color entryBorderLight = Color(0x0F000000);
  static const Color entryBorderDark = Color(0x14FFFFFF);

  // Semantic & Convenience Color Aliases
  static const Color primary = lightPrimary;
  static const Color accent = brandBlue;
  static const Color success = lightSuccess;
  static const Color successDark = darkSuccess;
  static const Color warning = lightWarning;
  static const Color error = lightError;
  static const Color info = brandBlue;

  static Color successColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkSuccess
        : lightSuccess;
  }

  static Color successColorFor(bool isDark) {
    return isDark ? darkSuccess : lightSuccess;
  }

  static Color warningColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkWarning
        : lightWarning;
  }

  static Color warningColorFor(bool isDark) {
    return isDark ? darkWarning : lightWarning;
  }

  static const Color textPrimaryLight = lightOnBackground;
  static const Color textSecondaryLight = lightOnSurfaceVariant;
  static const Color textTertiaryLight = lightOutline;

  static const Color textPrimaryDark = darkOnBackground;
  static const Color textSecondaryDark = darkOnSurfaceVariant;
  static const Color textTertiaryDark = darkOutline;

  static const Color surfaceLight = lightSurface;
  static const Color surfaceDark = darkSurface;
  static const Color surfaceContainerLight = lightSurfaceVariant;
  static const Color surfaceContainerDark = darkSurfaceVariant;
  static const Color borderLight = entryBorderLight;
  static const Color borderDark = entryBorderDark;

  // Pure Black Theme Surfaces
  static const Color pureBlackBackground = Color(0xFF000000);
  static const Color pureBlackSurface = Color(0xFF0B0C10);
  static const Color pureBlackCard = Color(0xFF131418);

  // Corner Radii
  static const double radiusCard = 18.0;
  static const double radiusCompact = 12.0;
  static const double radiusSettings = 18.0;
  static const double radiusSection = 18.0;
  static const double radiusPill = 999.0;
  static const double radiusSheet = 24.0;
  static const double radiusDialog = 22.0;

  // Touch Targets & Component Heights
  static const double minTouchTarget = 48.0;
  static const double tallTouchTarget = 52.0;
  static const double buttonHeightNormal = 48.0;
  static const double buttonHeightLarge = 52.0;
  static const double pillHeight = 36.0;
  static const double pillHeightLarge = 40.0;
  static const double glassButtonHeight = 48.0;
  static const double dialogButtonHeight = 52.0;
  static const double iconSizeSmall = 20.0;
  static const double iconSize = 24.0;
  static const double compactCardIconSize = 36.0;
  static const double compactCardGlyphSize = 20.0;

  // Insets & Spacing
  static const double contentPaddingSmall = 8.0;
  static const double contentPadding = 16.0;
  static const double contentPaddingMedium = 24.0;
  static const double contentPaddingExpanded = 32.0;
  static const double itemSpacing = 12.0;
  static const double compactCardSpacing = 6.0;
  static const double sheetSideInset = 8.0;
  static const double contentMaxWidth = 560.0;

  // Border & Outline Constants
  static const double borderWidth = 1.0;
  static const double tintedBorderAlpha = 0.25;

  // Motion & Animation
  static const Duration durationShort = Duration(milliseconds: 180);
  static const Duration durationNormal = Duration(milliseconds: 220);
  static const Duration durationScreenEnter = Duration(milliseconds: 320);
  static const Duration durationSlideDown = Duration(milliseconds: 220);
  static const double dialogInitialScale = 0.92;
  static const double pressedScale = 0.97;
  static const double disabledAlpha = 0.38;

  // Curves matching smooth emphasized spring easing
  static const Curve fastOutSlowIn = Curves.easeInOutCubicEmphasized;
  static const Curve linearOutSlowIn = Curves.easeOutCubic;
}

/// Semantic tones for status badges, tags, and highlights.
enum KeyNestSemanticTone {
  neutral,
  primary,
  success,
  warning,
  error;

  Color container(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    switch (this) {
      case KeyNestSemanticTone.neutral:
        return isDark
            ? KeyNestTokens.darkSurfaceVariant
            : KeyNestTokens.lightSurfaceVariant;
      case KeyNestSemanticTone.primary:
        return isDark
            ? KeyNestTokens.darkPrimaryContainer
            : KeyNestTokens.lightPrimaryContainer;
      case KeyNestSemanticTone.success:
        return isDark
            ? KeyNestTokens.darkSuccessContainer
            : KeyNestTokens.lightSuccessContainer;
      case KeyNestSemanticTone.warning:
        return isDark
            ? KeyNestTokens.darkWarningContainer
            : KeyNestTokens.lightWarningContainer;
      case KeyNestSemanticTone.error:
        return isDark
            ? KeyNestTokens.darkErrorContainer
            : KeyNestTokens.lightErrorContainer;
    }
  }

  Color content(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    switch (this) {
      case KeyNestSemanticTone.neutral:
        return isDark
            ? KeyNestTokens.darkOnSurfaceVariant
            : KeyNestTokens.lightOnSurfaceVariant;
      case KeyNestSemanticTone.primary:
        return isDark
            ? KeyNestTokens.darkOnPrimaryContainer
            : KeyNestTokens.lightOnPrimaryContainer;
      case KeyNestSemanticTone.success:
        return isDark
            ? KeyNestTokens.darkOnSuccessContainer
            : KeyNestTokens.lightOnSuccessContainer;
      case KeyNestSemanticTone.warning:
        return isDark
            ? KeyNestTokens.darkOnWarningContainer
            : KeyNestTokens.lightOnWarningContainer;
      case KeyNestSemanticTone.error:
        return isDark
            ? KeyNestTokens.darkOnErrorContainer
            : KeyNestTokens.lightOnErrorContainer;
    }
  }

  Color accent(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    switch (this) {
      case KeyNestSemanticTone.neutral:
        return isDark
            ? KeyNestTokens.darkOnSurfaceVariant
            : KeyNestTokens.lightOnSurfaceVariant;
      case KeyNestSemanticTone.primary:
        return isDark ? KeyNestTokens.darkPrimary : KeyNestTokens.lightPrimary;
      case KeyNestSemanticTone.success:
        return isDark ? KeyNestTokens.darkSuccess : KeyNestTokens.lightSuccess;
      case KeyNestSemanticTone.warning:
        return isDark ? KeyNestTokens.darkWarning : KeyNestTokens.lightWarning;
      case KeyNestSemanticTone.error:
        return isDark ? KeyNestTokens.darkError : KeyNestTokens.lightError;
    }
  }
}
