import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/item_type_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Large Vault Unlock Performance Profiling', () {
    for (final count in [20, 200, 1000]) {
      test('Profile vault with $count entries', () async {
        final kdbxFormat = KdbxFormat();
        final credentials =
            Credentials(ProtectedValue.fromString('master_pass_123'));
        final kdbx = kdbxFormat.create(credentials, 'Vault$count');
        final root = kdbx.body.rootGroup;

        for (var i = 0; i < count; i++) {
          final entry = KdbxEntry.create(kdbx, root);
          root.addEntry(entry);
          entry.setString(KdbxKey('Title'), PlainValue('Service $i'));
          entry.setString(
              KdbxKey('UserName'), PlainValue('user$i@example.com'));
          entry.setString(
              KdbxKey('Password'), ProtectedValue.fromString('password$i'));
          entry.setString(
              KdbxKey('URL'), PlainValue('https://service$i.example.com'));
          if (i % 5 == 0) {
            entry.setString(KdbxKey('otp'),
                PlainValue('otpauth://totp/Service$i:user?secret=JBSWY3DPEHPK3PXP'));
          }
          if (i % 7 == 0) {
            entry.setString(KdbxKey('item_type'), PlainValue('card'));
          } else if (i % 11 == 0) {
            entry.setString(KdbxKey('item_type'), PlainValue('note'));
          }
        }

        final bytes = await kdbxFormat.save(kdbx, (b) async => b);

        // 1. Decryption & Parsing in compute isolate
        final swDecrypt = Stopwatch()..start();
        final computeResponse = await compute(
          KdbxBloc.staticReadKdbxFile,
          KdbxReadArgs(bytes, credentials),
        );
        swDecrypt.stop();
        final parsedKdbx = computeResponse.file!;

        // 2. Tab counts baseline calculation
        final allEntries = parsedKdbx.body.rootGroup.getAllEntries();
        final swTabCounts = Stopwatch()..start();
        int secrets = 0, records = 0, cards = 0, notes = 0, tfas = 0;
        for (final e in allEntries) {
          if (KeyNestItemTypeHelper.isEntryInTrash(e)) {
            continue;
          }
          final type = KeyNestItemTypeHelper.getItemType(e);
          if (type == KeyNestItemType.record) {
            records++;
          } else if (type == KeyNestItemType.card) {
            cards++;
          } else if (type == KeyNestItemType.note) {
            notes++;
          } else {
            secrets++;
          }

          if (EntryTotpHelper.hasTotp(e)) {
            tfas++;
          }
        }
        swTabCounts.stop();

        // 3. Group breadcrumbs without cache vs with cache
        final swBreadcrumbs = Stopwatch()..start();
        final breadcrumbsMap = <KdbxGroup, List<String>>{};
        for (final e in allEntries) {
          final parent = e.parent;
          if (parent != null) {
            breadcrumbsMap.putIfAbsent(
              parent,
              () => parent.breadcrumbs
                  .map((g) => g.name.get() ?? '')
                  .where((n) => n.isNotEmpty)
                  .toList(),
            );
          }
        }
        swBreadcrumbs.stop();

        // 4. Sorting list of entries
        final swSort = Stopwatch()..start();
        final sorted = List<KdbxEntry>.from(allEntries)
          ..sort((a, b) {
            final aTitle = a.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
            final bTitle = b.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
            return aTitle.compareTo(bTitle);
          });
        swSort.stop();

        // 5. Redundant re-sort (as previously occurred in build())
        final swRedundantSort = Stopwatch()..start();
        final reSorted = List<KdbxEntry>.from(sorted)
          ..sort((a, b) {
            final aTitle = a.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
            final bTitle = b.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
            return aTitle.compareTo(bTitle);
          });
        swRedundantSort.stop();

        debugPrint(
          '=== Vault ($count entries) ===\n'
          '  Decryption & Parse (isolate): ${swDecrypt.elapsedMilliseconds} ms\n'
          '  Tab Counts Scan: ${swTabCounts.elapsedMicroseconds} us (${swTabCounts.elapsedMilliseconds} ms)\n'
          '  Cached Breadcrumbs (all entries): ${swBreadcrumbs.elapsedMicroseconds} us\n'
          '  Entry Sort (1st pass in _updateAllEntries): ${swSort.elapsedMicroseconds} us (${swSort.elapsedMilliseconds} ms)\n'
          '  Redundant Re-Sort (2nd pass in build()): ${swRedundantSort.elapsedMicroseconds} us (${swRedundantSort.elapsedMilliseconds} ms)',
        );

        expect(parsedKdbx, isNotNull);
        expect(secrets + records + cards + notes, count);
        expect(tfas, count ~/ 5);
        expect(sorted.length, count);
        expect(reSorted.length, count);
      });
    }
  });
}
