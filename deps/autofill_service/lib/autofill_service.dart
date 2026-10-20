import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

final _logger = Logger('autofill_service');

enum AutofillServiceStatus {
  unsupported,
  disabled,
  enabled,
}

class AutofillPreferences {
  AutofillPreferences({required this.enableDebug});

  factory AutofillPreferences.fromJson(Map<dynamic, dynamic> json) =>
      AutofillPreferences(enableDebug: json['enableDebug'] as bool);

  final bool enableDebug;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enableDebug': enableDebug,
      };
}

class PwDataset {
  PwDataset({
    required this.label,
    required this.username,
    this.email,
    required this.password,
    this.otp,
    this.id,
  });

  final String label;
  final String username;
  final String? email;
  final String password;
  final String? otp;
  final String? id;

  Map<String, dynamic> toMap() => {
        'label': label,
        'username': username,
        if (email != null) 'email': email,
        'password': password,
        if (otp != null) 'otp': otp,
        if (id != null) 'id': id,
      };
}

class AutofillSyncEntry {
  AutofillSyncEntry({
    required this.id,
    required this.label,
    required this.username,
    this.email,
    required this.password,
    this.urls = const [],
    this.packageNames = const [],
    this.registrableDomains = const [],
    this.otp,
    this.otpSecret,
    this.otpAlgorithm,
    this.otpPeriod,
    this.otpDigits,
    this.hasTotp = false,
    this.icon,
    this.requireReprompt = false,
    this.lastUsed = 0,
  });

  final String id;
  final String label;
  final String username;
  final String? email;
  final String password;
  final List<String> urls;
  final List<String> packageNames;
  final List<String> registrableDomains;
  final String? otp;
  final String? otpSecret;
  final String? otpAlgorithm;
  final int? otpPeriod;
  final int? otpDigits;
  final bool hasTotp;
  final Uint8List? icon;
  final bool requireReprompt;
  final int lastUsed;

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'username': username,
        if (email != null) 'email': email,
        'password': password,
        'urls': urls,
        'packageNames': packageNames,
        if (registrableDomains.isNotEmpty)
          'registrableDomains': registrableDomains,
        if (otp != null) 'otp': otp,
        if (otpSecret != null) 'otpSecret': otpSecret,
        if (otpAlgorithm != null) 'otpAlgorithm': otpAlgorithm,
        if (otpPeriod != null) 'otpPeriod': otpPeriod,
        if (otpDigits != null) 'otpDigits': otpDigits,
        'hasTotp': hasTotp,
        if (icon != null) 'icon': icon,
        'requireReprompt': requireReprompt,
        'lastUsed': lastUsed,
      };
}

class PendingSaveRequest {
  PendingSaveRequest({
    required this.username,
    required this.password,
    required this.packageName,
    required this.webDomain,
    this.isPasswordChange = false,
    this.isUpdate = false,
  });

  factory PendingSaveRequest.fromMap(Map<dynamic, dynamic> map) =>
      PendingSaveRequest(
        username: (map['username'] as String?) ?? '',
        password: (map['password'] as String?) ?? '',
        packageName: (map['packageName'] as String?) ?? '',
        webDomain: (map['webDomain'] as String?) ?? '',
        isPasswordChange: (map['isPasswordChange'] == true ||
            map['isPasswordChange'] == 'true'),
        isUpdate: (map['isUpdate'] == true ||
            map['isUpdate'] == 'true'),
      );

  final String username;
  final String password;
  final String packageName;
  final String webDomain;
  final bool isPasswordChange;
  final bool isUpdate;
}

class AutofillRequestInfo {
  AutofillRequestInfo({
    required this.hasRequest,
    required this.forcePicker,
    this.selectedEntryId,
  });

  final bool hasRequest;
  final bool forcePicker;
  final String? selectedEntryId;
}

class AutofillService {
  factory AutofillService() => _instance;

  AutofillService._();

  static const MethodChannel _channel =
      MethodChannel('com.moshinop.autofill_service');

  static bool? debugOverrideIsAndroid;
  static bool get isAndroidPlatform => debugOverrideIsAndroid ?? Platform.isAndroid;

  static final _instance = AutofillService._();

  static final _autofillRequestController = StreamController<void>.broadcast();
  Stream<void> get onAutofillRequest {
    _ensureInitialized();
    return _autofillRequestController.stream;
  }

  static final _autofillCancelledController = StreamController<void>.broadcast();
  Stream<void> get onAutofillCancelled {
    _ensureInitialized();
    return _autofillCancelledController.stream;
  }

  static final _autofillDismissedController = StreamController<void>.broadcast();
  Stream<void> get onAutofillDismissed {
    _ensureInitialized();
    return _autofillDismissedController.stream;
  }

  static bool _initialized = false;
  static void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAutofillRequest') {
        _autofillRequestController.add(null);
      } else if (call.method == 'onAutofillCancelled') {
        _autofillCancelledController.add(null);
      } else if (call.method == 'onAutofillDismissed') {
        _autofillDismissedController.add(null);
      }
    });
  }

  Future<AutofillRequestInfo> getAutofillRequestInfo() async {
    if (!Platform.isAndroid) {
      return AutofillRequestInfo(hasRequest: false, forcePicker: false);
    }
    _ensureInitialized();
    final result = await _channel.invokeMapMethod<String, dynamic>('hasPendingAutofillRequest');
    if (result == null) {
      return AutofillRequestInfo(hasRequest: false, forcePicker: false);
    }
    return AutofillRequestInfo(
      hasRequest: result['hasRequest'] as bool? ?? false,
      forcePicker: result['forcePicker'] as bool? ?? false,
      selectedEntryId: result['selectedEntryId'] as String?,
    );
  }

  Future<String?> getSelectedEntryId() async {
    if (!Platform.isAndroid) {
      return null;
    }
    return await _channel.invokeMethod<String>('getSelectedEntryId');
  }

  /// Backwards-compatible check for whether there's a pending autofill request.
  Future<bool> hasPendingAutofillRequest() async {
    final info = await getAutofillRequestInfo();
    return info.hasRequest;
  }

  Future<bool> cancelAutofill() async {
    if (!Platform.isAndroid) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('cancelAutofill')) ?? false;
  }

  Future<bool> get hasAutofillServicesSupport async {
    if (!Platform.isAndroid) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('hasAutofillServicesSupport'))
        as bool;
  }

  Future<bool> get hasEnabledAutofillServices async {
    return (await _channel.invokeMethod<bool>('hasEnabledAutofillServices')) ==
        true;
  }

  /// Chromium based browsers only forward form data to the autofill framework
  /// after the user enabled "Autofill using another service" in the browser
  /// settings. Returns the state of that setting for all installed browsers
  /// which expose it (empty on other platforms and for older browsers).
  Future<List<BrowserAutofillStatus>> getBrowserAutofillStatus() async {
    if (!Platform.isAndroid) {
      return [];
    }
    final result =
        await _channel.invokeListMethod<dynamic>('getBrowserAutofillStatus');
    _logger.fine('Got browser autofill status $result');
    return result
            ?.map((dynamic e) =>
                BrowserAutofillStatus.fromJson(e as Map<dynamic, dynamic>))
            .toList() ??
        [];
  }

  /// Opens the settings of the given browser, where the user can enable
  /// "Autofill using another service".
  Future<bool> openBrowserAutofillSettings(String packageName) async {
    return (await _channel.invokeMethod<bool>(
          'openBrowserAutofillSettings',
          <String, dynamic>{'packageName': packageName},
        )) ==
        true;
  }

  Future<AutofillMetadata?> getAutofillMetadata() async {
    final result = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('getAutofillMetadata');
    _logger.fine(
        'Got result for getAutofillMetadata $result (${result.runtimeType})');
    if (result == null) {
      return null;
    }
    return AutofillMetadata.fromJson(result);
  }

  static final ValueNotifier<AutofillServiceStatus?> statusNotifier =
      ValueNotifier<AutofillServiceStatus?>(null);

  Future<AutofillServiceStatus> status() async {
    if (!isAndroidPlatform) {
      statusNotifier.value = AutofillServiceStatus.unsupported;
      return AutofillServiceStatus.unsupported;
    }
    try {
      final enabled =
          await _channel.invokeMethod<bool>('hasEnabledAutofillServices');
      final currentStatus = enabled == null
          ? AutofillServiceStatus.unsupported
          : (enabled
              ? AutofillServiceStatus.enabled
              : AutofillServiceStatus.disabled);
      statusNotifier.value = currentStatus;
      return currentStatus;
    } catch (e) {
      _logger.warning('Failed to query autofill status: $e');
      return statusNotifier.value ?? AutofillServiceStatus.unsupported;
    }
  }

  Future<bool> requestSetAutofillService() async {
    final res = (await _channel.invokeMethod<bool>('requestSetAutofillService')) == true;
    await status();
    return res;
  }

  Future<bool> resultWithDataset({
    String? id,
    String? label,
    String? username,
    String? email,
    String? password,
    String? otp,
  }) async {
    return (await _channel.invokeMethod<bool>(
        'resultWithDataset', <String, dynamic>{
      if (id != null) 'id': id,
      'label': label,
      'username': username,
      if (email != null) 'email': email,
      'password': password,
      if (otp != null) 'otp': otp,
    })) as bool;
  }

  Future<bool> resultWithDatasets(List<PwDataset> datasets) async {
    return (await _channel.invokeMethod<bool>(
      'resultWithDatasets',
      <String, dynamic>{
        'datasets': datasets.map((e) => e.toMap()).toList(),
      },
    )) as bool;
  }

  Future<PendingSaveRequest?> getPendingSaveRequest() async {
    final result = await _channel
        .invokeMapMethod<dynamic, dynamic>('getPendingSaveRequest');
    if (result == null) {
      return null;
    }
    return PendingSaveRequest.fromMap(result);
  }

  Future<bool> clearPendingSaveRequest() async {
    if (!isAndroidPlatform) {
      return true;
    }
    return (await _channel.invokeMethod<bool>('clearPendingSaveRequest')) ==
        true;
  }

  Future<Map<String, dynamic>> getDiagnostics() async {
    if (!Platform.isAndroid) {
      return {
        'platform': Platform.operatingSystem,
        'supported': false,
      };
    }
    final result =
        await _channel.invokeMapMethod<String, dynamic>('getDiagnostics');
    return result ?? {};
  }

  Future<void> disableAutofillServices() async {
    await _channel.invokeMethod('disableAutofillServices');
    await status();
  }

  Future<AutofillPreferences> getPreferences() async {
    final json =
        await _channel.invokeMapMethod<String, dynamic>('getPreferences');
    if (json == null) {
      throw StateError('Got null response from `getPreferences`.');
    }
    _logger.fine('Got preferences $json');
    return AutofillPreferences.fromJson(json);
  }

  Future<void> setPreferences(AutofillPreferences preferences) async {
    _logger.fine('set prefs to ${preferences.toJson()}');
    await _channel.invokeMethod<void>(
        'setPreferences', {'preferences': preferences.toJson()});
  }

  Future<bool> syncCredentials(
    List<AutofillSyncEntry> entries, {
    int? autoLockSeconds,
  }) async {
    if (!isAndroidPlatform) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('syncCredentials', {
          'entries': entries.map((e) => e.toMap()).toList(),
          if (autoLockSeconds != null) 'autoLockSeconds': autoLockSeconds,
        })) ==
        true;
  }

  Future<bool> setAutoLockDuration(int seconds) async {
    if (!isAndroidPlatform) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('setAutoLockDuration', {
          'seconds': seconds,
        })) ==
        true;
  }

  Future<bool> isVaultUnlocked() async {
    if (!isAndroidPlatform) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('isVaultUnlocked')) ?? false;
  }

  Future<bool> touchActive() async {
    if (!isAndroidPlatform) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('touchActive')) ?? false;
  }

  Future<DateTime?> getLastActiveTimestamp() async {
    if (!isAndroidPlatform) {
      return null;
    }
    final millis = await _channel.invokeMethod<int>('getLastActiveTimestamp');
    if (millis == null || millis <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<bool> cacheSessionTokens(Map<String, String> tokens) async {
    if (!isAndroidPlatform) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('cacheSessionTokens', {
          'tokens': tokens,
        })) ==
        true;
  }

  Future<Map<String, String>?> getSessionTokens() async {
    if (!isAndroidPlatform) {
      return null;
    }
    final res = await _channel.invokeMapMethod<String, String>('getSessionTokens');
    return res;
  }

  Future<bool> clearSessionTokens() async {
    if (!isAndroidPlatform) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('clearSessionTokens')) == true;
  }

  Future<bool> clearCredentials() async {
    if (!isAndroidPlatform) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('clearCredentials')) == true;
  }

  Future<bool> clearAllCredentials() async {
    if (!isAndroidPlatform) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('clearAllCredentials')) == true;
  }

  Future<bool> isFreshInstall() async {
    if (!isAndroidPlatform) {
      return false;
    }
    try {
      return (await _channel.invokeMethod<bool>('isFreshInstall')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> rememberPendingLogin({
    required String entryId,
    required String verifiedContext,
    required String username,
  }) async {
    if (!isAndroidPlatform) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('rememberPendingLogin', {
          'entryId': entryId,
          'verifiedContext': verifiedContext,
          'username': username,
        })) ==
        true;
  }

  Future<Map<String, dynamic>?> getPendingLogin(String currentContext) async {
    if (!Platform.isAndroid) {
      return null;
    }
    return await _channel.invokeMapMethod<String, dynamic>('getPendingLogin', {
      'currentContext': currentContext,
    });
  }

  Future<bool> clearPendingLogin() async {
    if (!Platform.isAndroid) {
      return false;
    }
    return (await _channel.invokeMethod<bool>('clearPendingLogin')) == true;
  }
}

class AutofillMetadata {
  AutofillMetadata({required this.packageNames, required this.webDomains});
  factory AutofillMetadata.fromJson(Map<dynamic, dynamic> json) =>
      AutofillMetadata(
        packageNames: (json['packageNames'] as Iterable)
            .map((dynamic e) => e as String)
            .toSet(),
        webDomains: (json['webDomains'] as Iterable)
            .map((dynamic e) =>
                AutofillWebDomain.fromJson(e as Map<dynamic, dynamic>))
            .toSet(),
      );

  final Set<String> packageNames;
  final Set<AutofillWebDomain> webDomains;

  @override
  String toString() => toJson().toString();

  Map<String, Object> toJson() => {
        'packageNames': packageNames,
        'webDomains': webDomains.map((e) => e.toJson()),
      };
}

/// State of the "Autofill using another service" setting of a chromium based
/// browser. While [thirdPartyModeEnabled] is false, the browser will not
/// forward any form data to the autofill framework.
class BrowserAutofillStatus {
  BrowserAutofillStatus({
    required this.packageName,
    required this.label,
    required this.thirdPartyModeEnabled,
  });

  factory BrowserAutofillStatus.fromJson(Map<dynamic, dynamic> json) =>
      BrowserAutofillStatus(
        packageName: json['packageName'] as String,
        label: json['label'] as String,
        thirdPartyModeEnabled: json['thirdPartyModeEnabled'] as bool,
      );

  final String packageName;

  /// Name of the browser as displayed to the user, e.g. `Chrome`.
  final String label;

  final bool thirdPartyModeEnabled;

  @override
  String toString() => toJson().toString();

  Map<String, Object> toJson() => {
        'packageName': packageName,
        'label': label,
        'thirdPartyModeEnabled': thirdPartyModeEnabled,
      };
}

class AutofillWebDomain {
  AutofillWebDomain({this.scheme, required this.domain});

  factory AutofillWebDomain.fromJson(Map<dynamic, dynamic> json) =>
      AutofillWebDomain(
        scheme: json['scheme'] as String?,
        domain: json['domain'] as String,
      );

  final String? scheme;
  final String domain;

  @override
  String toString() => toJson().toString();

  Map<String, Object?> toJson() => {
        'scheme': scheme,
        'domain': domain,
      };
}
