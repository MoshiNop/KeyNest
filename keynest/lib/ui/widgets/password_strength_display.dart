import 'package:flutter/material.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:zxcvbn/zxcvbn.dart';

class PasswordStrengthDisplay extends ImplicitlyAnimatedWidget {
  const PasswordStrengthDisplay({super.key, this.strength})
    : super(duration: const Duration(milliseconds: 500));

  final Result? strength;

  @override
  _PasswordStrengthDisplayState createState() =>
      _PasswordStrengthDisplayState();
}

class _PasswordStrengthDisplayState
    extends AnimatedWidgetBaseState<PasswordStrengthDisplay> {
  static final _strengthColors = [
    Colors.redAccent,
    Colors.deepOrange,
    Colors.orange,
    Colors.yellow,
    Colors.lightGreenAccent,
  ];

  Tween<double?>? _scoreTween;
  ColorTween? _colorTween;
  ColorTween? _backgroundColorTween;

  @override
  void forEachTween(visitor) {
    _scoreTween =
        visitor(
              _scoreTween,
              widget.strength?.score?.let((val) => val + 1) ?? 0.0,
              (dynamic value) => Tween<double>(begin: value as double?),
            )
            as Tween<double?>?;
    _colorTween =
        visitor(
              _colorTween,
              _strengthColors[widget.strength?.score?.toInt() ?? 0],
              (dynamic value) => ColorTween(begin: value as Color?),
            )
            as ColorTween?;
    _backgroundColorTween =
        visitor(
              _backgroundColorTween,
              widget.strength == null
                  ? Colors.redAccent
                  : Colors.grey.withValues(alpha: 0.3),
              (dynamic value) => ColorTween(begin: value as Color?),
            )
            as ColorTween?;
  }

  @override
  Widget build(BuildContext context) {
    final strength = widget.strength;
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    final feedback = strength?.feedback.warning.takeUnlessBlank();
    final score = strength?.score;
    final scoreText = score != null ? loc.passwordScore(score) : '';
    final displayText = feedback != null && feedback.isNotEmpty
        ? (scoreText.isNotEmpty ? '$scoreText • $feedback' : feedback)
        : scoreText;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 6,
            value: (_scoreTween?.evaluate(animation) ?? 0.0) / 5.0,
            valueColor: AlwaysStoppedAnimation(
              _colorTween?.evaluate(animation) ?? Colors.grey,
            ),
            backgroundColor:
                _backgroundColorTween?.evaluate(animation) ??
                Colors.grey.withValues(alpha: 0.3),
          ),
        ),
        if (displayText.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            displayText,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
