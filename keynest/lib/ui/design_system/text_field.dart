import 'package:flutter/material.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';

/// Styled text field supporting labels, hints, prefixes, password reveal,
/// clear buttons, and consistent outline styling.
class KeyNestTextField extends StatefulWidget {
  KeyNestTextField({
    super.key,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.label,
    String? hintText,
    String? placeholder,
    dynamic leadingIcon,
    dynamic prefixIcon,
    this.trailingIcon,
    this.isPassword = false,
    this.showClearButton = false,
    this.enabled = true,
    this.readOnly = false,
    this.isError = false,
    this.errorText,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.focusNode,
    this.onSubmitted,
    this.autofocus = false,
  }) : hintText = hintText ?? placeholder,
       leadingIcon = leadingIcon is IconData
           ? Icon(leadingIcon)
           : (leadingIcon as Widget? ??
                 (prefixIcon is IconData
                     ? Icon(prefixIcon)
                     : prefixIcon as Widget?));

  final TextEditingController? controller;
  final String? initialValue;
  final ValueChanged<String>? onChanged;
  final String? label;
  final String? hintText;
  final Widget? leadingIcon;
  final Widget? trailingIcon;
  final bool isPassword;
  final bool showClearButton;
  final bool enabled;
  final bool readOnly;
  final bool isError;
  final String? errorText;
  final int? maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  State<KeyNestTextField> createState() => _KeyNestTextFieldState();
}

class _KeyNestTextFieldState extends State<KeyNestTextField> {
  late final TextEditingController _controller;
  late bool _obscureText;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ?? TextEditingController(text: widget.initialValue);
    _obscureText = widget.isPassword;
    _hasText = _controller.text.isNotEmpty;
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller.dispose();
    } else {
      _controller.removeListener(_onTextChanged);
    }
    super.dispose();
  }

  void _onTextChanged() {
    final hasNow = _controller.text.isNotEmpty;
    if (hasNow != _hasText) {
      setState(() {
        _hasText = hasNow;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final textColor = isDark
        ? KeyNestTokens.darkOnBackground
        : KeyNestTokens.lightOnBackground;
    final hintColor = textColor.withValues(alpha: 0.38);
    final unfocusedBorder = isDark
        ? KeyNestTokens.darkOutline.withValues(alpha: 0.25)
        : KeyNestTokens.lightOutline.withValues(alpha: 0.35);
    final focusedBorder = isDark
        ? KeyNestTokens.darkPrimary
        : KeyNestTokens.lightPrimary;

    Widget? effectiveTrailing;
    final trailingActions = <Widget>[];

    if (widget.isPassword) {
      trailingActions.add(
        IconButton(
          icon: Icon(
            _obscureText
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            size: 20.0,
            color: textColor.withValues(alpha: 0.6),
          ),
          onPressed: () {
            setState(() {
              _obscureText = !_obscureText;
            });
          },
        ),
      );
    }

    if (widget.showClearButton && _hasText && !widget.readOnly) {
      trailingActions.add(
        IconButton(
          icon: Icon(
            Icons.clear_rounded,
            size: 20.0,
            color: textColor.withValues(alpha: 0.6),
          ),
          onPressed: () {
            _controller.clear();
            widget.onChanged?.call('');
          },
        ),
      );
    }

    if (widget.trailingIcon != null) {
      trailingActions.add(widget.trailingIcon!);
    }

    if (trailingActions.isNotEmpty) {
      effectiveTrailing = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: trailingActions,
      );
    }

    return TextField(
      controller: _controller,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      enabled: widget.enabled,
      readOnly: widget.readOnly,
      obscureText: _obscureText,
      maxLines: widget.isPassword ? 1 : widget.maxLines,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      style: theme.textTheme.bodyLarge?.copyWith(
        color: textColor,
      ),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hintText,
        errorText: widget.isError ? widget.errorText : null,
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: hintColor,
          fontWeight: FontWeight.normal,
        ),
        labelStyle: theme.textTheme.bodyMedium?.copyWith(
          color: textColor.withValues(alpha: 0.65),
        ),
        prefixIcon: widget.leadingIcon != null
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: IconTheme(
                  data: IconThemeData(
                    color: textColor.withValues(alpha: 0.6),
                    size: 20.0,
                  ),
                  child: widget.leadingIcon!,
                ),
              )
            : null,
        prefixIconConstraints: const BoxConstraints(minWidth: 44.0),
        suffixIcon: effectiveTrailing != null
            ? Padding(
                padding: const EdgeInsets.only(right: 6.0),
                child: effectiveTrailing,
              )
            : null,
        suffixIconConstraints: const BoxConstraints(minWidth: 44.0),
        filled: true,
        fillColor: isDark
            ? KeyNestTokens.darkSurfaceVariant.withValues(alpha: 0.35)
            : KeyNestTokens.lightSurfaceVariant.withValues(alpha: 0.45),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16.0,
          vertical: 14.0,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusCompact),
          borderSide: BorderSide(
            color: unfocusedBorder,
            width: KeyNestTokens.borderWidth,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusCompact),
          borderSide: BorderSide(
            color: unfocusedBorder,
            width: KeyNestTokens.borderWidth,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusCompact),
          borderSide: BorderSide(color: focusedBorder, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KeyNestTokens.radiusCompact),
          borderSide: BorderSide(
            color: isDark ? KeyNestTokens.darkError : KeyNestTokens.lightError,
            width: KeyNestTokens.borderWidth,
          ),
        ),
      ),
    );
  }
}

/// Search field with standard search iconography and instant clear action.
class KeyNestSearchTextField extends StatelessWidget {
  const KeyNestSearchTextField({
    super.key,
    this.controller,
    this.onChanged,
    this.hintText = 'Search...',
    this.autofocus = false,
  });

  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final String hintText;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return KeyNestTextField(
      controller: controller,
      onChanged: onChanged,
      hintText: hintText,
      leadingIcon: const Icon(Icons.search_rounded),
      showClearButton: true,
      textInputAction: TextInputAction.search,
    );
  }
}
