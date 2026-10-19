import 'package:flutter/widgets.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';

abstract interface class CloudStorageCustomLoginButtonAdapter
    implements CloudStorageProvider {
  Widget getCustomLoginWidget({
    required VoidCallback onSuccess,
    required Widget defaultWidget,
  });
}
