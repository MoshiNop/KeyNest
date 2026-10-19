import 'dart:async';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/foundation.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/cloud_storage/cloud_storage_helper.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_provider.dart';
import 'package:keynest/cloud_storage/google_drive/google_drive_provider.dart';
import 'package:keynest/cloud_storage/onedrive/onedrive_provider.dart';
import 'package:keynest/cloud_storage/webdav/webdav_provider.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/utils/path_util.dart';
import 'package:logging/logging.dart';

final _logger = Logger('keynest.cloud_storage_bloc');

/// Manages available cloud storages.
/// Extends ChangeNotifier so UI screens react immediately to connection/disconnection changes.
class CloudStorageBloc extends ChangeNotifier {
  CloudStorageBloc(this.env, PathUtil pathUtil, Analytics analytics)
    : _helper = CloudStorageHelper(env, pathUtil, analytics),
      availableCloudStorage = {} {
    if (env.featureCloudStorageProprietary) {
      availableCloudStorage.addAll(
        {
          DropboxProvider(
            env: env,
            helper: _helper,
            onAuthChanged: notifyListeners,
          ),
          GoogleDriveProvider(
            env: env,
            helper: _helper,
            onAuthChanged: notifyListeners,
          ),
          OneDriveProvider(env: env, helper: _helper),
        }.where((element) => element.isSupported()),
      );
    }
    if (env.featureCloudStorageWebDav) {
      availableCloudStorage.add(WebDavProvider(helper: _helper));
    }
    unawaited(restoreSavedAuth());
  }

  final Env env;
  final CloudStorageHelper _helper;
  final Set<CloudStorageProvider> availableCloudStorage;

  bool _isRestoringAuth = false;
  bool get isRestoringAuth => _isRestoringAuth;

  Future<void> restoreSavedAuth() async {
    _isRestoringAuth = true;
    for (final provider in availableCloudStorage) {
      try {
        await provider.loadSavedAuth();
      } catch (e, stack) {
        _logger.warning('Failed to restore saved auth for ${provider.id}: $e', stack);
      }
    }
    _isRestoringAuth = false;
    notifyListeners();
  }

  CloudStorageProvider? providerById(String? id) =>
      availableCloudStorage.firstWhereOrNull((p) => p.id == id);

  void notifyAuthChanged() {
    notifyListeners();
  }
}

