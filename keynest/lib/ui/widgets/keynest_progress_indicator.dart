import 'package:flutter/material.dart';

class KeyNestProgressIndicator extends StatelessWidget {
  const KeyNestProgressIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return const CircularProgressIndicator();
  }
}

class ProgressIndicatorForButtonBar extends StatelessWidget {
  const ProgressIndicatorForButtonBar({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(),
    );
  }
}
