// ignore_for_file: always_put_control_body_on_new_line
import 'package:collection/collection.dart';
import 'package:kdbx/kdbx.dart';

/// Predefined standard fields supported in KeyNest entries.
enum KeyNestStandardField {
  title,
  username,
  email,
  password,
  website,
  notes,
  totp,
  category,
  cardholder,
  cardNumber,
  expiry,
  cvv,
  pin,
  tags,
}

extension KeyNestStandardFieldExt on KeyNestStandardField {
  String get label {
    switch (this) {
      case KeyNestStandardField.title:
        return 'Title';
      case KeyNestStandardField.username:
        return 'Username';
      case KeyNestStandardField.email:
        return 'Email';
      case KeyNestStandardField.password:
        return 'Password';
      case KeyNestStandardField.website:
        return 'Website';
      case KeyNestStandardField.notes:
        return 'Notes';
      case KeyNestStandardField.totp:
        return 'TOTP / 2FA Secret';
      case KeyNestStandardField.category:
        return 'Folder / Category';
      case KeyNestStandardField.cardholder:
        return 'Cardholder Name';
      case KeyNestStandardField.cardNumber:
        return 'Card Number';
      case KeyNestStandardField.expiry:
        return 'Expiration Date';
      case KeyNestStandardField.cvv:
        return 'CVC / CVV';
      case KeyNestStandardField.pin:
        return 'PIN';
      case KeyNestStandardField.tags:
        return 'Tags';
    }
  }

  KdbxKey get kdbxKey {
    switch (this) {
      case KeyNestStandardField.title:
        return KdbxKeyCommon.TITLE;
      case KeyNestStandardField.username:
        return KdbxKeyCommon.USER_NAME;
      case KeyNestStandardField.email:
        return KdbxKey('Email');
      case KeyNestStandardField.password:
        return KdbxKeyCommon.PASSWORD;
      case KeyNestStandardField.website:
        return KdbxKeyCommon.URL;
      case KeyNestStandardField.notes:
        return KdbxKey('Notes');
      case KeyNestStandardField.totp:
        return KdbxKey('OTPAuth');
      case KeyNestStandardField.category:
        return KdbxKey('ItemCategory');
      case KeyNestStandardField.cardholder:
        return KdbxKey('Cardholder');
      case KeyNestStandardField.cardNumber:
        return KdbxKey('CardNumber');
      case KeyNestStandardField.expiry:
        return KdbxKey('Expiry');
      case KeyNestStandardField.cvv:
        return KdbxKey('CVV');
      case KeyNestStandardField.pin:
        return KdbxKey('PIN');
      case KeyNestStandardField.tags:
        return KdbxKey('Tags');
    }
  }

  bool get isSensitive {
    switch (this) {
      case KeyNestStandardField.password:
      case KeyNestStandardField.totp:
      case KeyNestStandardField.cvv:
      case KeyNestStandardField.pin:
        return true;
      default:
        return false;
    }
  }
}

/// Destination type for a CSV column.
enum KeyNestMappingDestinationType {
  standard,
  customField,
  skip,
}

/// Column mapping configuration for a single CSV source column.
class KeyNestColumnMapping {
  KeyNestColumnMapping({
    required this.sourceColumnIndex,
    required this.sourceColumnName,
    required this.destinationType,
    this.standardField,
    this.customFieldName,
  });

  final int sourceColumnIndex;
  final String sourceColumnName;
  KeyNestMappingDestinationType destinationType;
  KeyNestStandardField? standardField;
  String? customFieldName;

  bool isStandard(KeyNestStandardField field) =>
      destinationType == KeyNestMappingDestinationType.standard &&
      standardField == field;

  bool get isCustomField =>
      destinationType == KeyNestMappingDestinationType.customField;

  bool get isSkipped => destinationType == KeyNestMappingDestinationType.skip;

  String get effectiveDestinationLabel {
    switch (destinationType) {
      case KeyNestMappingDestinationType.standard:
        return standardField?.label ?? 'Standard Field';
      case KeyNestMappingDestinationType.customField:
        final name = customFieldName?.trim();
        return (name != null && name.isNotEmpty)
            ? 'Custom: $name'
            : 'Custom Field';
      case KeyNestMappingDestinationType.skip:
        return 'Skip (Do not import)';
    }
  }

  KeyNestColumnMapping copyWith({
    int? sourceColumnIndex,
    String? sourceColumnName,
    KeyNestMappingDestinationType? destinationType,
    KeyNestStandardField? standardField,
    String? customFieldName,
  }) {
    return KeyNestColumnMapping(
      sourceColumnIndex: sourceColumnIndex ?? this.sourceColumnIndex,
      sourceColumnName: sourceColumnName ?? this.sourceColumnName,
      destinationType: destinationType ?? this.destinationType,
      standardField: standardField ?? this.standardField,
      customFieldName: customFieldName ?? this.customFieldName,
    );
  }
}

/// Validation result for the entire set of column mappings.
class KeyNestCsvMappingValidation {
  const KeyNestCsvMappingValidation({
    required this.isValid,
    required this.errors,
    required this.warnings,
  });

  final bool isValid;
  final List<String> errors;
  final List<String> warnings;
}

/// Validation and preview data for an individual CSV data row.
class KeyNestCsvRowPreview {
  const KeyNestCsvRowPreview({
    required this.rowIndex,
    required this.isValid,
    required this.title,
    required this.mappedValues,
    this.issueReason,
  });

  final int rowIndex;
  final bool isValid;
  final String title;
  final Map<String, String> mappedValues;
  final String? issueReason;
}

/// Helpers for auto-detection, validation, and preview of CSV mappings.
class KeyNestCsvMappingHelper {
  /// Auto-detects column mappings based on known header conventions
  /// (Bitwarden, LastPass, KeePass, Generic CSV).
  static List<KeyNestColumnMapping> autoDetectMappings(List<String> headers) {
    final mappings = <KeyNestColumnMapping>[];
    final usedStandardFields = <KeyNestStandardField>{};

    for (int i = 0; i < headers.length; i++) {
      final rawHeader = headers[i].trim();
      final lower = rawHeader.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');

      KeyNestStandardField? detected;

      if (lower == 'title' || lower == 'name' || lower == 'itemname') {
        detected = KeyNestStandardField.title;
      } else if (lower == 'username' ||
          lower == 'loginusername' ||
          lower == 'user') {
        detected = KeyNestStandardField.username;
      } else if (lower == 'email' ||
          lower == 'emailaddress' ||
          lower == 'loginemail' ||
          lower == 'mail') {
        detected = KeyNestStandardField.email;
      } else if (lower == 'password' ||
          lower == 'loginpassword' ||
          lower == 'pass') {
        detected = KeyNestStandardField.password;
      } else if (lower == 'url' ||
          lower == 'loginuri' ||
          lower == 'website' ||
          lower == 'uri' ||
          lower == 'link') {
        detected = KeyNestStandardField.website;
      } else if (lower == 'notes' ||
          lower == 'extra' ||
          lower == 'comment' ||
          lower == 'comments' ||
          lower == 'description') {
        detected = KeyNestStandardField.notes;
      } else if (lower == 'totp' ||
          lower == 'logintotp' ||
          lower == 'otpauth' ||
          lower == '2fa' ||
          lower == 'otp') {
        detected = KeyNestStandardField.totp;
      } else if (lower == 'category' ||
          lower == 'folder' ||
          lower == 'grouping') {
        detected = KeyNestStandardField.category;
      } else if (lower == 'cardholder' ||
          lower == 'cardholdername' ||
          lower == 'nameoncard') {
        detected = KeyNestStandardField.cardholder;
      } else if (lower == 'cardnumber' ||
          lower == 'creditcardnumber' ||
          lower == 'number') {
        detected = KeyNestStandardField.cardNumber;
      } else if (lower == 'expiry' ||
          lower == 'expiration' ||
          lower == 'expirydate' ||
          lower == 'exp' ||
          lower == 'expires') {
        detected = KeyNestStandardField.expiry;
      } else if (lower == 'cvv' ||
          lower == 'cvc' ||
          lower == 'securitycode' ||
          lower == 'verificationcode') {
        detected = KeyNestStandardField.cvv;
      } else if (lower == 'pin') {
        detected = KeyNestStandardField.pin;
      } else if (lower == 'tags' || lower == 'tag') {
        detected = KeyNestStandardField.tags;
      }

      if (detected != null && !usedStandardFields.contains(detected)) {
        usedStandardFields.add(detected);
        mappings.add(
          KeyNestColumnMapping(
            sourceColumnIndex: i,
            sourceColumnName: rawHeader,
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: detected,
          ),
        );
      } else if (rawHeader.isNotEmpty) {
        // Unknown or duplicate header becomes a custom field preserving original name
        mappings.add(
          KeyNestColumnMapping(
            sourceColumnIndex: i,
            sourceColumnName: rawHeader,
            destinationType: KeyNestMappingDestinationType.customField,
            customFieldName: rawHeader,
          ),
        );
      } else {
        mappings.add(
          KeyNestColumnMapping(
            sourceColumnIndex: i,
            sourceColumnName: 'Column ${i + 1}',
            destinationType: KeyNestMappingDestinationType.skip,
          ),
        );
      }
    }

    return mappings;
  }

  /// Validates mapping integrity, detecting conflicts, duplicates, and missing required fields.
  static KeyNestCsvMappingValidation validateMappings(
    List<KeyNestColumnMapping> mappings,
  ) {
    final errors = <String>[];
    final warnings = <String>[];

    // 1. Check duplicate standard fields
    final standardCounts = <KeyNestStandardField, List<String>>{};
    for (final m in mappings) {
      if (m.destinationType == KeyNestMappingDestinationType.standard &&
          m.standardField != null) {
        standardCounts
            .putIfAbsent(m.standardField!, () => [])
            .add(m.sourceColumnName);
      }
    }

    for (final entry in standardCounts.entries) {
      if (entry.value.length > 1) {
        errors.add(
          "Multiple columns (${entry.value.map((s) => "'$s'").join(', ')}) are mapped to '${entry.key.label}'. Please assign each standard field to only one column.",
        );
      }
    }

    // 2. Check duplicate custom field names
    final customFieldCounts = <String, List<String>>{};
    for (final m in mappings) {
      if (m.destinationType == KeyNestMappingDestinationType.customField) {
        final name = m.customFieldName?.trim() ?? '';
        if (name.isEmpty) {
          errors.add(
            "Custom field name cannot be empty for column '${m.sourceColumnName}'.",
          );
        } else {
          customFieldCounts.putIfAbsent(name.toLowerCase(), () => []).add(name);
        }
      }
    }

    for (final entry in customFieldCounts.entries) {
      if (entry.value.length > 1) {
        errors.add(
          "Duplicate custom field name '${entry.value.first}'. Please give each custom field a distinct name to avoid overwriting data.",
        );
      }
    }

    // 3. Enforce mandatory Title
    final hasTitle = mappings.any(
      (m) =>
          m.destinationType == KeyNestMappingDestinationType.standard &&
          m.standardField == KeyNestStandardField.title,
    );
    if (!hasTitle) {
      errors.add("Please map at least one column to 'Title'.");
    }

    // 4. Advisory warning for identity fields (Username / Email)
    final hasIdentity = mappings.any(
      (m) =>
          m.destinationType == KeyNestMappingDestinationType.standard &&
          (m.standardField == KeyNestStandardField.username ||
              m.standardField == KeyNestStandardField.email),
    );
    if (!hasIdentity) {
      warnings.add(
        'No column is mapped to Username or Email. At least one of Username or Email is recommended for login entries.',
      );
    }

    return KeyNestCsvMappingValidation(
      isValid: errors.isEmpty,
      errors: errors,
      warnings: warnings,
    );
  }

  /// Evaluates rows and builds preview data reflecting the current mappings.
  static List<KeyNestCsvRowPreview> previewRows({
    required List<List<String>> dataRows,
    required List<KeyNestColumnMapping> mappings,
    int maxPreviewCount = 10,
  }) {
    final previews = <KeyNestCsvRowPreview>[];
    final previewRowsToProcess = dataRows.take(maxPreviewCount).toList();

    final colTitle = mappings
        .firstWhereOrNull(
          (m) => m.isStandard(KeyNestStandardField.title),
        )
        ?.sourceColumnIndex;
    final colUser = mappings
        .firstWhereOrNull(
          (m) => m.isStandard(KeyNestStandardField.username),
        )
        ?.sourceColumnIndex;
    final colEmail = mappings
        .firstWhereOrNull(
          (m) => m.isStandard(KeyNestStandardField.email),
        )
        ?.sourceColumnIndex;
    final colUrl = mappings
        .firstWhereOrNull(
          (m) => m.isStandard(KeyNestStandardField.website),
        )
        ?.sourceColumnIndex;

    for (int r = 0; r < previewRowsToProcess.length; r++) {
      final row = previewRowsToProcess[r];
      final mappedValues = <String, String>{};

      String getVal(int? idx) =>
          (idx != null && idx >= 0 && idx < row.length) ? row[idx].trim() : '';

      final title = getVal(colTitle);
      final user = getVal(colUser);
      final email = getVal(colEmail);
      final url = getVal(colUrl);

      // Populate preview values according to active mappings
      for (final m in mappings) {
        if (m.isSkipped) continue;
        final val = getVal(m.sourceColumnIndex);
        if (m.destinationType == KeyNestMappingDestinationType.standard &&
            m.standardField != null) {
          mappedValues[m.standardField!.label] = val;
        } else if (m.isCustomField &&
            m.customFieldName != null &&
            m.customFieldName!.trim().isNotEmpty) {
          mappedValues['[Custom] ${m.customFieldName!.trim()}'] = val;
        }
      }

      final effectiveTitle = title.isNotEmpty
          ? title
          : (url.isNotEmpty ? url : '');
      final isAllEmpty = mappedValues.values.every((v) => v.isEmpty);

      bool isValid = true;
      String? issue;

      if (isAllEmpty) {
        isValid = false;
        issue = 'Row is empty across all mapped columns.';
      } else if (effectiveTitle.isEmpty) {
        isValid = false;
        issue = 'Title is missing or empty.';
      } else if (user.isEmpty &&
          email.isEmpty &&
          mappedValues['Password']?.isEmpty == true) {
        // Advisory note for rows with empty credentials
        issue = 'Missing Username, Email, and Password.';
      }

      previews.add(
        KeyNestCsvRowPreview(
          rowIndex: r + 1,
          isValid: isValid,
          title: effectiveTitle.isNotEmpty
              ? effectiveTitle
              : 'Untitled (Row ${r + 1})',
          mappedValues: mappedValues,
          issueReason: issue,
        ),
      );
    }

    return previews;
  }
}
