import 'package:flutter/material.dart';
import 'package:keynest/theme.dart';

/// Utility to perform fuzzy search matching and text highlighting
/// consistent with KeyNest's Secrets tab.
class KeyNestSearchHighlight {
  /// Splits [text] into spans where substrings matching [query] terms
  /// are highlighted with [KeyNestPalette.primary] (or [KeyNestPalette.primaryDark]).
  static InlineSpan highlight(
    String text,
    String? query, {
    required bool isDark,
    Color? highlightColor,
    TextStyle? defaultStyle,
  }) {
    if (query == null || query.trim().isEmpty) {
      return TextSpan(text: text, style: defaultStyle);
    }

    final lcText = text.toLowerCase();
    final lcFilterTerms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();

    if (lcFilterTerms.isEmpty) {
      return TextSpan(text: text, style: defaultStyle);
    }

    final regexPattern = lcFilterTerms.map((e) => RegExp.escape(e)).join('|');
    if (regexPattern.isEmpty) {
      return TextSpan(text: text, style: defaultStyle);
    }

    final filterRegexp = RegExp(regexPattern);
    var previousMatchEnd = 0;
    final spans = <TextSpan>[];
    final color =
        highlightColor ??
        (isDark ? KeyNestPalette.primaryDark : KeyNestPalette.primary);

    for (final match in filterRegexp.allMatches(lcText)) {
      if (match.start > previousMatchEnd) {
        spans.add(
          TextSpan(
            text: text.substring(previousMatchEnd, match.start),
            style: defaultStyle,
          ),
        );
      }
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: (defaultStyle ?? const TextStyle()).copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      );
      previousMatchEnd = match.end;
    }

    if (previousMatchEnd < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(previousMatchEnd),
          style: defaultStyle,
        ),
      );
    }

    return TextSpan(children: spans, style: defaultStyle);
  }

  /// Builds a [Text.rich] widget with query highlighting.
  static Widget text({
    required String text,
    required String? query,
    required bool isDark,
    TextStyle? style,
    int? maxLines,
    TextOverflow? overflow,
    TextAlign? textAlign,
    Color? highlightColor,
  }) {
    return Text.rich(
      highlight(
        text,
        query,
        isDark: isDark,
        highlightColor: highlightColor,
        defaultStyle: style,
      ),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
