import 'dart:async';
import 'package:autofill_service/autofill_service.dart';
import 'package:autofill_shared/credential_matcher.dart';
import 'package:flutter/material.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/services/keynest_pending_login_memory.dart';
import 'package:keynest/ui/screens/keynest_autofill_sheet.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:logging/logging.dart';

final _logger = Logger('autofill_resume_helper');

class AutofillResumeHelper {
  static Future<bool> _confirmOriginMismatch(
    BuildContext context,
    KdbxEntry entry,
    String targetContext,
  ) async {
    final entryUrl =
        entry.getString(KdbxKeyCommon.URL)?.getText()?.trim() ??
        entry.label ??
        'this entry';
    final target = targetContext.isNotEmpty
        ? targetContext
        : 'the current site';

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 24),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Website Mismatch Warning',
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(
            'This login is saved for "$entryUrl", but you are currently filling into "$target".\n\n'
            'Filling credentials into an unrelated website may expose your password to phishing or unintended recipients.\n\n'
            'Are you sure you want to fill this credential into $target?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Fill Anyway'),
          ),
        ],
      ),
    );
    return result == true;
  }

  static Future<void> resumeAutofill(
    BuildContext context,
    KdbxBloc kdbxBloc, {
    bool forcePicker = false,
  }) async {
    String? selectedEntryId;
    // If not explicitly forced, check whether the native intent signals force picker or selectedEntryId
    if (!forcePicker) {
      try {
        final requestInfo = await AutofillService().getAutofillRequestInfo();
        if (requestInfo.forcePicker) {
          forcePicker = true;
        }
        selectedEntryId = requestInfo.selectedEntryId;
      } catch (_) {
        // Ignore — fall through to the rest of the flow
      }
    }
    try {
      // 1. Sync credentials immediately to native Android credential store
      await kdbxBloc.syncAndroidAutofillStore(immediate: true);

      // 2. Retrieve pending autofill metadata
      final meta = await AutofillService().getAutofillMetadata();
      if (meta == null && selectedEntryId == null) {
        _logger.info(
          'No autofill metadata found and no explicit entry selected, opening credential picker',
        );
        if (context.mounted) {
          await Navigator.of(context).push(
            KeyNestAutofillSheet.route(kdbxBloc: kdbxBloc),
          );
        }
        return;
      }

      final requests = <CredentialRequest>[];
      if (meta != null) {
        for (final domain in meta.webDomains) {
          if (domain.domain.isNotEmpty) {
            requests.add(CredentialRequest.web('https://${domain.domain}'));
          }
        }
        for (final pkg in meta.packageNames) {
          if (pkg.isNotEmpty) {
            requests.add(CredentialRequest.application(pkg));
          }
        }
      }

      final targetContext = (meta != null && meta.webDomains.isNotEmpty)
          ? meta.webDomains.first.domain
          : ((meta != null && meta.packageNames.isNotEmpty)
                ? meta.packageNames.first
                : '');

      final remembered = KeyNestPendingLoginMemory.instance.getRemembered(
        targetContext,
      );

      final matcher = CredentialMatcher.instance;
      final matchingEntries = <KdbxEntry>[];
      KdbxEntry? carryoverMatch;
      KdbxEntry? explicitlySelectedEntry;

      final openFiles = kdbxBloc.openedFilesKdbx;
      for (final file in openFiles) {
        for (final entry in file.body.rootGroup.getAllEntries()) {
          if (entry.isInRecycleBin()) {
            continue;
          }

          if (selectedEntryId != null && entry.uuid.uuid == selectedEntryId) {
            explicitlySelectedEntry = entry;
          }

          final allUrls = <String>[
            ...entry.autofillUrls.map((u) => u.toString()),
          ];
          final rawUrl = entry.getString(KdbxKeyCommon.URL)?.getText()?.trim();
          if (rawUrl != null &&
              rawUrl.isNotEmpty &&
              !allUrls.contains(rawUrl)) {
            allUrls.add(rawUrl);
          }

          if (remembered != null &&
              (entry.uuid.uuid == remembered.entryUuid ||
                  (entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '') ==
                      remembered.username)) {
            carryoverMatch = entry;
          }

          if (requests.isNotEmpty) {
            final quality = matcher.matchBest(requests, allUrls);
            if (quality == CredentialMatchQuality.host ||
                quality == CredentialMatchQuality.registrableDomain ||
                quality == CredentialMatchQuality.application) {
              matchingEntries.add(entry);
            }
          }
        }
      }

      _logger.info(
        'Autofill resume matches: count=${matchingEntries.length}, carryover=${carryoverMatch != null}, explicit=${explicitlySelectedEntry != null}, forcePicker=$forcePicker',
      );

      // Prioritize explicit selection, then carryover match, then single match
      final singleTarget =
          explicitlySelectedEntry ??
          carryoverMatch ??
          (matchingEntries.length == 1 ? matchingEntries.first : null);

      if (!forcePicker && singleTarget != null) {
        // Revalidate vault session before autofilling
        if (kdbxBloc.openedFilesKdbx.isEmpty) {
          _logger.warning('Vault not opened before autofill resume');
          if (context.mounted) {
            await Navigator.of(context).push(
              KeyNestAutofillSheet.route(kdbxBloc: kdbxBloc),
            );
          }
          return;
        }

        // If the credential belongs to an unrelated site, confirm with origin mismatch warning
        if (requests.isNotEmpty) {
          final allUrls = <String>[
            ...singleTarget.autofillUrls.map((u) => u.toString()),
          ];
          final rawUrl = singleTarget
              .getString(KdbxKeyCommon.URL)
              ?.getText()
              ?.trim();
          if (rawUrl != null &&
              rawUrl.isNotEmpty &&
              !allUrls.contains(rawUrl)) {
            allUrls.add(rawUrl);
          }
          final quality = matcher.matchBest(requests, allUrls);
          final isMatchingOrigin =
              quality == CredentialMatchQuality.host ||
              quality == CredentialMatchQuality.registrableDomain ||
              quality == CredentialMatchQuality.application;
          if (!isMatchingOrigin) {
            if (context.mounted) {
              final confirmed = await _confirmOriginMismatch(
                context,
                singleTarget,
                targetContext,
              );
              if (!confirmed) {
                return;
              }
            }
          }
        }

        final username =
            singleTarget.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
        final email =
            singleTarget.getString(KdbxKey('Email'))?.getText()?.trim() ?? '';
        final password =
            singleTarget.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
        final otp = EntryTotpHelper.getLiveTotpCode(singleTarget);

        if (targetContext.isNotEmpty) {
          KeyNestPendingLoginMemory.instance.remember(
            entryUuid: singleTarget.uuid.uuid,
            verifiedContext: targetContext,
            username: username.isNotEmpty ? username : email,
          );
          await AutofillService().rememberPendingLogin(
            entryId: singleTarget.uuid.uuid,
            verifiedContext: targetContext,
            username: username.isNotEmpty ? username : email,
          );
        }

        QuickUnlockStorage.touchSession();
        unawaited(AutofillService().touchActive());
        await AutofillService().resultWithDataset(
          id: singleTarget.uuid.uuid,
          label: singleTarget.label,
          username: username,
          email: email.isNotEmpty ? email : null,
          password: password,
          otp: otp,
        );
        _logger.info(
          'Auto-resumed selected/single match and returned to browser.',
        );
        return;
      }

      // Multiple matches or no automatic match:
      // Show clear credential picker sheet where accounts are identified
      if (context.mounted) {
        await Navigator.of(context).push(
          KeyNestAutofillSheet.route(kdbxBloc: kdbxBloc),
        );
      }
    } catch (e, stack) {
      _logger.warning('Failed to resume autofill', e, stack);
      if (context.mounted) {
        await Navigator.of(context).push(
          KeyNestAutofillSheet.route(kdbxBloc: kdbxBloc),
        );
      }
    }
  }
}
