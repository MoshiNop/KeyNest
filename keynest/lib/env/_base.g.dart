// GENERATED CODE - DO NOT MODIFY BY HAND

part of '_base.dart';

// **************************************************************************
// BuiltValueGenerator
// **************************************************************************

class _$AppInfo extends AppInfo {
  @override
  final String appName;
  @override
  final String version;
  @override
  final int buildNumber;
  @override
  final String packageName;

  factory _$AppInfo([void Function(AppInfoBuilder)? updates]) =>
      (AppInfoBuilder()..update(updates))._build();

  _$AppInfo._({
    required this.appName,
    required this.version,
    required this.buildNumber,
    required this.packageName,
  }) : super._();
  @override
  AppInfo rebuild(void Function(AppInfoBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  AppInfoBuilder toBuilder() => AppInfoBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is AppInfo &&
        appName == other.appName &&
        version == other.version &&
        buildNumber == other.buildNumber &&
        packageName == other.packageName;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, appName.hashCode);
    _$hash = $jc(_$hash, version.hashCode);
    _$hash = $jc(_$hash, buildNumber.hashCode);
    _$hash = $jc(_$hash, packageName.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'AppInfo')
          ..add('appName', appName)
          ..add('version', version)
          ..add('buildNumber', buildNumber)
          ..add('packageName', packageName))
        .toString();
  }
}

class AppInfoBuilder implements Builder<AppInfo, AppInfoBuilder> {
  _$AppInfo? _$v;

  String? _appName;
  String? get appName => _$this._appName;
  set appName(String? appName) => _$this._appName = appName;

  String? _version;
  String? get version => _$this._version;
  set version(String? version) => _$this._version = version;

  int? _buildNumber;
  int? get buildNumber => _$this._buildNumber;
  set buildNumber(int? buildNumber) => _$this._buildNumber = buildNumber;

  String? _packageName;
  String? get packageName => _$this._packageName;
  set packageName(String? packageName) => _$this._packageName = packageName;

  AppInfoBuilder();

  AppInfoBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _appName = $v.appName;
      _version = $v.version;
      _buildNumber = $v.buildNumber;
      _packageName = $v.packageName;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(AppInfo other) {
    _$v = other as _$AppInfo;
  }

  @override
  void update(void Function(AppInfoBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  AppInfo build() => _build();

  _$AppInfo _build() {
    final _$result =
        _$v ??
        _$AppInfo._(
          appName: BuiltValueNullFieldError.checkNotNull(
            appName,
            r'AppInfo',
            'appName',
          ),
          version: BuiltValueNullFieldError.checkNotNull(
            version,
            r'AppInfo',
            'version',
          ),
          buildNumber: BuiltValueNullFieldError.checkNotNull(
            buildNumber,
            r'AppInfo',
            'buildNumber',
          ),
          packageName: BuiltValueNullFieldError.checkNotNull(
            packageName,
            r'AppInfo',
            'packageName',
          ),
        );
    replace(_$result);
    return _$result;
  }
}

class _$FeatureFlags extends FeatureFlags {
  @override
  final bool? keyNestCloud;
  @override
  final String? keyNestCloudUri;

  factory _$FeatureFlags([void Function(FeatureFlagsBuilder)? updates]) =>
      (FeatureFlagsBuilder()..update(updates))._build();

  _$FeatureFlags._({this.keyNestCloud, this.keyNestCloudUri}) : super._();
  @override
  FeatureFlags rebuild(void Function(FeatureFlagsBuilder) updates) =>
      (toBuilder()..update(updates)).build();

  @override
  FeatureFlagsBuilder toBuilder() => FeatureFlagsBuilder()..replace(this);

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) return true;
    return other is FeatureFlags &&
        keyNestCloud == other.keyNestCloud &&
        keyNestCloudUri == other.keyNestCloudUri;
  }

  @override
  int get hashCode {
    var _$hash = 0;
    _$hash = $jc(_$hash, keyNestCloud.hashCode);
    _$hash = $jc(_$hash, keyNestCloudUri.hashCode);
    _$hash = $jf(_$hash);
    return _$hash;
  }

  @override
  String toString() {
    return (newBuiltValueToStringHelper(r'FeatureFlags')
          ..add('keyNestCloud', keyNestCloud)
          ..add('keyNestCloudUri', keyNestCloudUri))
        .toString();
  }
}

class FeatureFlagsBuilder
    implements Builder<FeatureFlags, FeatureFlagsBuilder> {
  _$FeatureFlags? _$v;

  bool? _keyNestCloud;
  bool? get keyNestCloud => _$this._keyNestCloud;
  set keyNestCloud(bool? keyNestCloud) => _$this._keyNestCloud = keyNestCloud;

  String? _keyNestCloudUri;
  String? get keyNestCloudUri => _$this._keyNestCloudUri;
  set keyNestCloudUri(String? keyNestCloudUri) =>
      _$this._keyNestCloudUri = keyNestCloudUri;

  FeatureFlagsBuilder();

  FeatureFlagsBuilder get _$this {
    final $v = _$v;
    if ($v != null) {
      _keyNestCloud = $v.keyNestCloud;
      _keyNestCloudUri = $v.keyNestCloudUri;
      _$v = null;
    }
    return this;
  }

  @override
  void replace(FeatureFlags other) {
    _$v = other as _$FeatureFlags;
  }

  @override
  void update(void Function(FeatureFlagsBuilder)? updates) {
    if (updates != null) updates(this);
  }

  @override
  FeatureFlags build() => _build();

  _$FeatureFlags _build() {
    final _$result =
        _$v ??
        _$FeatureFlags._(
          keyNestCloud: keyNestCloud,
          keyNestCloudUri: keyNestCloudUri,
        );
    replace(_$result);
    return _$result;
  }
}

// ignore_for_file: deprecated_member_use_from_same_package,type=lint
