import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

class CommonField {
  CommonField({
    required this.key,
    required this.displayName,
    this.includeInSearch = false,
    this.protect = false,
    this.keyboardType,
    this.autocorrect = false,
    this.enableSuggestions = false,
    this.textCapitalization = TextCapitalization.none,
    this.icon = Icons.label_outline,
    this.showByDefault = true,
  });

  final KdbxKey key;
  final String displayName;
  final bool includeInSearch;
  final bool protect;
  final TextInputType? keyboardType;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextCapitalization textCapitalization;
  final IconData icon;
  final bool showByDefault;

  String? stringValue(KdbxEntry entry) => entry.getString(key)?.getText();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommonField &&
          runtimeType == other.runtimeType &&
          key == other.key;

  @override
  int get hashCode => key.hashCode;
}

class CommonFields {
  CommonFields(AppLocalizations loc)
    : fields = [
        CommonField(
          key: KdbxKeyCommon.TITLE,
          displayName: loc.fieldTitle,
          includeInSearch: true,
          icon: Icons.label,
          autocorrect: true,
          enableSuggestions: true,
          textCapitalization: TextCapitalization.sentences,
        ),
        CommonField(
          key: KdbxKeyCommon.USER_NAME,
          displayName: loc.fieldUserName,
          includeInSearch: true,
          keyboardType: TextInputType.text,
          icon: Icons.account_circle,
        ),
        CommonField(
          key: KdbxKey('Email'),
          displayName: 'Email',
          includeInSearch: true,
          keyboardType: TextInputType.emailAddress,
          icon: Icons.alternate_email_rounded,
        ),
        CommonField(
          key: KdbxKeyCommon.PASSWORD,
          displayName: loc.fieldPassword,
          protect: true,
          keyboardType: TextInputType.visiblePassword,
          icon: Icons.lock,
        ),
        CommonField(
          key: KdbxKeyCommon.URL,
          displayName: loc.fieldWebsite,
          includeInSearch: true,
          keyboardType: TextInputType.url,
          icon: Icons.link,
        ),
        CommonField(
          key: KdbxKey('Notes'),
          displayName: 'Notes',
          includeInSearch: true,
          keyboardType: TextInputType.multiline,
          icon: Icons.notes_rounded,
          autocorrect: true,
          enableSuggestions: true,
          textCapitalization: TextCapitalization.sentences,
          showByDefault: false,
        ),
        CommonField(
          key: KdbxKeyCommon.OTP,
          displayName: loc.fieldTotp,
          icon: Icons.watch_later,
          protect: true,
          showByDefault: false,
        ),
        CommonField(
          key: KdbxKey('Tags'),
          displayName: 'Tags',
          includeInSearch: true,
          icon: Icons.tag_rounded,
          autocorrect: false,
          enableSuggestions: true,
          showByDefault: false,
        ),
      ] {
    assert(fields.map((f) => f.key).toSet().length == fields.length);
  }

  static final defaultSearchFields = {
    KdbxKeyCommon.TITLE,
    KdbxKeyCommon.USER_NAME,
    KdbxKey('Email'),
    KdbxKeyCommon.PASSWORD,
    KdbxKeyCommon.URL,
    KdbxKey('Notes'),
    KdbxKey('Tags'),
  };

  CommonField get title => _fieldByKey(KdbxKeyCommon.TITLE);

  CommonField get userName => _fieldByKey(KdbxKeyCommon.USER_NAME);

  CommonField get email => _fieldByKey(KdbxKey('Email'));

  CommonField get password => _fieldByKey(KdbxKeyCommon.PASSWORD);

  CommonField get url => _fieldByKey(KdbxKeyCommon.URL);

  CommonField get notes => _fieldByKey(KdbxKey('Notes'));

  CommonField get tags => _fieldByKey(KdbxKey('Tags'));

  /// Secret for TOTP -- content is modeled after
  /// https://github.com/google/google-authenticator/blob/master/mobile/ios/README
  /// otpauth://TYPE/LABEL?PARAMETERS
  CommonField get otpAuth => _fieldByKeyString('OTPAuth');

  /// compatibility field to look OTP token for, used by TrayTOTP
  /// Contains a base32 encoded secret, parameters are stored in
  /// `TOTP Settings` [otpAuthCompat1Settings].
  CommonField otpAuthCompat1 = _internalCommonField('TOTP Seed');
  CommonField otpAuthCompat1Settings = _internalCommonField('TOTP Settings');

  /// compatibility field to look OTP token for, used by e.g. KeeWeb
  /// contains the same URL as we use (see [otpAuth])
  CommonField otpAuthCompat2 = _internalCommonField('otp');

  final List<CommonField> fields;

  bool isCommon(
    KdbxKey key,
  ) => //fields.firstWhere((f) => f.key == key, orElse: () => null) != null;
      this[key] != null;

  bool isTotp(KdbxKey key) =>
      [otpAuth, otpAuthCompat1, otpAuthCompat2].map((e) => e.key).contains(key);

  CommonField? operator [](KdbxKey key) =>
      fields.firstWhereOrNull((f) => f.key == key);

  CommonField _fieldByKeyString(@NonNls String key) =>
      _fieldByKey(KdbxKey(key));

  CommonField _fieldByKey(KdbxKey key) =>
      fields.firstWhere((f) => f.key == key);

  static CommonField _internalCommonField(@NonNls String key) =>
      CommonField(key: KdbxKey(key), displayName: key);
}
