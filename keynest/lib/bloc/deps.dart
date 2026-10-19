import 'dart:async';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_bloc.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/services/keynest_dynamic_icon_service.dart';
import 'package:keynest/utils/path_utils.dart';

/// Global resources available throughout the app (using [Provider])
class Deps {
  factory Deps({required Env env}) {
    final appDataBloc = AppDataBloc(env);
    final analytics = Analytics(env: env);
    final cloudStorageBloc = CloudStorageBloc(env, PathUtils(), analytics);
    return Deps._(
      env: env,
      appDataBloc: appDataBloc,
      analytics: analytics,
      kdbxBloc: KdbxBloc(
        env: env,
        appDataBloc: appDataBloc,
        analytics: analytics,
        cloudStorageBloc: cloudStorageBloc,
      ),
      cloudStorageBloc: cloudStorageBloc,
    );
  }

  Deps._({
    required this.appDataBloc,
    required this.kdbxBloc,
    required this.env,
    required this.analytics,
    required this.cloudStorageBloc,
  }) {
    Future<void>.delayed(const Duration(milliseconds: 100)).then((value) async {
      final appData = await appDataBloc.store.load();
      KeyNestDynamicIconService.instance.networkFetchEnabled =
          appData.fetchWebsiteIcons ??
          env.featureFetchWebsiteIconEnabledByDefault;
      unawaited(KeyNestDynamicIconService.instance.initDiskCache());
      final daysSinceLaunch = appData.firstLaunchedAt!
          .difference(DateTime.now())
          .abs()
          .inDays;
      await analytics.events.trackInit(
        userType: appData.manualUserType,
        value: daysSinceLaunch,
      );
    });
  }

  final Env env;
  final AppDataBloc appDataBloc;
  final KdbxBloc kdbxBloc;
  final Analytics analytics;
  final CloudStorageBloc cloudStorageBloc;
}
