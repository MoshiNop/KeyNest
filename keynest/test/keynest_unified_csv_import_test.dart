import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/models/keynest_csv_mapping.dart';
import 'package:keynest/services/keynest_import_export_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/ui/design_system/design_tokens.dart';
import 'package:keynest/ui/screens/keynest_csv_import_screen.dart';
import 'package:keynest/ui/screens/keynest_import_export.dart';
import 'package:keynest/ui/widgets/keynest_destination_picker.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'util/test_util.mocks.dart';

void main() {
  group('1. Unified CSV Import & Auto-Detection Tests', () {
    test('Auto-detects Bitwarden CSV headers accurately', () {
      final headers = [
        'folder',
        'favorite',
        'type',
        'name',
        'notes',
        'fields',
        'reprompt',
        'login_uri',
        'login_username',
        'login_password',
        'login_totp',
      ];

      final mappings = KeyNestCsvMappingHelper.autoDetectMappings(headers);

      final titleMapping = mappings.firstWhere(
        (m) => m.isStandard(KeyNestStandardField.title),
      );
      expect(titleMapping.sourceColumnName, equals('name'));

      final userMapping = mappings.firstWhere(
        (m) => m.isStandard(KeyNestStandardField.username),
      );
      expect(userMapping.sourceColumnName, equals('login_username'));

      final passMapping = mappings.firstWhere(
        (m) => m.isStandard(KeyNestStandardField.password),
      );
      expect(passMapping.sourceColumnName, equals('login_password'));

      final uriMapping = mappings.firstWhere(
        (m) => m.isStandard(KeyNestStandardField.website),
      );
      expect(uriMapping.sourceColumnName, equals('login_uri'));

      final totpMapping = mappings.firstWhere(
        (m) => m.isStandard(KeyNestStandardField.totp),
      );
      expect(totpMapping.sourceColumnName, equals('login_totp'));

      final categoryMapping = mappings.firstWhere(
        (m) => m.isStandard(KeyNestStandardField.category),
      );
      expect(categoryMapping.sourceColumnName, equals('folder'));

      // Unrecognized Bitwarden columns become custom fields
      final fieldsMapping = mappings.firstWhere(
        (m) => m.sourceColumnName == 'fields',
      );
      expect(fieldsMapping.isCustomField, isTrue);
      expect(fieldsMapping.customFieldName, equals('fields'));
    });

    test('Auto-detects 1Password and LastPass headers accurately', () {
      // 1Password
      final onePassHeaders = [
        'Title',
        'Url',
        'Username',
        'Password',
        'Notes',
        'OTPAuth',
      ];
      final onePassMappings = KeyNestCsvMappingHelper.autoDetectMappings(
        onePassHeaders,
      );
      expect(
        onePassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.title))
            .sourceColumnName,
        equals('Title'),
      );
      expect(
        onePassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.website))
            .sourceColumnName,
        equals('Url'),
      );
      expect(
        onePassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.username))
            .sourceColumnName,
        equals('Username'),
      );
      expect(
        onePassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.password))
            .sourceColumnName,
        equals('Password'),
      );
      expect(
        onePassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.totp))
            .sourceColumnName,
        equals('OTPAuth'),
      );

      // LastPass
      final lastPassHeaders = [
        'url',
        'username',
        'password',
        'totp',
        'extra',
        'name',
        'grouping',
        'fav',
      ];
      final lastPassMappings = KeyNestCsvMappingHelper.autoDetectMappings(
        lastPassHeaders,
      );
      expect(
        lastPassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.title))
            .sourceColumnName,
        equals('name'),
      );
      expect(
        lastPassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.website))
            .sourceColumnName,
        equals('url'),
      );
      expect(
        lastPassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.username))
            .sourceColumnName,
        equals('username'),
      );
      expect(
        lastPassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.notes))
            .sourceColumnName,
        equals('extra'),
      );
      expect(
        lastPassMappings
            .firstWhere((m) => m.isStandard(KeyNestStandardField.category))
            .sourceColumnName,
        equals('grouping'),
      );
    });

    test(
      'Auto-detects dedicated Email column alongside Username in Generic CSV',
      () {
        final headers = [
          'Title',
          'Username',
          'Email',
          'Password',
          'Website',
          'Notes',
        ];
        final mappings = KeyNestCsvMappingHelper.autoDetectMappings(headers);

        expect(
          mappings
              .firstWhere((m) => m.isStandard(KeyNestStandardField.username))
              .sourceColumnName,
          equals('Username'),
        );
        expect(
          mappings
              .firstWhere((m) => m.isStandard(KeyNestStandardField.email))
              .sourceColumnName,
          equals('Email'),
        );
      },
    );
  });

  group('2. Custom Field Mapping & Arbitrary Assignment Tests', () {
    test(
      'User manual mapping takes absolute precedence over header names',
      () async {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('MasterKeyPass123!'),
          null,
        );
        final format = KdbxFormat();
        final file = format.create(credentials, 'Precedence Test Vault');

        // CSV has "username" and "email", but user purposefully swaps them:
        // "username" -> Email
        // "email" -> Username
        const csvContent = '''
Title,username,password,email
SwappedEntry,my_email_val@example.com,secret123,actual_username
''';

        final rows = KeyNestImportExportService.parseCsv(csvContent);

        final customMappings = [
          KeyNestColumnMapping(
            sourceColumnIndex: 0,
            sourceColumnName: 'Title',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.title,
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 1,
            sourceColumnName: 'username',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.email, // Mapped to Email!
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 2,
            sourceColumnName: 'password',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.password,
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 3,
            sourceColumnName: 'email',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.username, // Mapped to Username!
          ),
        ];

        final mockKdbxBloc = MockKdbxBloc();
        when(
          mockKdbxBloc.createEntry(
            file: anyNamed('file'),
            group: anyNamed('group'),
          ),
        ).thenAnswer((invocation) {
          final f = invocation.namedArguments[#file] as KdbxFile? ?? file;
          final g =
              invocation.namedArguments[#group] as KdbxGroup? ??
              f.body.rootGroup;
          final entry = KdbxEntry.create(f, g);
          g.addEntry(entry);
          return entry;
        });
        when(
          mockKdbxBloc.saveFile(any),
        ).thenAnswer((_) async => FileContent(Uint8List(0)));

        final result = await KeyNestImportExportService.importMappedCsv(
          kdbxBloc: mockKdbxBloc,
          targetFile: file,
          rows: rows,
          mappings: customMappings,
        );

        expect(result.success, isTrue);
        expect(result.count, equals(1));

        final entries = file.body.rootGroup.getAllEntries().toList();
        expect(entries.length, equals(1));

        final entry = entries.first;
        expect(
          entry.getString(KdbxKeyCommon.TITLE)?.getText(),
          equals('SwappedEntry'),
        );
        // Verify swapped values
        expect(
          entry.getString(KdbxKey('Email'))?.getText(),
          equals('my_email_val@example.com'),
        );
        expect(
          entry.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          equals('actual_username'),
        );
        expect(
          entry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          equals('secret123'),
        );
      },
    );

    test(
      'Custom fields are created with user-specified names and values',
      () async {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('MasterKeyPass123!'),
          null,
        );
        final format = KdbxFormat();
        final file = format.create(credentials, 'Custom Field Vault');

        const csvContent = '''
Title,Username,Password,Recovery Code,Security Question
MyService,admin,Pass123,RC-9988-7766,What is your pet name?
''';

        final rows = KeyNestImportExportService.parseCsv(csvContent);

        final mappings = [
          KeyNestColumnMapping(
            sourceColumnIndex: 0,
            sourceColumnName: 'Title',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.title,
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 1,
            sourceColumnName: 'Username',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.username,
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 2,
            sourceColumnName: 'Password',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.password,
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 3,
            sourceColumnName: 'Recovery Code',
            destinationType: KeyNestMappingDestinationType.customField,
            customFieldName: 'Backup Recovery Key', // User renamed custom field
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 4,
            sourceColumnName: 'Security Question',
            destinationType: KeyNestMappingDestinationType.customField,
            customFieldName: 'Security Question',
          ),
        ];

        final mockKdbxBloc = MockKdbxBloc();
        when(
          mockKdbxBloc.createEntry(
            file: anyNamed('file'),
            group: anyNamed('group'),
          ),
        ).thenAnswer((invocation) {
          final f = invocation.namedArguments[#file] as KdbxFile? ?? file;
          final g =
              invocation.namedArguments[#group] as KdbxGroup? ??
              f.body.rootGroup;
          final entry = KdbxEntry.create(f, g);
          g.addEntry(entry);
          return entry;
        });
        when(
          mockKdbxBloc.saveFile(any),
        ).thenAnswer((_) async => FileContent(Uint8List(0)));

        final result = await KeyNestImportExportService.importMappedCsv(
          kdbxBloc: mockKdbxBloc,
          targetFile: file,
          rows: rows,
          mappings: mappings,
        );

        expect(result.success, isTrue);

        final entry = file.body.rootGroup.getAllEntries().first;
        expect(
          entry.getString(KdbxKeyCommon.TITLE)?.getText(),
          equals('MyService'),
        );
        expect(
          entry.getString(KdbxKey('Backup Recovery Key'))?.getText(),
          equals('RC-9988-7766'),
        );
        expect(
          entry.getString(KdbxKey('Security Question'))?.getText(),
          equals('What is your pet name?'),
        );
      },
    );

    test(
      'Skipped columns are completely ignored and not written to entries',
      () async {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('MasterKeyPass123!'),
          null,
        );
        final format = KdbxFormat();
        final file = format.create(credentials, 'Skip Vault');

        const csvContent = '''
Title,Username,Password,IgnoreMe1,IgnoreMe2
Server,root,RootPass99,secret_trash,junk_data
''';

        final rows = KeyNestImportExportService.parseCsv(csvContent);

        final mappings = [
          KeyNestColumnMapping(
            sourceColumnIndex: 0,
            sourceColumnName: 'Title',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.title,
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 1,
            sourceColumnName: 'Username',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.username,
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 2,
            sourceColumnName: 'Password',
            destinationType: KeyNestMappingDestinationType.standard,
            standardField: KeyNestStandardField.password,
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 3,
            sourceColumnName: 'IgnoreMe1',
            destinationType: KeyNestMappingDestinationType.skip,
          ),
          KeyNestColumnMapping(
            sourceColumnIndex: 4,
            sourceColumnName: 'IgnoreMe2',
            destinationType: KeyNestMappingDestinationType.skip,
          ),
        ];

        final mockKdbxBloc = MockKdbxBloc();
        when(
          mockKdbxBloc.createEntry(
            file: anyNamed('file'),
            group: anyNamed('group'),
          ),
        ).thenAnswer((invocation) {
          final f = invocation.namedArguments[#file] as KdbxFile? ?? file;
          final g =
              invocation.namedArguments[#group] as KdbxGroup? ??
              f.body.rootGroup;
          final entry = KdbxEntry.create(f, g);
          g.addEntry(entry);
          return entry;
        });
        when(
          mockKdbxBloc.saveFile(any),
        ).thenAnswer((_) async => FileContent(Uint8List(0)));

        final result = await KeyNestImportExportService.importMappedCsv(
          kdbxBloc: mockKdbxBloc,
          targetFile: file,
          rows: rows,
          mappings: mappings,
        );

        expect(result.success, isTrue);

        final entry = file.body.rootGroup.getAllEntries().first;
        expect(entry.getString(KdbxKey('IgnoreMe1')), isNull);
        expect(entry.getString(KdbxKey('IgnoreMe2')), isNull);
      },
    );
  });

  group('3. Mapping Conflict & Validation Tests', () {
    test('Rejects duplicate mapping targeting the same standard field', () {
      final mappings = [
        KeyNestColumnMapping(
          sourceColumnIndex: 0,
          sourceColumnName: 'ItemName',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.title,
        ),
        KeyNestColumnMapping(
          sourceColumnIndex: 1,
          sourceColumnName: 'PageTitle',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.title, // Duplicate Title!
        ),
        KeyNestColumnMapping(
          sourceColumnIndex: 2,
          sourceColumnName: 'Username',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.username,
        ),
      ];

      final validation = KeyNestCsvMappingHelper.validateMappings(mappings);
      expect(validation.isValid, isFalse);
      expect(
        validation.errors.any(
          (e) => e.contains(
            "Multiple columns ('ItemName', 'PageTitle') are mapped to 'Title'",
          ),
        ),
        isTrue,
      );
    });

    test('Rejects duplicate custom field names', () {
      final mappings = [
        KeyNestColumnMapping(
          sourceColumnIndex: 0,
          sourceColumnName: 'Title',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.title,
        ),
        KeyNestColumnMapping(
          sourceColumnIndex: 1,
          sourceColumnName: 'Code1',
          destinationType: KeyNestMappingDestinationType.customField,
          customFieldName: 'PinCode',
        ),
        KeyNestColumnMapping(
          sourceColumnIndex: 2,
          sourceColumnName: 'Code2',
          destinationType: KeyNestMappingDestinationType.customField,
          customFieldName:
              'pincode', // Same custom field name case-insensitively
        ),
      ];

      final validation = KeyNestCsvMappingHelper.validateMappings(mappings);
      expect(validation.isValid, isFalse);
      expect(
        validation.errors.any(
          (e) => e.contains("Duplicate custom field name 'PinCode'"),
        ),
        isTrue,
      );
    });

    test('Rejects missing Title mapping', () {
      final mappings = [
        KeyNestColumnMapping(
          sourceColumnIndex: 0,
          sourceColumnName: 'User',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.username,
        ),
        KeyNestColumnMapping(
          sourceColumnIndex: 1,
          sourceColumnName: 'Pass',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.password,
        ),
      ];

      final validation = KeyNestCsvMappingHelper.validateMappings(mappings);
      expect(validation.isValid, isFalse);
      expect(
        validation.errors.any(
          (e) => e.contains("Please map at least one column to 'Title'"),
        ),
        isTrue,
      );
    });

    test('Rejects empty custom field name', () {
      final mappings = [
        KeyNestColumnMapping(
          sourceColumnIndex: 0,
          sourceColumnName: 'Title',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.title,
        ),
        KeyNestColumnMapping(
          sourceColumnIndex: 1,
          sourceColumnName: 'CustomCol',
          destinationType: KeyNestMappingDestinationType.customField,
          customFieldName: '   ', // Blank
        ),
      ];

      final validation = KeyNestCsvMappingHelper.validateMappings(mappings);
      expect(validation.isValid, isFalse);
      expect(
        validation.errors.any(
          (e) => e.contains('Custom field name cannot be empty'),
        ),
        isTrue,
      );
    });
  });

  group('4. Live CSV Preview Tests', () {
    test('Generates preview reflecting active mappings with row status', () {
      final dataRows = [
        ['Google', 'user@gmail.com', 'Pass1', 'https://google.com'],
        ['', '', '', ''], // empty row
        ['GitHub', 'octocat', 'Pass2', 'https://github.com'],
      ];

      final mappings = [
        KeyNestColumnMapping(
          sourceColumnIndex: 0,
          sourceColumnName: 'Title',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.title,
        ),
        KeyNestColumnMapping(
          sourceColumnIndex: 1,
          sourceColumnName: 'Email',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.email,
        ),
        KeyNestColumnMapping(
          sourceColumnIndex: 2,
          sourceColumnName: 'Password',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.password,
        ),
        KeyNestColumnMapping(
          sourceColumnIndex: 3,
          sourceColumnName: 'Website',
          destinationType: KeyNestMappingDestinationType.standard,
          standardField: KeyNestStandardField.website,
        ),
      ];

      final previews = KeyNestCsvMappingHelper.previewRows(
        dataRows: dataRows,
        mappings: mappings,
      );

      expect(previews.length, equals(3));

      // Row 1: Valid
      expect(previews[0].isValid, isTrue);
      expect(previews[0].title, equals('Google'));
      expect(previews[0].mappedValues['Email'], equals('user@gmail.com'));
      expect(previews[0].mappedValues['Password'], equals('Pass1'));

      // Row 2: Empty row
      expect(previews[1].isValid, isFalse);
      expect(previews[1].issueReason, contains('Row is empty'));

      // Row 3: Valid
      expect(previews[2].isValid, isTrue);
      expect(previews[2].title, equals('GitHub'));
    });
  });

  group('5. Robust CSV Parsing Tests', () {
    test(
      'Handles commas inside quotes, escaped quotes, multiline values, and Unicode',
      () {
        const complexCsv = '''
Title,Username,Password,Notes
"Company, Inc.",user1,"p""a,ss","Notes with
newline and unicode 🔑"
Simple,user2,pass2,regular note
''';

        final rows = KeyNestImportExportService.parseCsv(complexCsv);
        expect(rows.length, equals(3));

        final firstRow = rows[1];
        expect(firstRow[0], equals('Company, Inc.'));
        expect(firstRow[1], equals('user1'));
        expect(firstRow[2], equals('p"a,ss'));
        expect(firstRow[3], contains('\n'));
        expect(firstRow[3], contains('🔑'));

        final secondRow = rows[2];
        expect(secondRow[0], equals('Simple'));
        expect(secondRow[1], equals('user2'));
      },
    );
  });

  group('6. Import/Export UI & CSV Screen Tests', () {
    testWidgets(
      'KeyNestImportExportScreen displays unified CSV option and no redundant tiles',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final credentials = Credentials.composite(
          ProtectedValue.fromString('pass'),
          null,
        );
        final file = KdbxFormat().create(credentials, 'UI Vault');
        final mockBloc = MockKdbxBloc();
        when(mockBloc.openedFilesKdbx).thenReturn([file]);

        await tester.pumpWidget(
          MaterialApp(
            home: Provider<KdbxBloc>.value(
              value: mockBloc,
              child: const KeyNestImportExportScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Unified CSV tile exists
        expect(find.text('CSV Spreadsheet (.csv)'), findsOneWidget);
        expect(find.text('UNIFIED IMPORT'), findsOneWidget);

        // Redundant import tiles are gone
        expect(find.text('Bitwarden'), findsNothing);
        expect(find.text('LastPass'), findsNothing);
        expect(find.text('1Password'), findsNothing);
        expect(find.text('Generic CSV Spreadsheet'), findsNothing);

        // Other import and export tiles preserved
        expect(find.text('KeePass Database (.kdbx)'), findsOneWidget);
        expect(find.text('JSON Document'), findsOneWidget);
        expect(find.text('Export JSON Document'), findsOneWidget);
        expect(find.text('Export KeePass (.kdbx)'), findsOneWidget);
        expect(find.text('Export CSV Spreadsheet'), findsOneWidget);
      },
    );

    testWidgets(
      'KeyNestCsvImportScreen toggles between Quick Import and Custom Mapping',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final credentials = Credentials.composite(
          ProtectedValue.fromString('pass'),
          null,
        );
        final file = KdbxFormat().create(credentials, 'Screen Vault');
        final mockBloc = MockKdbxBloc();
        when(mockBloc.openedFilesKdbx).thenReturn([file]);
        when(mockBloc.openedFiles).thenReturn(OpenedKdbxFiles({}));
        when(mockBloc.openedFilesWithSources).thenReturn([]);

        const sampleCsv = '''
Title,Username,Password,Recovery Code
Server1,admin,pass1,1234
''';
        final rows = KeyNestImportExportService.parseCsv(sampleCsv);

        await tester.pumpWidget(
          MaterialApp(
            home: Provider<KdbxBloc>.value(
              value: mockBloc,
              child: KeyNestCsvImportScreen(
                fileName: 'passwords.csv',
                csvText: sampleCsv,
                parsedRows: rows,
                initialDestination: KeyNestDestination(
                  file: file,
                  group: file.body.rootGroup,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Quick Import is default
        expect(find.text('Quick Import'), findsOneWidget);
        expect(find.text('Custom Mapping'), findsOneWidget);
        expect(find.text('AUTOMATICALLY DETECTED COLUMNS (4)'), findsOneWidget);

        // Switch to Custom Mapping
        await tester.tap(find.text('Custom Mapping'));
        await tester.pumpAndSettle();

        expect(find.text('COLUMN ASSIGNMENTS (4)'), findsOneWidget);
        expect(find.text('Col 1'), findsOneWidget);
        expect(find.text('Col 2'), findsOneWidget);
        expect(find.text('Col 3'), findsOneWidget);
        expect(find.text('Col 4'), findsOneWidget);
        expect(find.text('LIVE RECORD PREVIEW'), findsOneWidget);
      },
    );

    testWidgets(
      'Import/Export Theme System: CheckboxTheme and semantic warning/success colors ensure high contrast',
      (WidgetTester tester) async {
        final lightTheme = createTheme();
        final darkTheme = createDarkTheme();

        // Checkbox theme side border thickness must be 2.0 for accessibility
        expect(
          WidgetStateProperty.resolveAs(lightTheme.checkboxTheme.side, {}),
          equals(const BorderSide(color: Color(0xFF73777F), width: 2.0)),
        );
        expect(
          WidgetStateProperty.resolveAs(darkTheme.checkboxTheme.side, {}),
          equals(const BorderSide(color: Color(0xFF94A3B8), width: 2.0)),
        );

        // Dark mode warning and success colors must provide high contrast
        expect(KeyNestPalette.warningColorFor(true), equals(const Color(0xFFF5BD48)));
        expect(KeyNestPalette.warningColorFor(false), equals(const Color(0xFF7C5800)));
        expect(KeyNestPalette.successColorFor(true), equals(const Color(0xFF90D889)));
        expect(KeyNestPalette.successColorFor(false), equals(const Color(0xFF286C2A)));
      },
    );

    testWidgets(
      'KeyNestImportExportScreen renders icons with theme accent color and no container box in dark mode',
      (WidgetTester tester) async {
        final credentials = Credentials.composite(
          ProtectedValue.fromString('pass'),
          null,
        );
        final file = KdbxFormat().create(credentials, 'UI Vault');
        final mockBloc = MockKdbxBloc();
        when(mockBloc.openedFilesKdbx).thenReturn([file]);

        await tester.pumpWidget(
          MaterialApp(
            theme: createDarkTheme(),
            home: Provider<KdbxBloc>.value(
              value: mockBloc,
              child: const KeyNestImportExportScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Icons must be rendered with dark primary accent
        final shieldIcon = tester.widget<Icon>(find.byIcon(Icons.shield_rounded));
        expect(shieldIcon.color, equals(KeyNestPalette.primaryDark));

        final csvIcon = tester.widgetList<Icon>(find.byIcon(Icons.table_chart_rounded)).first;
        expect(csvIcon.color, equals(KeyNestPalette.primaryDark));

        // Badges for UNENCRYPTED must use dark-mode warning color (Color(0xFFF5BD48))
        final unencryptedBadgeText = tester.widgetList<Text>(find.text('UNENCRYPTED')).first;
        expect(unencryptedBadgeText.style?.color, equals(KeyNestTokens.darkWarning));

        // Badges for UNIFIED IMPORT must use dark-mode success color (Color(0xFF90D889))
        final unifiedBadgeText = tester.widget<Text>(find.text('UNIFIED IMPORT'));
        expect(unifiedBadgeText.style?.color, equals(KeyNestTokens.darkSuccess));
      },
    );
  });
}
