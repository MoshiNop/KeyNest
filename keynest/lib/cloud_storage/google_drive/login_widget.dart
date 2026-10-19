import 'package:flutter/material.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';

class GoogleLoginWidget extends StatelessWidget {
  const GoogleLoginWidget({
    super.key,
    required this.onSuccess,
    required this.googleDriveProvider,
    required this.defaultWidget,
  });

  final GoogleDriveProvider googleDriveProvider;
  final VoidCallback onSuccess;
  final Widget defaultWidget;

  @override
  Widget build(BuildContext context) {
    return defaultWidget;
  }
}
