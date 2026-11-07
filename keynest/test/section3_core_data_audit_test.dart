import 'dart:convert';
import 'dart:io';

import 'package:autofill_service/autofill_service.dart';
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/models/keynest_csv_mapping.dart';
import 'package:keynest/services/keynest_import_export_service.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/keynest_saf_service.dart';
import 'package:keynest/ui/screens/add_payment_card.dart';
import 'package:keynest/ui/screens/keynest_autofill_save_dialog.dart';
import 'package:keynest/ui/screens/keynest_data_screens.dart';
import 'package:keynest/ui/screens/note_details.dart';
import 'package:keynest/ui/screens/select_file_screen.dart';
import 'package:keynest/ui/widgets/keynest_search_highlight.dart';
import 'package:keynest/utils/dialog_utils.dart';
import 'package:keynest/utils/duplicate_detector.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/item_type_helper.dart';
import 'package:keynest/utils/totp_parser.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'util/test_util.mocks.dart';

KdbxFile _createVault(String name) {
  final credentials = Credentials.composite(
    ProtectedValue.fromString('MasterPass123!'),
    null,
  );
  return KdbxFormat().create(credentials, name);
}

MockKdbxBloc _createMockKdbxBloc(KdbxFile file) {
  final bloc = MockKdbxBloc();
  when(bloc.openedFilesKdbx).thenReturn([file]);
  when(bloc.openedFiles).thenReturn(OpenedKdbxFiles({}));
  when(
    bloc.createEntry(file: anyNamed('file'), group: anyNamed('group')),
  ).thenAnswer((invocation) {
    final f = invocation.namedArguments[#file] as KdbxFile? ?? file;
    final g =
        invocation.namedArguments[#group] as KdbxGroup? ?? f.body.rootGroup;
    final entry = KdbxEntry.create(f, g);
    g.addEntry(entry);
    return entry;
  });
  when(
    bloc.saveFile(any),
  ).thenAnswer((_) async => FileContent(Uint8List(0)));
  return bloc;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('keynest_sec3_audit_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (MethodCall call) async {
          return tempRoot.path;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    try {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('[DATA-01] Atomic Local & SAF Vault Writes', () {
    test(
      'FileSourceLocal.write atomically replaces existing vault and cleans .tmp/.bak',
      () async {
        const fs = LocalFileSystem();
        final vaultFile = fs.file('${tempRoot.path}/atomic_vault.kdbx');
        final initialBytes = Uint8List.fromList(utf8.encode('OLD_KDBX_V1'));
        await vaultFile.writeAsBytes(initialBytes, flush: true);

        final source = FileSourceLocal(
          vaultFile,
          databaseName: 'Atomic',
          uuid: 'uuid-atomic-1',
        );
        final updatedBytes = Uint8List.fromList(
          utf8.encode('NEW_KDBX_V2_LONGER_PAYLOAD'),
        );
        await source.write(updatedBytes, {'prev': true});

        expect(await vaultFile.readAsBytes(), equals(updatedBytes));
        expect(fs.file('${vaultFile.path}.tmp').existsSync(), isFalse);
        expect(fs.file('${vaultFile.path}.bak').existsSync(), isFalse);
      },
    );

    test(
      'KeyNestSafService.writeVaultFile preserves existing vault when overwrite is false and replaces atomically when true',
      () async {
        final existing = File('${tempRoot.path}/existing.kdbx');
        final originalBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
        await existing.writeAsBytes(originalBytes, flush: true);

        final dest = KeyNestDirectoryDestination(displayPath: tempRoot.path);
        await expectLater(
          () => KeyNestSafService.writeVaultFile(
            destination: dest,
            fileName: 'existing.kdbx',
            bytes: Uint8List.fromList([9, 9, 9]),
            overwrite: false,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await existing.readAsBytes(), equals(originalBytes));

        final replacementBytes = Uint8List.fromList([10, 20, 30, 40, 50, 60]);
        await KeyNestSafService.writeVaultFile(
          destination: dest,
          fileName: 'existing.kdbx',
          bytes: replacementBytes,
          overwrite: true,
        );
        expect(await existing.readAsBytes(), equals(replacementBytes));
        expect(File('${existing.path}.tmp').existsSync(), isFalse);
        expect(File('${existing.path}.bak').existsSync(), isFalse);
      },
    );

    test(
      'KeyNestSafService.extractRelativeSubPath resolves nested subfolder paths under SAF tree URI',
      () {
        const treeUri =
            'content://com.android.externalstorage.documents/tree/primary%3ADocuments';
        expect(
          KeyNestSafService.extractRelativeSubPath(
            treeUri,
            '/storage/emulated/0/Documents',
          ),
          isNull,
        );
        expect(
          KeyNestSafService.extractRelativeSubPath(
            treeUri,
            '/storage/emulated/0/Documents/KeyNest/Work',
          ),
          equals('KeyNest/Work'),
        );
      },
    );
  });

  group('[DATA-02] Favorites Persistence & Autofill Save Error Handling', () {
    test(
      'KeyNestItemTypeHelper.toggleFavorite persists vault immediately via kdbxBloc.saveFile',
      () async {
        final vault = _createVault('FavVault');
        final bloc = _createMockKdbxBloc(vault);
        final entry = KdbxEntry.create(vault, vault.body.rootGroup);
        vault.body.rootGroup.addEntry(entry);

        expect(KeyNestItemTypeHelper.isFavorite(entry), isFalse);
        final nowFav = await KeyNestItemTypeHelper.toggleFavorite(entry, bloc);
        expect(nowFav, isTrue);
        expect(KeyNestItemTypeHelper.isFavorite(entry), isTrue);
        verify(bloc.saveFile(vault)).called(1);

        final afterUnfav = await KeyNestItemTypeHelper.toggleFavorite(
          entry,
          bloc,
        );
        expect(afterUnfav, isFalse);
        expect(KeyNestItemTypeHelper.isFavorite(entry), isFalse);
        verify(bloc.saveFile(vault)).called(1);
      },
    );

    testWidgets(
      'KeyNestAutofillSaveDialog stays open with error banner and rolls back entry on save failure',
      (tester) async {
        final vault = _createVault('AutofillVault');
        final bloc = _createMockKdbxBloc(vault);
        when(bloc.saveFile(any)).thenThrow(
          const FileSystemException('Disk full (ENOSPC)'),
        );

        var dismissed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KeyNestAutofillSaveDialog(
                kdbxBloc: bloc,
                pendingSave: PendingSaveRequest(
                  username: 'alice@example.com',
                  password: 'SuperSecretPassword!',
                  packageName: 'com.example.app',
                  webDomain: 'example.com',
                ),
                onDismiss: () => dismissed = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save as New'));
        await tester.pumpAndSettle();

        expect(dismissed, isFalse);
        expect(find.textContaining('Failed to save credential'), findsOneWidget);
        expect(vault.body.rootGroup.entries, isEmpty);
      },
    );
  });

  group('[DATA-04] SelectUrlDialog Validation & Unicode Search Highlight', () {
    testWidgets(
      'SelectUrlDialog stays open and shows validation error on invalid URL instead of popping null',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (ctx) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    showDialog<Object?>(
                      context: ctx,
                      builder: (_) => SelectUrlDialog(),
                    );
                  },
                  child: const Text('Open URL Dialog'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open URL Dialog'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'not-a-valid-url');
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        // Dialog must remain open showing an inline error rather than closing.
        expect(find.byType(SelectUrlDialog), findsOneWidget);
      },
    );

    test(
      'KeyNestSearchHighlight.highlight handles Unicode case-folding length changes (İ) without RangeError',
      () {
        // Turkish dotted capital 'İ' (U+0130, length 1) lowercases to 'i\u0307' (length 2).
        const trickyTitle = 'İİİ Bank Account Login';
        final span = KeyNestSearchHighlight.highlight(
          trickyTitle,
          'Login',
          defaultStyle: const TextStyle(fontSize: 14),
          isDark: false,
        );
        expect(span.toPlainText(), equals(trickyTitle));
      },
    );
  });

  group('[DATA-05] CSV/JSON ItemType, Protected CardNumber & Folder Hierarchy', () {
    test(
      'CSV import maps Folder column to real KdbxGroups, writes ItemType, and protects CardNumber',
      () async {
        expect(KeyNestStandardField.cardNumber.isSensitive, isTrue);

        final vault = _createVault('CsvVault');
        final bloc = _createMockKdbxBloc(vault);

        const csvText =
            'Title,Type,Folder,Cardholder,CardNumber,Expiry,CVV\n'
            'Corporate Amex,card,Finance/Cards,JANE DOE,378282246310005,12/29,1234\n';
        final res = await KeyNestImportExportService.importCsvText(
          kdbxBloc: bloc,
          targetFile: vault,
          csvText: csvText,
        );
        expect(res.success, isTrue);
        expect(res.addedCount, equals(1));

        final financeGroup = vault.body.rootGroup.groups.firstWhere(
          (g) => g.name.get() == 'Finance',
        );
        final cardsGroup = financeGroup.groups.firstWhere(
          (g) => g.name.get() == 'Cards',
        );
        expect(cardsGroup.entries.length, equals(1));

        final cardEntry = cardsGroup.entries.first;
        expect(
          cardEntry.getString(KdbxKey('ItemType'))?.getText(),
          equals('card'),
        );
        expect(
          KeyNestItemTypeHelper.getItemType(cardEntry),
          equals(KeyNestItemType.card),
        );
        final storedCardNumber = cardEntry.getString(KdbxKey('CardNumber'));
        expect(storedCardNumber, isA<ProtectedValue>());
        expect(storedCardNumber?.getText(), equals('378282246310005'));
      },
    );

    test(
      'JSON import creates folder hierarchy, protects CardNumber, and preserves card/custom fields on update',
      () async {
        final vault = _createVault('JsonVault');
        final bloc = _createMockKdbxBloc(vault);

        final initialJson = jsonEncode({
          'items': [
            {
              'title': 'Travel Card',
              'type': 'card',
              'folder': 'Personal/Wallet',
              'cardholder': 'JOHN SMITH',
              'cardNumber': '371449635398431',
              'expiry': '08/29',
              'cvv': '8888',
              'network': 'American Express',
              'fields': {'Customer Support': '+1-800-555-0199'},
            },
          ],
        });

        final res1 = await KeyNestImportExportService.importJsonText(
          kdbxBloc: bloc,
          targetFile: vault,
          jsonText: initialJson,
        );
        expect(res1.success, isTrue);
        expect(res1.addedCount, equals(1));

        final personal = vault.body.rootGroup.groups.singleWhere(
          (g) => g.name.get() == 'Personal',
        );
        final wallet = personal.groups.singleWhere(
          (g) => g.name.get() == 'Wallet',
        );
        final entry = wallet.entries.single;
        expect(entry.getString(KdbxKey('ItemType'))?.getText(), equals('card'));
        expect(entry.getString(KdbxKey('CardNumber')), isA<ProtectedValue>());
        expect(
          entry.getString(KdbxKey('Customer Support'))?.getText(),
          equals('+1-800-555-0199'),
        );

        // Now run duplicate update with new CVV & custom field
        final updatedJson = jsonEncode({
          'items': [
            {
              'title': 'Travel Card',
              'type': 'card',
              'folder': 'Personal/Wallet',
              'cardholder': 'JOHN SMITH',
              'cardNumber': '371449635398431',
              'expiry': '08/31',
              'cvv': '9999',
              'network': 'American Express',
              'fields': {'Customer Support': '+1-800-555-0200'},
            },
          ],
        });

        final res2 = await KeyNestImportExportService.importJsonText(
          kdbxBloc: bloc,
          targetFile: vault,
          jsonText: updatedJson,
          duplicateStrategy: KeyNestImportDuplicateStrategy.update,
        );
        expect(res2.success, isTrue);
        expect(res2.updatedCount, equals(1));
        expect(entry.getString(KdbxKey('Expiry'))?.getText(), equals('08/31'));
        expect(entry.getString(KdbxKey('CVV'))?.getText(), equals('9999'));
        expect(
          entry.getString(KdbxKey('Customer Support'))?.getText(),
          equals('+1-800-555-0200'),
        );
      },
    );
  });

  group('[DATA-06] Preferences Merge Preserves hasCompletedOnboarding', () {
    test(
      'KeyNestVaultScope persistence merges into existing preferences without wiping hasCompletedOnboarding',
      () async {
        await KeyNestPreferencesService.setCompletedOnboarding(true);
        expect(await KeyNestPreferencesService.hasCompletedOnboarding(), isTrue);

        KeyNestVaultScope.instance.setFavoritesOnly(true);
        KeyNestVaultScope.instance.setSelectedCategory('Work');
        // Allow async _persist() lock to complete
        await KeyNestPreferencesService.updatePreferences((_) {});

        expect(
          await KeyNestPreferencesService.hasCompletedOnboarding(),
          isTrue,
        );
        final raw = await KeyNestPreferencesService.loadRawPreferences();
        expect(raw['favoritesOnly'], isTrue);
        expect(raw['selectedCategory'], equals('Work'));
        expect(raw['hasCompletedOnboarding'], isTrue);
      },
    );
  });

  group('[DATA-07, DATA-08, DATA-09] Payment Card & Encrypted Note Fixes', () {
    testWidgets(
      'AddPaymentCardScreen saves 15-digit Amex, preserves custom title, allows editing expired cards, and records history',
      (tester) async {
        final vault = _createVault('CardVault');
        final bloc = _createMockKdbxBloc(vault);
        final existingCard = KdbxEntry.create(vault, vault.body.rootGroup);
        vault.body.rootGroup.addEntry(existingCard);
        existingCard.setString(
          KdbxKeyCommon.TITLE,
          PlainValue('Corporate Platinum Amex'),
        );
        KeyNestItemTypeHelper.setItemType(existingCard, KeyNestItemType.card);
        existingCard.setString(KdbxKey('Cardholder'), PlainValue('ALICE DOE'));
        existingCard.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('378282246310005'),
        );
        // Already expired card (01/22) must still be editable!
        existingCard.setString(KdbxKey('Expiry'), PlainValue('01/22'));
        existingCard.setString(
          KdbxKey('CVV'),
          ProtectedValue.fromString('1234'),
        );
        existingCard.setString(
          KdbxKey('Notes'),
          ProtectedValue.fromString('Keep for expense audit'),
        );

        await tester.pumpWidget(
          Provider<KdbxBloc>.value(
            value: bloc,
            child: MaterialApp(
              home: AddPaymentCardScreen(existingEntry: existingCard),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final saveBtn = find.text('Save Card');
        await tester.ensureVisible(saveBtn);
        await tester.tap(saveBtn);
        await tester.pumpAndSettle();

        expect(
          existingCard.getString(KdbxKeyCommon.TITLE)?.getText(),
          equals('Corporate Platinum Amex'),
        );
        expect(
          existingCard.getString(KdbxKeyCommon.PASSWORD)?.getText(),
          equals('378282246310005'),
        );
        expect(existingCard.getString(KdbxKey('Notes')), isA<ProtectedValue>());
        expect(existingCard.history.length, equals(1));
      },
    );

    testWidgets(
      'NoteDetailsScreen preserves ProtectedValue on encrypted Notes and blank custom fields',
      (tester) async {
        final vault = _createVault('NoteVault');
        final bloc = _createMockKdbxBloc(vault);
        final note = KdbxEntry.create(vault, vault.body.rootGroup);
        vault.body.rootGroup.addEntry(note);
        note.setString(KdbxKeyCommon.TITLE, PlainValue('SSH Recovery Note'));
        KeyNestItemTypeHelper.setItemType(note, KeyNestItemType.note);
        note.setString(
          KdbxKey('Notes'),
          ProtectedValue.fromString('Original encrypted body'),
        );
        note.setString(KdbxKey('EmptyTemplateField'), PlainValue(''));

        await tester.pumpWidget(
          Provider<KdbxBloc>.value(
            value: bloc,
            child: MaterialApp(
              home: NoteDetailsScreen(entry: note, isEditing: true),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect(note.getString(KdbxKey('Notes')), isA<ProtectedValue>());
        expect(note.getString(KdbxKey('EmptyTemplateField')), isNotNull);
      },
    );
  });

  group('[DATA-10] SimplePromptDialog Clipboard Guard & ReceiveItemSheet', () {
    testWidgets(
      'SimplePromptDialog does NOT overwrite typed text with clipboard on AppLifecycleState.resumed',
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                return <String, dynamic>{'text': 'CLIPBOARD_SECRET_OVERWRITE'};
              }
              return null;
            });

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SimplePromptDialog(
                title: 'New Folder',
                initialValue: 'MyTypedFolder',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();

        expect(find.text('MyTypedFolder'), findsOneWidget);
        expect(find.text('CLIPBOARD_SECRET_OVERWRITE'), findsNothing);
      },
    );

    testWidgets(
      'KeyNestReceiveItemSheet imports otpauth://totp payload into open vault and saves',
      (tester) async {
        final vault = _createVault('ReceiveVault');
        final bloc = _createMockKdbxBloc(vault);

        await tester.pumpWidget(
          Provider<KdbxBloc>.value(
            value: bloc,
            child: const MaterialApp(
              home: Scaffold(body: KeyNestReceiveItemSheet()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byType(TextField),
          'otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub',
        );
        await tester.tap(find.text('Import Code'));
        await tester.pumpAndSettle();

        expect(vault.body.rootGroup.entries.length, equals(1));
        final imported = vault.body.rootGroup.entries.single;
        expect(
          imported.getString(KdbxKeyCommon.TITLE)?.getText(),
          equals('GitHub'),
        );
        expect(imported.getString(KdbxKey('OTPAuth')), isA<ProtectedValue>());
        verify(bloc.saveFile(vault)).called(1);
      },
    );
  });

  group('[DATA-11 & DATA-12] HOTP Rejection & Complete Duplicate Precision', () {
    test(
      'EntryTotpHelper and TotpQrData reject counter-based otpauth://hotp URIs',
      () {
        const hotpUri =
            'otpauth://hotp/Example:alice?secret=JBSWY3DPEHPK3PXP&counter=1';
        const totpUri =
            'otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&period=30';

        expect(EntryTotpHelper.parseOtpAuth(hotpUri), isNull);
        expect(TotpQrData.parse(hotpUri), isNull);

        expect(EntryTotpHelper.parseOtpAuth(totpUri), isNotNull);
        expect(TotpQrData.parse(totpUri), isNotNull);
      },
    );

    test(
      'KeyNestDuplicateDetector.areCompleteDuplicates distinguishes URL paths and binary attachment bytes',
      () {
        final vault = _createVault('DupeVault');
        final a = KdbxEntry.create(vault, vault.body.rootGroup);
        final b = KdbxEntry.create(vault, vault.body.rootGroup);
        vault.body.rootGroup.addEntry(a);
        vault.body.rootGroup.addEntry(b);

        for (final e in [a, b]) {
          e.setString(KdbxKeyCommon.TITLE, PlainValue('GitHub Org'));
          e.setString(KdbxKeyCommon.USER_NAME, PlainValue('admin'));
          e.setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('SamePass!'),
          );
        }
        a.setString(KdbxKeyCommon.URL, PlainValue('https://github.com/org-a'));
        b.setString(KdbxKeyCommon.URL, PlainValue('https://github.com/org-b'));

        // Registrable domain normalizer still matches github.com for autofill:
        expect(
          KeyNestDuplicateDetector.normalizeUrl('https://github.com/org-a'),
          equals('github.com'),
        );
        // Complete duplicate check must NOT collapse distinct URL paths:
        expect(KeyNestDuplicateDetector.areCompleteDuplicates(a, b), isFalse);

        // Make URLs identical, then attach same-named files with different bytes:
        b.setString(KdbxKeyCommon.URL, PlainValue('https://github.com/org-a'));
        expect(KeyNestDuplicateDetector.areCompleteDuplicates(a, b), isTrue);

        a.createBinary(
          isProtected: true,
          name: 'id_ed25519',
          bytes: Uint8List.fromList([1, 2, 3, 4]),
        );
        b.createBinary(
          isProtected: true,
          name: 'id_ed25519',
          bytes: Uint8List.fromList([1, 2, 3, 99]),
        );
        expect(KeyNestDuplicateDetector.areCompleteDuplicates(a, b), isFalse);
      },
    );
  });
}

