import 'package:built_value/built_value.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:keynest/utils/constants.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

part '_base.freezed.dart';
part '_base.g.dart';

enum EnvType { production, development }

abstract class AppInfo implements Built<AppInfo, AppInfoBuilder> {
  factory AppInfo([void Function(AppInfoBuilder b)? updates]) = _$AppInfo;
  AppInfo._();

  String get appName;
  String get version;
  int get buildNumber;
  String get packageName;

  String get versionLabel => '$version+$buildNumber'; // NON-NLS

  String get shortString => '$appName ($versionLabel)'; // NON-NLS

  String get longString => '$shortString [$packageName]'; // NON-NLS
}

@freezed
abstract class EnvSecrets with _$EnvSecrets {
  const factory EnvSecrets({
    required String? analyticsAmplitudeApiKey,
    required String? analyticsGoogleAnalyticsId,
    required ({String siteId, String url})? analyticsMatomo,
    required String? Function()? googleClientId,
    required String? googleClientSecret,
    required String? dropboxKey,
    required String? dropboxSecret,
    required String? microsoftClientId,
    required String? microsoftClientSecret,
  }) = _EnvSecrets;

  static const nullSecrets = EnvSecrets(
    analyticsAmplitudeApiKey: null,
    analyticsGoogleAnalyticsId: null,
    analyticsMatomo: null,
    googleClientId: null,
    googleClientSecret: null,
    dropboxKey: null,
    dropboxSecret: null,
    microsoftClientId: null,
    microsoftClientSecret: null,
  );
}

abstract class FeatureFlags
    implements Built<FeatureFlags, FeatureFlagsBuilder> {
  factory FeatureFlags([void Function(FeatureFlagsBuilder b)? updates]) =
      _$FeatureFlags;
  FeatureFlags._();

  bool? get keyNestCloud;
  String? get keyNestCloudUri;
}

abstract class Env {
  Env(this.type) {
    value = this;
  }

  /// app name ;) basically it's just here so I don't have to translate it.
  static const KeyNest = 'KeyNest'; // NON-NLS
  static const KeyNestCloud = 'KeyNest Cloud'; // NON-NLS
  static const KeePassExtension = 'kdbx'; // NON-NLS

  static const _keyNestCloudUrl = 'https://cloud.keynest.app'; // NON-NLS

  static Env? value;

  final EnvType type;
  EnvSecrets? get secrets;

  final overrideFlutterOnError = true;

  String get diacEndpoint => '$_keyNestCloudUrl/diac'; // NON-NLS

  bool get diacHidden => false;

  /// whether diac is disabled by default, and only enabled through opt-in.
  bool get diacDefaultDisabled => false;

  String? get oauthRedirectUri;
  bool get oauthRedirectUriSupported;

  bool get isDebug => type == EnvType.development;

  String get name => runtimeType.toString();

  String get forumUrl => UrlConstants.forumUrl;

  String forumUrlNewTopic({
    String title = CharConstants.empty,
    String body = CharConstants.empty,
    int category = 5,
    List<String> tags = const <String>[],
  }) => nonNls(
    Uri.parse('${forumUrl}new-topic')
        .replace(
          queryParameters: <String, String>{
            'title': title,
            'body': body,
            'category_id': category.toString(),
            'tags': tags.join(','),
          }..removeWhere((key, value) => value.isEmpty),
        )
        .toString(),
  );

  /// Allows having a "namespace" for different environments.
  /// e.g. for mac os to have a different configuration for
  /// debug build vs. production/app store build.
  String? get storageNamespace => storageNamespaceFromEnvironment;

  /// App group shared between the app and the credential provider extension,
  /// and the keychain access group the cached vault keys live in — an app
  /// group identifier doubles as a `kSecAttrAccessGroup`.
  ///
  /// Must match `com.apple.security.application-groups` in the entitlements of
  /// both targets. Not namespaced per environment: debug and release builds
  /// have distinct bundle ids but share this container, which is fine because
  /// only one of them is ever installed with autofill enabled.
  ///
  /// The `group.` prefix is required on iOS, where Apple adds the team id
  /// behind the scenes. **macOS differs**: a sandboxed app needs the group
  /// either prefixed with the team id, authorized by an embedded provisioning
  /// profile, or distributed through the Mac App Store. KeyNest ships both MAS
  /// and Developer ID builds, so the macOS extension (phase 5) may need
  /// `$(AppIdentifierPrefix)group.com.moshinop.keynest` here — which is the
  /// style macos/Runner already uses for `keychain-access-groups`.
  String get autofillAppGroupIdentifier => 'group.com.moshinop.keynest';

  /// allow disabling of "onboarding".
  bool get featureOnboarding => true;

  /// Support for dropbox, google drive.
  bool get featureCloudStorageProprietary => true;

  /// Automatically fetch website icons.
  /// Disabled by default to respect offline behavior and user privacy.
  bool get featureFetchWebsiteIconEnabledByDefault => false;

  /// Support for WebDAV
  bool get featureCloudStorageWebDav => true;

  @protected
  String? get storageNamespaceFromEnvironment;

  final FeatureFlags featureFlags = FeatureFlags(
    (b) => b
      ..keyNestCloud = false
      ..keyNestCloudUri = null,
  );

  Future<AppInfo> getAppInfo();
}
