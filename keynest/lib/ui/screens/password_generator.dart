import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/ui/design_system/design_system.dart';
import 'package:keynest/ui/widgets/password_strength_display.dart';
import 'package:keynest/ui/widgets/slide_hide_widget.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/extension_methods.dart';
import 'package:keynest/utils/password_generator.dart';
import 'package:keynest/utils/platform.dart';
import 'package:provider/provider.dart';
import 'package:quiver/iterables.dart' as iterables;
import 'package:zxcvbn/zxcvbn.dart';

enum FinishButtonStyle {
  done,
  save,
}

class PasswordGeneratorScreen extends StatelessWidget {
  const PasswordGeneratorScreen({super.key, this.finishButton});

  static Route<String> route({required FinishButtonStyle finishButton}) {
    if (KeyNestPlatform.isDesktopOrWeb) {
      return KeyNestDesktopDialogRoute<String>(
        settings: const RouteSettings(name: '/passwordGenerator'),
        maxWidth: 520,
        maxHeight: 620,
        builder: (context) => PasswordGeneratorScreen(
          finishButton: finishButton,
        ),
      );
    }
    return KeyNestPushPageRoute<String>(
      settings: const RouteSettings(name: '/passwordGenerator'),
      builder: (context) => PasswordGeneratorScreen(
        finishButton: finishButton,
      ),
    );
  }

  /// Either a 'Done' for using in a form field, or 'Save as Default'
  final FinishButtonStyle? finishButton;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.generatePassword),
      ),
      body: GeneratePassword(
        doneButtonLabel: finishButton == FinishButtonStyle.done
            ? loc.doneButtonLabel
            : loc.useAsDefault,
        doneButtonOnPressed: (password) => Navigator.of(context).pop(password),
      ),
    );
  }
}

class GeneratePassword extends StatefulWidget {
  const GeneratePassword({
    super.key,
    this.doneButtonIcon,
    required this.doneButtonLabel,
    this.doneButtonOnPressed,
  });

  final Icon? doneButtonIcon;
  final String doneButtonLabel;
  final void Function(String? password)? doneButtonOnPressed;

  @override
  _GeneratePasswordState createState() => _GeneratePasswordState();
}

class _GeneratePasswordState extends State<GeneratePassword> {
  static final _zxcvbn = Zxcvbn();

  static Map<String, CharacterSet> characterSets(AppLocalizations loc) => {
    loc.characterSetLowerCase: CharacterSet.alphabetAsciiLowerCase,
    loc.characterSetUpperCase: CharacterSet.alphabetAsciiUpperCase,
    loc.characterSetNumeric: CharacterSet.numeric,
    loc.characterSetUmlauts: CharacterSet.alphabetUmlauts,
    loc.characterSetSpecial: CharacterSet.specialCharacters,
  };

  late Map<String, CharacterSet> _characterSets;

  static const _defaultCharacterSets = {
    CharacterSet.alphabetAsciiLowerCase,
    CharacterSet.alphabetAsciiUpperCase,
    CharacterSet.numeric,
  };

  static const int passwordLengthMin = 5;
  static const int passwordLengthMax = 40;

  /// prevent people from crashing the app.
  static const int passwordLengthCustomMax = 10000;

  final Set<CharacterSet?> _selectedCharacterSet = Set.of(
    _defaultCharacterSets,
  );

  String? _password;
  Result? _strength;
  int? _passwordLength = 20;
  final _passwordLengthCustom = TextEditingController();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _passwordLengthCustom.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appData = Provider.of<AppData>(context);
    _passwordLength = appData.passwordGeneratorLength ?? _passwordLength;
    if (appData.passwordGeneratorCharacterSets.isNotEmpty) {
      final loaded = CharacterSet.characterSetFromIds(
        appData.passwordGeneratorCharacterSets,
      ).where((s) => s != null).toSet();
      if (loaded.isNotEmpty) {
        _selectedCharacterSet
          ..clear()
          ..addAll(loaded);
      }
    }
    _characterSets = characterSets(AppLocalizations.of(context));
    _generatePassword();
  }

  void _generatePassword() {
    if (_selectedCharacterSet.isEmpty) {
      _selectedCharacterSet.addAll(_defaultCharacterSets);
    }
    final pwd = PasswordGenerator.singleton().generatePassword(
      CharacterSetCollection(_selectedCharacterSet.toList()),
      _passwordLength ?? 20,
    );
    setState(() {
      _password = pwd;
      _strength = _zxcvbn.evaluate(pwd);
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: KeyNestSurfaceCard(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: SelectableText(
                            _password ?? CharConstants.empty,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded),
                          tooltip: loc.generatePassword,
                          onPressed: _generatePassword,
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy_rounded),
                          tooltip: loc.shortcutCopyPassword,
                          onPressed: () {
                            if (_password != null && _password!.isNotEmpty) {
                              SecurityService.copySensitive(
                                context,
                                _password!,
                                label: loc.generatorPassword,
                              );
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    PasswordStrengthDisplay(strength: _strength),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            SimpleGridWidget(
              children: _characterSets.entries.map<Widget>(
                (entry) {
                  final isSelected = _selectedCharacterSet.contains(
                    entry.value,
                  );
                  final canDisable =
                      !isSelected || _selectedCharacterSet.length > 1;
                  return OptionToggleTile(
                    label: entry.key.replaceFirst(' (', '\n('), // NON-NLS
                    value: isSelected,
                    onChanged: canDisable
                        ? (val) {
                            setState(() {
                              if (val) {
                                _selectedCharacterSet.add(entry.value);
                              } else {
                                if (_selectedCharacterSet.length > 1) {
                                  _selectedCharacterSet.remove(entry.value);
                                }
                              }
                              _generatePassword();
                            });
                          }
                        : null,
                  );
                },
              ).toList(),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                const SizedBox(width: 16),
                Text(loc.length),
                Expanded(
                  child: Slider(
                    value: min(
                      _passwordLength!.toDouble(),
                      passwordLengthMax.toDouble(),
                    ),
                    min: passwordLengthMin.toDouble(),
                    max: passwordLengthMax.toDouble(),
                    divisions: (passwordLengthMax - passwordLengthMin),
                    label: _passwordLength.toString(),
                    onChanged: (val) {
                      setState(() {
                        _passwordLength = val.round();
                        _generatePassword();
                        if (_passwordLength == passwordLengthMax &&
                            _passwordLengthCustom.text.isEmpty) {
                          _passwordLengthCustom.text = passwordLengthMax
                              .toString();
                        }
                      });
                    },
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 32),
                  child: Text(
                    _passwordLength.toString(),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
            SlideHideWidget(
              hide: _passwordLength! < passwordLengthMax.toDouble(),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.only(bottom: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: TextField(
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      labelText: loc.customLength,
                      helperText: loc.customLengthHelperText(passwordLengthMax),
                    ),
                    controller: _passwordLengthCustom,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.right,
                    onChanged: (value) {
                      int.tryParse(value)?.let((number) {
                        if (number > passwordLengthMax &&
                            number <= passwordLengthCustomMax) {
                          setState(() {
                            _passwordLength = number;
                            _generatePassword();
                          });
                        }
                      });
                    },
                  ),
                ),
              ),
            ),
            ...?(widget.doneButtonOnPressed == null
                ? null
                : [
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: KeyNestGlassButton(
                        text: widget.doneButtonLabel,
                        icon:
                            widget.doneButtonIcon ??
                            const Icon(Icons.check_circle_outline),
                        tone: KeyNestSemanticTone.primary,
                        fullWidth: true,
                        onClick: () {
                          final appDataBloc = Provider.of<AppDataBloc>(
                            context,
                            listen: false,
                          );
                          appDataBloc.update(
                            (b, appData) => b
                              ..passwordGeneratorLength = _passwordLength
                              ..passwordGeneratorCharacterSets.replace(
                                _selectedCharacterSet
                                    .where((s) => s != null)
                                    .map<String>(
                                      (set) =>
                                          CharacterSet.characterSetIdFor(set),
                                    ),
                              ),
                          );
                          widget.doneButtonOnPressed!(_password);
                        },
                      ),
                    ),
                  ]),
          ],
        ),
      ),
    );
  }
}

class SimpleGridWidget extends StatelessWidget {
  const SimpleGridWidget({
    super.key,
    this.columns = 2,
    required this.children,
  });

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: iterables
          .partition(
            children.followedBy(
              List.generate(children.length % columns, (_) => Container()),
            ),
            columns,
          )
          .map(
            (partition) => Row(
              mainAxisSize: MainAxisSize.max,
              children: partition
                  .map((child) => Expanded(child: child))
                  .toList(),
            ),
          )
          .toList(),
    );
  }
}

class OptionToggleTile extends StatelessWidget {
  const OptionToggleTile({
    super.key,
    required this.label,
    required this.value,
    this.onChanged,
  });

  final String label;
  final bool value;
  final void Function(bool value)? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return InkWell(
      onTap: enabled ? () => onChanged!(!value) : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: value,
              onChanged: enabled ? (value) => onChanged!(value!) : null,
            ),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: enabled ? null : Theme.of(context).disabledColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
