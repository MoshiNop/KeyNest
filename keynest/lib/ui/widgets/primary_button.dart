import 'package:flutter/material.dart';
import 'package:keynest/ui/design_system/design_system.dart';

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    this.child,
    this.onPressed,
    this.icon,
    this.large = true,
  });

  final Widget? child;
  final VoidCallback? onPressed;
  final Widget? icon;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final childWidget = icon == null
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: child,
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              icon!,
              const SizedBox(width: 8.0),
              ?child,
            ],
          );

    return KeyNestPressScale(
      onTap: onPressed,
      child: Theme(
        data: _createMainButtonTheme(
          theme,
          large: large,
        ),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            foregroundColor: theme.colorScheme.onPrimary,
            backgroundColor: theme.colorScheme.primary,
            elevation: 0,
            minimumSize: Size(
              0,
              large
                  ? KeyNestTokens.buttonHeightLarge
                  : KeyNestTokens.buttonHeightNormal,
            ),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 24),
          ),
          onPressed: onPressed,
          child: childWidget,
        ),
      ),
    );
  }
}

ThemeData _createMainButtonTheme(
  ThemeData themeData, {
  bool large = true,
}) => themeData.copyWith(
  //       elevatedButtonTheme: themeData.elevatedButtonTheme.style(
  //         // buttonColor: themeData.primaryColor,
  //         // textTheme: ButtonTextTheme.primary,
  // //      disabledColor: KeyNestTheme.disabledPrimaryColor,
  // //         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  // //         padding: large
  // //             ? const EdgeInsets.symmetric(
  // //                 vertical: 16,
  // //                 horizontal: 16,
  // //               )
  // //             : null,
  //       ),
  textTheme: large
      ? themeData.textTheme.apply(fontSizeFactor: 1.4)
      : themeData.textTheme,
);
