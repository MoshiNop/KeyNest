import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:typed_data';

import 'package:autofill_service/autofill_service.dart';
import 'package:autofill_shared/credential_matcher.dart';
import 'package:biometric_storage/biometric_storage.dart';
import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:kdbx/kdbx.dart';
import 'package:keynest/autofill/autofill_identities.dart';
import 'package:keynest/autofill/autofill_mirror.dart';
import 'package:keynest/bloc/analytics.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_content.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx/file_source_web_none.dart'
    if (dart.library.js) 'package:keynest/bloc/kdbx/file_source_web.dart'
    if (dart.library.html) 'package:keynest/bloc/kdbx/file_source_web.dart'
    if (dart.library.js_interop) 'package:keynest/bloc/kdbx/file_source_web.dart';
import 'package:keynest/bloc/kdbx/storage_exception.dart';
import 'package:keynest/bloc/kdbx_argon2_ffi.dart'
    if (dart.library.js) 'package:keynest/bloc/kdbx_argon2_web.dart'
    if (dart.library.html) 'package:keynest/bloc/kdbx_argon2_web.dart'
    if (dart.library.js_interop) 'package:keynest/bloc/kdbx_argon2_web.dart';
import 'package:keynest/cloud_storage/cloud_storage_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/dropbox/dropbox_merge_engine.dart';
import 'package:keynest/cloud_storage/keynest_cloud_sync_manager.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/main.dart';
import 'package:keynest/services/key_file_store.dart';
import 'package:keynest/services/keynest_dynamic_icon_service.dart';
import 'package:keynest/services/keynest_pending_login_memory.dart';
import 'package:keynest/services/keynest_preferences_service.dart';
import 'package:keynest/services/security_service.dart';
import 'package:keynest/theme.dart';
import 'package:keynest/utils/base32utils.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/entry_totp_helper.dart';
import 'package:keynest/utils/key_file_handler.dart';
import 'package:keynest/utils/otpauth.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('kdbx_bloc');

class FileExistsException extends KdbxException {
  FileExistsException({
    required this.path,
  });

  final String path;

  @NonNls
  @override
  String toString() {
    return 'FileExistsException{path: $path}';
  }
}

class FileAlreadyOpenException extends KdbxException {
  FileAlreadyOpenException({
    required this.newFileSource,
    required this.newFile,
    required this.openFileSource,
    required this.openFile,
  }) : assert(newFile.body.rootGroup.uuid == openFile.body.rootGroup.uuid);

  FileSource newFileSource;
  KdbxFile newFile;
  FileSource openFileSource;
  KdbxFile openFile;

  @NonNls
  @override
  String toString() {
    final map = {
      'newFileSource': newFileSource.toString(),
      'openFileSource': openFileSource.toString(),
      'uuid': newFile.body.rootGroup.uuid,
      'databaseName': newFile.body.meta.databaseName.get(),
    };
    return 'FileAlreadyOpenException{$map}';
  }
}

class QuickUnlockStorage {
  QuickUnlockStorage({
    required this.cloudStorageBloc,
    required this.env,
    required this.analytics,
  });

  final CloudStorageBloc cloudStorageBloc;
  final Env env;
  final Analytics analytics;
  bool? _supported;

  static var debugForceNoBiometricSupport = false;

  /// should only be used if used in non interactive callbacks.
  bool? get supportsBiometricKeystoreAlready => _supported;

  Future<bool> supportsBiometricKeyStore({bool force = false}) async {
    if (KeyNestPlatform.isWeb || debugForceNoBiometricSupport) {
      return false;
    }
    if (!force && _supported != null) {
      return _supported!;
    }
    final canAuthenticate = await BiometricStorage().canAuthenticate();
    _logger.finer('supportBiometricKeyStore: $canAuthenticate');
    return _supported = (canAuthenticate == CanAuthenticateResponse.success);
  }

  Future<BiometricStorageFile>? _storageFileCached;

  @NonNls
  Future<BiometricStorageFile> _storageFile() => _storageFileCached ??=
      BiometricStorage().getStorage('${env.storageNamespace ?? ''}QuickUnlock');

  static Map<FileSource, Credentials>? _inMemorySessionCredentials;
  static DateTime? _lastActiveSessionTimestamp;

  static void cacheSessionCredentials(Map<FileSource, Credentials> creds) {
    if (creds.isNotEmpty) {
      _inMemorySessionCredentials = {
        ...?_inMemorySessionCredentials,
        ...creds,
      };
      _lastActiveSessionTimestamp = DateTime.now();
      if (KeyNestPlatform.isAndroid) {
        final tokenMap = <String, String>{};
        for (final entry in _inMemorySessionCredentials!.entries) {
          try {
            final hash = entry.value.getHash();
            tokenMap[entry.key.uuid] = base64.encode(hash);
          } catch (e) {
            _logger.warning(
              'Failed to get hash for credentials of ${entry.key.uuid}: $e',
            );
          }
        }
        if (tokenMap.isNotEmpty) {
          unawaited(AutofillService().cacheSessionTokens(tokenMap));
        }
      }
    }
  }

  static void touchSession() {
    if (_inMemorySessionCredentials != null) {
      _lastActiveSessionTimestamp = DateTime.now();
      if (KeyNestPlatform.isAndroid) {
        unawaited(AutofillService().touchActive());
      }
    }
  }

  static bool isSessionValid() {
    if (_inMemorySessionCredentials == null ||
        _inMemorySessionCredentials!.isEmpty) {
      return false;
    }
    final timeout = SecuritySettingsStore.instance.autoLockSeconds;
    if (timeout == 0) {
      return false;
    }
    if (timeout < 0) {
      return true;
    }
    final last = _lastActiveSessionTimestamp;
    if (last == null) {
      return false;
    }
    final elapsed = DateTime.now().difference(last).inSeconds;
    return elapsed < timeout;
  }

  static void clearSession() {
    _inMemorySessionCredentials = null;
    _lastActiveSessionTimestamp = null;
    if (KeyNestPlatform.isAndroid) {
      unawaited(AutofillService().clearSessionTokens());
      unawaited(AutofillService().clearCredentials());
    }
  }

  static Future<bool> restoreSessionFromNative(
    AppDataBloc appDataBloc,
    CloudStorageBloc cloudStorageBloc,
  ) async {
    if (!KeyNestPlatform.isAndroid) {
      return false;
    }
    if (isSessionValid()) {
      return true;
    }
    try {
      final tokens = await AutofillService().getSessionTokens();
      if (tokens == null || tokens.isEmpty) {
        return false;
      }
      final appData = await appDataBloc.store.load();
      final restored = <FileSource, Credentials>{};
      for (final entry in tokens.entries) {
        final file = appData.recentFileByUuid(entry.key);
        if (file != null) {
          restored[file.toFileSource(cloudStorageBloc)] = HashCredentials(
            base64.decode(entry.value),
          );
        }
      }
      if (restored.isNotEmpty) {
        _inMemorySessionCredentials = restored;
        _lastActiveSessionTimestamp = DateTime.now();
        return true;
      }
    } catch (e, stack) {
      _logger.warning(
        'Failed to restore session from native Android',
        e,
        stack,
      );
    }
    return false;
  }

  static final Map<String, String> _knownVaultHashes = {};

  Future<void> deleteQuickUnlock() async {
    _knownVaultHashes.clear();
    clearSession();
    if (KeyNestPlatform.isAndroid) {
      unawaited(AutofillService().clearCredentials());
    }
    if (KeyNestPlatform.isWeb) {
      return;
    }
    final storageFile = await _storageFile();
    await storageFile.delete();
    _storageFileCached = null;
  }

  Future<void> saveVaultCredential(
    FileSource fileSource,
    Credentials credentials,
  ) async {
    cacheSessionCredentials({fileSource: credentials});
    _knownVaultHashes[fileSource.uuid] = base64.encode(credentials.getHash());
    if (!(await supportsBiometricKeyStore())) {
      _logger.warning(
        'Biometric keystore not supported for saveVaultCredential',
      );
      return;
    }
    final storage = await _storageFile();
    try {
      await storage.write(json.encode(_knownVaultHashes));
    } catch (e, st) {
      _logger.severe(
        'Failed to write vault credential to biometric storage',
        e,
        st,
      );
      rethrow;
    }
  }

  Future<void> removeVaultCredential(String uuid) async {
    _knownVaultHashes.remove(uuid);
    if (_inMemorySessionCredentials != null) {
      _inMemorySessionCredentials!.removeWhere((k, _) => k.uuid == uuid);
      if (_inMemorySessionCredentials!.isEmpty) {
        clearSession();
      }
    }
    if (!(await supportsBiometricKeyStore())) {
      return;
    }
    try {
      final storage = await _storageFile();
      if (_knownVaultHashes.isEmpty) {
        _logger.fine(
          'No remaining vault credentials, deleting quick unlock storage.',
        );
        await storage.delete();
        _storageFileCached = null;
      } else {
        await storage.write(json.encode(_knownVaultHashes));
      }
    } catch (e, st) {
      _logger.warning('Failed to remove vault credential $uuid: $e', e, st);
    }
  }

  Future<void> updateQuickUnlockFile(
    Map<FileSource, Credentials> fileCredentials,
  ) async {
    if (fileCredentials.isEmpty) {
      clearSession();
    } else {
      cacheSessionCredentials(fileCredentials);
    }
    if (!(await supportsBiometricKeyStore())) {
      _logger.severe(
        'updateQuickUnlockFile must not be called when biometric store is not supported.',
      );
      return;
    }
    for (final entry in fileCredentials.entries) {
      _knownVaultHashes[entry.key.uuid] = base64.encode(entry.value.getHash());
    }
    _logger.fine('Getting storage file.');
    final storage = await _storageFile();
    _logger.fine(
      'got storage, writing credentials.'
      ' ${_knownVaultHashes.length}',
    );
    try {
      if (_knownVaultHashes.isEmpty) {
        _logger.fine('Deleting quick unlock.');
        await storage.delete();
        _storageFileCached = null;
      } else {
        await storage.write(json.encode(_knownVaultHashes));
      }
    } catch (e, stackTrace) {
      _logger.severe(
        'Error while writing quick unlock credentials.',
        e,
        stackTrace,
      );
      rethrow;
    } finally {
      _logger.finer('all done.');
    }
  }

  Future<Map<FileSource, Credentials>> loadQuickUnlockFile(
    AppDataBloc appDataBloc, {
    bool silentOnly = false,
  }) async {
    if (isSessionValid()) {
      touchSession();
      return Map.from(_inMemorySessionCredentials!);
    }
    if (silentOnly) {
      return {};
    }
    final appData = await appDataBloc.store.load();
    if (appData.previousFiles.isEmpty) {
      _logger.fine('No previous files in app data. Skipping quick unlock.');
      return {};
    }
    if (!(await supportsBiometricKeyStore())) {
      _logger.fine('Biometric store not supported. no quickunlock.');
      return {};
    }
    // Only attempt native biometric read if there is at least one enrolled vault in previousFiles
    // that actually exists on the filesystem / cloud storage.
    final enrolledFiles = appData.previousFiles
        .where((f) => f.biometricStoreName != null)
        .toList();
    if (enrolledFiles.isEmpty) {
      _logger.fine('No previous files have biometric quick unlock enrolled.');
      return {};
    }
    bool anyExists = false;
    for (final f in enrolledFiles) {
      if (await f.checkExists(cloudStorageBloc)) {
        anyExists = true;
        break;
      }
    }
    if (!anyExists) {
      _logger.fine(
        'None of the biometric-enrolled files currently exist on disk.',
      );
      return {};
    }

    final storage = await _storageFile();
    final jsonContent = await storage.read();
    if (jsonContent == null) {
      _logger.finer('No quick unlock available.');
      return {};
    }
    final map = json.decode(jsonContent) as Map<String, dynamic>;
    final entries = <MapEntry<FileSource, Credentials>>[];
    for (final entry in map.entries) {
      if (entry.value is String) {
        _knownVaultHashes[entry.key] = entry.value as String;
      }
      final file =
          appData.recentFileByUuid(entry.key) ??
          appData.previousFiles.firstWhereOrNull(
            (f) => f.sourcePath == entry.key,
          );
      if (file != null) {
        entries.add(
          MapEntry(
            file.toFileSource(cloudStorageBloc),
            HashCredentials(base64.decode(entry.value as String)),
          ),
        );
      }
    }
    final result = Map<FileSource, Credentials>.fromEntries(entries);
    if (result.isNotEmpty) {
      cacheSessionCredentials(result);
    }
    return result;
  }
}

/// response to [KdbxBloc.readKdbxFile] will either be an exception OR a file.
class ReadFileResponse {
  ReadFileResponse(this.file, this.exception, this.exceptionType);
  final KdbxFile? file;
  final Object? exception;
  final String? exceptionType;
}

class KdbxOpenedFile {
  KdbxOpenedFile({
    required this.fileSource,
    required this.openedFile,
    required this.kdbxFile,
    required this.kdbxFileContent,
  });

  final FileSource fileSource;
  final OpenedFile openedFile;
  final KdbxFile kdbxFile;

  /// The file content as the source last saw it: what [kdbxFile] was read
  /// from, and after that whatever the most recent save wrote.
  final FileContent kdbxFileContent;
}

class OpenedKdbxFiles {
  OpenedKdbxFiles(Map<FileSource, KdbxOpenedFile> files)
    : _files = Map.unmodifiable(files);
  final Map<FileSource, KdbxOpenedFile> _files;

  int get length => _files.length;
  bool get isEmpty => _files.isEmpty;
  bool get isNotEmpty => _files.isNotEmpty;

  KdbxOpenedFile? operator [](FileSource? fileSource) => _files[fileSource!];
  Iterable<MapEntry<FileSource, KdbxOpenedFile>> get entries => _files.entries;
  Iterable<KdbxOpenedFile> get values => _files.values;

  bool containsKey(FileSource file) => _files.containsKey(file);
}

/// Result information for [KdbxBloc.openFile] method calls.
class OpenFileResult {
  OpenFileResult({
    this.kdbxOpenedFile,
    this.fileContent,
    this.unlockStopwatch,
    this.loadStopwatch,
  });
  final KdbxOpenedFile? kdbxOpenedFile;
  final FileContent? fileContent;
  final Stopwatch? unlockStopwatch;
  final Stopwatch? loadStopwatch;
}

abstract class KdbxBlocDelegate {
  void conflictMerged(FileSource fileSource, KdbxFile file, MergeContext merge);
}

typedef OpenedFileUpdater = void Function(OpenedFileBuilder b);

class KdbxBloc {
  KdbxBloc({
    required this.env,
    required this.appDataBloc,
    required this.analytics,
    required this.cloudStorageBloc,
  }) : quickUnlockStorage = QuickUnlockStorage(
         cloudStorageBloc: cloudStorageBloc,
         env: env,
         analytics: analytics,
       ) {
    if (KeyNestPlatform.isWeb) {
      KdbxFormat.dartWebWorkaround = true;
    }
    _openedFiles
        .map(
          (value) => Map.fromEntries(
            value.entries.map(
              (entry) => MapEntry(entry.value.kdbxFile, entry.value),
            ),
          ),
        )
        .listen((data) => _openedFilesByKdbxFile = data);
    appDataBloc.store
        .load()
        .then((data) {
          KeyNestDynamicIconService.instance.networkFetchEnabled =
              data.fetchWebsiteIcons ??
              env.featureFetchWebsiteIconEnabledByDefault;
        })
        .catchError((_) {});
  }

  final Env env;
  final AppDataBloc appDataBloc;
  final Analytics analytics;
  final CloudStorageBloc cloudStorageBloc;
  final QuickUnlockStorage quickUnlockStorage;

  /// Keeps the databases opted into autofill readable by the credential
  /// provider extension. Inert on platforms without an app group container.
  late final autofillMirror = AutofillMirror(
    appGroupIdentifier: env.autofillAppGroupIdentifier,
  );
  late final autofillIdentities = AutofillIdentities();
  late final KdbxFormat kdbxFormat = KdbxFormat(FlutterArgon2());
  KdbxBlocDelegate? delegate;

  final _openedFiles = BehaviorSubject<OpenedKdbxFiles>.seeded(
    OpenedKdbxFiles({}),
  );
  late Map<KdbxFile, KdbxOpenedFile> _openedFilesByKdbxFile;
  final _openedFilesQuickUnlock = <FileSource>{};

  Iterable<MapEntry<FileSource, KdbxFile>> get openedFilesWithSources =>
      _openedFiles.value.entries.map(
        (entry) => MapEntry(entry.key, entry.value.kdbxFile),
      );

  OpenedKdbxFiles get openedFiles => _openedFiles.value;
  List<KdbxFile> get openedFilesKdbx =>
      _openedFiles.value.values.map((value) => value.kdbxFile).toList();
  ValueStream<OpenedKdbxFiles> get openedFilesChanged => _openedFiles.stream;

  int _activeSaveCount = 0;
  bool get isSaving => _activeSaveCount > 0;
  final List<Completer<void>> _activeSaveWaiters = [];

  /// Waits until all active in-progress save operations have completed.
  Future<void> waitForPendingSaves() async {
    if (_activeSaveCount <= 0) {
      return;
    }
    final completer = Completer<void>();
    _activeSaveWaiters.add(completer);
    await completer.future;
  }

  Future<int>? _quickUnlockCheckRunning;

  void dispose() {
    _autofillSyncDebounceTimer?.cancel();
    _autofillMirrorDebounceTimer?.cancel();
    _pendingAutofillMirrorSyncs.clear();
    _openedFiles.close();
  }

  Future<KdbxOpenedFile> updateOpenedFile(
    KdbxOpenedFile file,
    OpenedFileUpdater updater,
  ) async {
    final updatedFile = (file.openedFile.toBuilder()..update(updater)).build();
    final wasAutofillEnabled = file.openedFile.autofillEnabledOrDefault;
    final isAutofillEnabled = updatedFile.autofillEnabledOrDefault;
    if (wasAutofillEnabled && !isAutofillEnabled) {
      // opted out — take the copy and the cached key away again. What is
      // advertised is republished below, once the flag has actually landed.
      _pendingAutofillMirrorSyncs.remove(file.openedFile.uuid);
      if (_pendingAutofillMirrorSyncs.isEmpty) {
        _autofillMirrorDebounceTimer?.cancel();
        _autofillMirrorDebounceTimer = null;
      }
      await autofillMirror.removeFile(file.openedFile.uuid);
    } else if (!wasAutofillEnabled && isAutofillEnabled) {
      // Opted in while the file is already open. The mirror is otherwise only
      // written on open and after save, so without this the extension would
      // find nothing until the user next did one of those — having just been
      // told autofill is on.
      //
      // kdbxFileContent is what the file was read from, which is what the
      // mirror needs: re-serializing would rotate the kdf salt and stand the
      // cached key up against a vault it can no longer open.
      await _mirrorFile(
        updatedFile,
        file.kdbxFile,
        file.kdbxFileContent.content,
      );
    }
    await appDataBloc.update((b, data) {
      b.previousFiles.map((f) {
        if (!f.isSameFileAs(file.openedFile)) {
          return f;
        }
        return updatedFile;
      });
    });
    final newFile = KdbxOpenedFile(
      fileSource: file.fileSource,
      openedFile: updatedFile,
      kdbxFile: file.kdbxFile,
      kdbxFileContent: file.kdbxFileContent,
    );
    _openedFiles.add(
      OpenedKdbxFiles({
        ..._openedFiles.value._files,
        file.fileSource: newFile,
      }),
    );
    if (wasAutofillEnabled != isAutofillEnabled) {
      // Only now, after the stream carries the new flag. What gets advertised
      // is derived from _openedFiles, so publishing from the branches above
      // announced precisely the state the user had just left — switching
      // autofill on published nothing, and switching it off published
      // everything.
      await _publishAutofillIdentities();
    }
    _logger.info('new values: ${_openedFiles.value}');
    return newFile;
  }

  Stream<OpenFileResult> openFile(
    FileSource file,
    Credentials credentials, {
    bool addToQuickUnlock = false,
  }) async* {
    Uint8List? previous;
    late KdbxOpenedFile openedFile;
    await for (final fileContent in file.content()) {
      _logger.finer('$file got from ${fileContent.source}');
      final loadStopwatch = Stopwatch()..start();
      if (previous != null) {
        if (ByteUtils.eq(previous, fileContent.content)) {
          _logger.finer('$file: No changes detected. Nothing to do.');
          continue;
        } else {
          if (openedFile.kdbxFile.isDirty) {
            throw StateError(
              'File was changed locally while '
              'loading new file from remote storage.',
            );
          }
        }
      }
      previous = fileContent.content;
      loadStopwatch.stop();
      final unlockStopwatch = Stopwatch()..start();
      openedFile = await _openFileContent(
        file,
        credentials,
        fileContent,
        addToQuickUnlock,
      );
      addToQuickUnlock = false;

      yield OpenFileResult(
        kdbxOpenedFile: openedFile,
        fileContent: fileContent,
        unlockStopwatch: unlockStopwatch..stop(),
        loadStopwatch: loadStopwatch,
      );
    }
    _logger.finer('$file: Done.');
  }

  Future<KdbxOpenedFile> _openFileContent(
    FileSource file,
    Credentials credentials,
    FileContent fileContent,
    bool addToQuickUnlock,
  ) async {
    final readArgs = KdbxReadArgs(fileContent.content, credentials);
    final kdbxReadFile = await readKdbxFile(kdbxFormat, readArgs);
    final kdbxReadFileException = kdbxReadFile.exception;
    if (kdbxReadFileException != null) {
      final mapping = <Type, Object Function()>{
        KdbxInvalidKeyException: () => KdbxInvalidKeyException(),
        KdbxCorruptedFileException: () => KdbxCorruptedFileException(''),
        KdbxInvalidFileStructure: () =>
            KdbxInvalidFileStructure(kdbxReadFile.exception?.toString() ?? ''),
      }.map((key, value) => MapEntry(key.toString(), value));
      final exception = mapping[kdbxReadFile.exceptionType!];
      if (exception != null) {
        throw exception();
      }
      throw kdbxReadFileException;
    }
    final kdbxFile = kdbxReadFile.file!;

    // make sure kdbxFile is not already opened with another FileSource.
    final openedUuid = kdbxFile.body.rootGroup.uuid;
    for (final openedFile in _openedFiles.value.values) {
      if (openedFile.kdbxFile.body.rootGroup.uuid == openedUuid &&
          openedFile.fileSource != file) {
        throw FileAlreadyOpenException(
          newFileSource: file,
          newFile: kdbxFile,
          openFileSource: openedFile.fileSource,
          openFile: openedFile.kdbxFile,
        );
      }
    }

    final resolvedVaultName = () {
      final nameFromPath = file.displayName;
      if (nameFromPath.isNotEmpty &&
          nameFromPath != 'Vault' &&
          nameFromPath.toLowerCase() != 'vault') {
        return nameFromPath;
      }
      final metaName = kdbxFile.body.meta.databaseName.get()?.trim();
      if (metaName != null && metaName.isNotEmpty) {
        final cleanMeta = FileSource.cleanDisplayName(metaName);
        if (cleanMeta.isNotEmpty &&
            cleanMeta != 'Vault' &&
            cleanMeta.toLowerCase() != 'vault') {
          return cleanMeta;
        }
      }
      final rootName = kdbxFile.body.rootGroup.name.get()?.trim();
      if (rootName != null && rootName.isNotEmpty) {
        final cleanRoot = FileSource.cleanDisplayName(rootName);
        if (cleanRoot.isNotEmpty &&
            cleanRoot != 'Vault' &&
            cleanRoot.toLowerCase() != 'vault') {
          return cleanRoot;
        }
      }
      return nameFromPath.isNotEmpty ? nameFromPath : 'Vault';
    }();

    final openedFile = await appDataBloc.openedFile(
      file,
      name: resolvedVaultName,
      defaultColor: _defaultNextColor(),
      biometricStoreName: addToQuickUnlock ? file.uuid : null,
    );
    final kdbxOpenedFile = KdbxOpenedFile(
      fileSource: file,
      openedFile: openedFile,
      kdbxFile: kdbxFile,
      kdbxFileContent: fileContent,
    );
    _openedFiles.add(
      OpenedKdbxFiles({
        ..._openedFiles.value._files,
        file: kdbxOpenedFile,
      }),
    );
    analytics.events.trackOpenFile(type: file.typeDebug);
    analytics.events.trackOpenFile2(
      generator: kdbxFile.body.meta.generator.get() ?? 'NULL',
      version: '${kdbxFile.header.version}',
    );

    QuickUnlockStorage.cacheSessionCredentials({
      for (final opened in _openedFiles.value.values)
        opened.fileSource: opened.kdbxFile.credentials,
    });

    if (addToQuickUnlock) {
      _openedFilesQuickUnlock.add(file);
      _logger.fine('adding file to quick unlock.');
      try {
        await quickUnlockStorage.saveVaultCredential(
          file,
          kdbxFile.credentials,
        );
      } catch (e, st) {
        _openedFilesQuickUnlock.remove(file);
        _logger.warning('Failed to persist quick unlock credentials', e, st);
      }
    }
    await _syncAutofillMirror(kdbxOpenedFile, fileContent.content);
    return kdbxOpenedFile;
  }

  /// Refreshes (or removes) this database's copy in the app group container.
  ///
  /// [bytes] must be the content that was actually read from or written to the
  /// file source. Re-serializing here would rotate the kdf salt again and
  /// strand the key we are about to cache.
  ///
  /// Never rethrows: autofill is a convenience, and failing to mirror must not
  /// fail the open or the save that triggered it.
  /// Writes the copy and the cached key, without asking whether it should.
  Future<void> _mirrorFile(
    OpenedFile openedFile,
    KdbxFile kdbxFile,
    Uint8List bytes,
  ) async {
    try {
      await autofillMirror.syncFile(
        fileUuid: openedFile.uuid,
        name: openedFile.name,
        file: kdbxFile,
        bytes: bytes,
      );
    } catch (e, stackTrace) {
      _logger.warning('Unable to update the autofill mirror.', e, stackTrace);
    }
  }

  Future<void> _syncAutofillMirror(
    KdbxOpenedFile file,
    Uint8List bytes,
  ) async {
    if (KeyNestPlatform.isWeb || !file.openedFile.autofillEnabledOrDefault) {
      return;
    }
    await _mirrorFile(file.openedFile, file.kdbxFile, bytes);
    await _publishAutofillIdentities();
    await _syncAndroidAutofillStore(immediate: false);
  }

  /// Advertises every entry of every enabled vault to iOS.
  ///
  /// Republished as a whole set rather than incrementally, because this is the
  /// only place that knows which vaults are currently enabled — and an entry
  /// that was deleted, or a vault that was switched off, has to stop being
  /// offered. Cheap: names and usernames only, no decryption beyond what is
  /// already in memory.
  /// Only what the mirror actually holds is advertised. Being enabled and open
  /// is not enough — mirroring can fail, quietly and by design, and a
  /// suggestion for a vault the extension has no copy of goes nowhere when the
  /// user taps it. The manifest is the extension's own view, so intersecting
  /// with it is what keeps the two stores from disagreeing.
  Future<void> _publishAutofillIdentities() async {
    final mirrored = (await autofillMirror.readManifest()).entries
        .map((e) => e.fileUuid)
        .toSet();
    final enabled = <String, KdbxFile>{
      for (final file in _openedFiles.value.values)
        if (file.openedFile.autofillEnabledOrDefault &&
            mirrored.contains(file.openedFile.uuid))
          file.openedFile.uuid: file.kdbxFile,
    };
    await autofillIdentities.publish(enabled);
  }

  /// Synchronizes unlocked credentials with Android native AutofillCredentialStore
  /// to enable immediate 1-tap autofill suggestions without visible auth sheets.
  Future<void> syncAndroidAutofillStore({bool immediate = false}) =>
      _syncAndroidAutofillStore(immediate: immediate);

  Timer? _autofillSyncDebounceTimer;
  Timer? _autofillMirrorDebounceTimer;
  final Map<String, ({KdbxOpenedFile file, Uint8List bytes})>
  _pendingAutofillMirrorSyncs = {};

  /// Whether there is a pending debounced autofill mirror sync.
  bool get hasPendingAutofillMirrorSync =>
      _autofillMirrorDebounceTimer != null ||
      _pendingAutofillMirrorSyncs.isNotEmpty;

  /// Flushes any pending debounced autofill mirror sync immediately.
  Future<void> flushPendingAutofillMirror() =>
      _flushPendingAutofillMirrorSyncs();

  Future<void> _flushPendingAutofillMirrorSyncs() async {
    _autofillMirrorDebounceTimer?.cancel();
    _autofillMirrorDebounceTimer = null;
    if (_pendingAutofillMirrorSyncs.isEmpty) {
      return;
    }
    final pending = Map<String, ({KdbxOpenedFile file, Uint8List bytes})>.from(
      _pendingAutofillMirrorSyncs,
    );
    _pendingAutofillMirrorSyncs.clear();

    for (final entry in pending.values) {
      final currentOpen = _openedFilesByKdbxFile[entry.file.kdbxFile];
      if (currentOpen != null &&
          currentOpen.openedFile.autofillEnabledOrDefault) {
        await _syncAutofillMirror(currentOpen, entry.bytes);
      }
    }
  }

  Future<void> _syncAndroidAutofillStore({bool immediate = false}) async {
    if (!KeyNestPlatform.isAndroid) {
      return;
    }
    _autofillSyncDebounceTimer?.cancel();
    if (immediate) {
      await _executeAndroidAutofillSync();
    } else {
      _autofillSyncDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        _executeAndroidAutofillSync();
      });
    }
  }

  Future<void> _executeAndroidAutofillSync() async {
    final openFiles = openedFilesKdbx;
    if (openFiles.isEmpty) {
      await AutofillService().clearCredentials();
      return;
    }

    final missingDomainsToFetch = <String>{};
    final syncEntries = <AutofillSyncEntry>[];
    for (final file in openFiles) {
      for (final entry in file.body.rootGroup.getAllEntries()) {
        if (entry.isInRecycleBin()) {
          continue;
        }
        final username =
            entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '';
        final email =
            entry.getString(KdbxKey('Email'))?.getText()?.trim() ?? '';
        final password =
            entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
        final urls = entry.autofillUrls.map((u) => u.toString()).toList();
        final rawUrl = entry.getString(KdbxKeyCommon.URL)?.getText();
        if (rawUrl != null && rawUrl.isNotEmpty && !urls.contains(rawUrl)) {
          urls.add(rawUrl);
        }

        final packageNames = <String>[];
        final registrableDomains = <String>{};
        for (final u in urls) {
          final trimmedUrl = u.trim();
          if (trimmedUrl.startsWith('androidapp://')) {
            final pkg = trimmedUrl
                .replaceFirst('androidapp://', '')
                .trim()
                .toLowerCase();
            if (pkg.isNotEmpty && !CredentialMatcher.isBrowserPackage(pkg)) {
              packageNames.add(pkg);
            }
          } else {
            final domain = CredentialMatcher.instance.registrableDomain(
              trimmedUrl,
            );
            if (domain != null && domain.isNotEmpty) {
              registrableDomains.add(domain.toLowerCase());
            }
          }
        }

        final otpAuth = EntryTotpHelper.getOtpAuth(entry);
        final liveOtp = EntryTotpHelper.getLiveTotpCode(entry);
        final otpSecret = otpAuth != null ? base32Encode(otpAuth.secret) : null;
        final otpAlgorithm = otpAuth != null
            ? OtpAuth.algorithms[otpAuth.algorithm]
            : null;
        final otpPeriod = otpAuth?.period;
        final otpDigits = otpAuth?.digits;
        final hasTotp = otpAuth != null;

        Uint8List? iconBytes = entry.customIcon?.data;
        if (iconBytes == null || iconBytes.isEmpty) {
          final candidateDomains = <String>[...urls];
          final raw = entry.getString(KdbxKeyCommon.URL)?.getText()?.trim();
          if (raw != null &&
              raw.isNotEmpty &&
              !candidateDomains.contains(raw)) {
            candidateDomains.add(raw);
          }
          final title = entry.getString(KdbxKeyCommon.TITLE)?.getText()?.trim();
          if (title != null &&
              title.isNotEmpty &&
              !candidateDomains.contains(title)) {
            candidateDomains.add(title);
          }
          final label = entry.label?.trim();
          if (label != null &&
              label.isNotEmpty &&
              !candidateDomains.contains(label)) {
            candidateDomains.add(label);
          }

          // 1. Fast in-memory / local disk cache check (non-blocking)
          for (final u in candidateDomains) {
            iconBytes = KeyNestDynamicIconService.instance.getCachedIconSync(u);
            if (iconBytes != null && iconBytes.isNotEmpty) {
              break;
            }
          }

          // 3. If uncached, queue domain for background non-blocking fetch only if website icon fetching is enabled
          final appData = appDataBloc.store.cachedValue;
          final isIconFetchEnabled =
              appData?.fetchWebsiteIcons ??
              env.featureFetchWebsiteIconEnabledByDefault;
          if (isIconFetchEnabled &&
              KeyNestDynamicIconService.instance.networkFetchEnabled &&
              (iconBytes == null || iconBytes.isEmpty) &&
              candidateDomains.isNotEmpty) {
            for (final u in candidateDomains) {
              final domain = KeyNestDynamicIconService.extractDomain(u);
              if (domain != null && domain.isNotEmpty) {
                missingDomainsToFetch.add(domain);
                break;
              }
            }
          }
        }

        syncEntries.add(
          AutofillSyncEntry(
            id: entry.uuid.uuid,
            label: entry.label ?? 'KeyNest',
            username: username,
            email: email.isNotEmpty ? email : null,
            password: password,
            urls: urls,
            packageNames: packageNames,
            registrableDomains: registrableDomains.toList(),
            otp: liveOtp,
            otpSecret: otpSecret,
            otpAlgorithm: otpAlgorithm,
            otpPeriod: otpPeriod,
            otpDigits: otpDigits,
            hasTotp: hasTotp,
            icon: iconBytes,
            requireReprompt: false,
            lastUsed:
                entry.times.lastAccessTime.get()?.millisecondsSinceEpoch ?? 0,
          ),
        );
      }
    }

    final autoLockSec = SecuritySettingsStore.instance.autoLockSeconds;
    try {
      await AutofillService().syncCredentials(
        syncEntries,
        autoLockSeconds: autoLockSec,
      );
      _logger.fine(
        'Synchronized ${syncEntries.length} entries to Android AutofillService (autoLockSec=$autoLockSec)',
      );
    } catch (e, stack) {
      _logger.warning(
        'Failed to sync credentials to Android AutofillService',
        e,
        stack,
      );
    }

    // Schedule background icon fetch for missing domains without blocking unlock
    if (missingDomainsToFetch.isNotEmpty &&
        KeyNestDynamicIconService.instance.networkFetchEnabled) {
      unawaited(() async {
        var anyNewIcon = false;
        for (final domain in missingDomainsToFetch) {
          if (!KeyNestDynamicIconService.instance.networkFetchEnabled) {
            break;
          }
          try {
            final fetched = await KeyNestDynamicIconService.instance
                .getOrFetchIcon(
                  domain,
                  timeout: const Duration(seconds: 3),
                );
            if (fetched != null && fetched.isNotEmpty) {
              anyNewIcon = true;
            }
          } catch (_) {}
        }
        if (anyNewIcon) {
          unawaited(_syncAndroidAutofillStore());
        }
      }());
    }
  }

  /// Records what the save put on disk, and refreshes the autofill mirror.
  ///
  /// Every save rotates the kdf salt, so the mirrored copy and its cached key
  /// both have to be replaced or the extension is left holding a stale key.
  ///
  /// [savedContent] then replaces [KdbxOpenedFile.kdbxFileContent], which
  /// otherwise keeps the bytes the file was *opened* with for as long as it
  /// stays open. Two things go wrong when it does. [reload] compares fresh
  /// origin content against it, so after any save it decides the file changed
  /// and merges against itself. And the autofill opt-in path mirrors it
  /// verbatim — handing the extension pre-save bytes whose kdf salt the key
  /// cached alongside them no longer matches, so the copy cannot be opened.
  Future<void> _syncAutofillMirrorAfterSave(
    KdbxFile file,
    Uint8List? writtenBytes,
    FileContent? savedContent, {
    bool immediate = false,
  }) async {
    var openedFile = _openedFilesByKdbxFile[file];
    if (openedFile == null) {
      return;
    }
    if (savedContent != null) {
      openedFile = KdbxOpenedFile(
        fileSource: openedFile.fileSource,
        openedFile: openedFile.openedFile,
        kdbxFile: openedFile.kdbxFile,
        kdbxFileContent: savedContent,
      );
      _openedFiles.add(
        OpenedKdbxFiles({
          ..._openedFiles.value._files,
          openedFile.fileSource: openedFile,
        }),
      );
    }
    if (writtenBytes == null) {
      return;
    }
    if (immediate) {
      _autofillMirrorDebounceTimer?.cancel();
      _autofillMirrorDebounceTimer = null;
      _pendingAutofillMirrorSyncs.remove(openedFile.openedFile.uuid);
      await _syncAutofillMirror(openedFile, writtenBytes);
    } else {
      _pendingAutofillMirrorSyncs[openedFile.openedFile.uuid] = (
        file: openedFile,
        bytes: writtenBytes,
      );
      _autofillMirrorDebounceTimer?.cancel();
      _autofillMirrorDebounceTimer = Timer(
        const Duration(milliseconds: 500),
        () {
          unawaited(_flushPendingAutofillMirrorSyncs());
        },
      );
    }
  }

  Color? _defaultNextColor() {
    for (final color in KeyNestTheme.defaultColorOrder) {
      if (!openedFiles.values.any(
        (file) => file.openedFile.colorCode == color.toARGB32(),
      )) {
        return color;
      }
    }
    return null;
  }

  /// writes all opened files into secure storage.
  Future<void> _updateQuickUnlockStore({FileSource? ifRequiredFor}) async {
    if (ifRequiredFor != null) {
      if (!_openedFilesQuickUnlock.any((s) => s.uuid == ifRequiredFor.uuid)) {
        return;
      }
    }
    final openedFiles = _openedFiles.value;
    final entries = <FileSource, Credentials>{};
    for (final fileSource in _openedFilesQuickUnlock) {
      final openedFile =
          openedFiles[fileSource] ??
          openedFiles.values.firstWhereOrNull(
            (f) => f.fileSource.uuid == fileSource.uuid,
          );
      if (openedFile == null) {
        _logger.warning(
          'File was closed, but was still listed in quick unlock files: ${fileSource.uuid}',
        );
        continue;
      }
      entries[openedFile.fileSource] = openedFile.kdbxFile.credentials;
    }
    await quickUnlockStorage.updateQuickUnlockFile(entries);
  }

  bool _isOpen(FileSource file) => _openedFiles.value.containsKey(file);

  Future<void> continueLoadInBackground(
    StreamIterator<OpenFileResult> openIt, {
    @NonNls required String debugName,
    required FileSource fileSource,
  }) async {
    try {
      while (await openIt.moveNext()) {
        final r = openIt.current;
        _logger.fine('load:$debugName new data from ${r.fileContent!.source}');
      }
    } catch (e, stackTrace) {
      _logger.severe(
        'load:$debugName error while loading subsequent '
        'data from $fileSource.',
        e,
        stackTrace,
      );
      rethrow;
    }
    _logger.fine('load:$debugName finished.');
  }

  bool hasQuickUnlockOpen() => _openedFilesQuickUnlock.isNotEmpty;

  Future<void> deleteQuickUnlock() => quickUnlockStorage.deleteQuickUnlock();

  bool canSilentQuickUnlock() => QuickUnlockStorage.isSessionValid();

  Future<bool> trySilentRestoreAndUnlock([AppLocalizations? loc]) async {
    final appData = await appDataBloc.store.load();
    if (appData.previousFiles.isEmpty) {
      return false;
    }
    final restored = await QuickUnlockStorage.restoreSessionFromNative(
      appDataBloc,
      cloudStorageBloc,
    );
    if (!restored && !canSilentQuickUnlock()) {
      return false;
    }
    try {
      final opened = await reopenQuickUnlock(
        loc,
        null,
        true,
      );
      if (opened > 0 || openedFilesKdbx.isNotEmpty) {
        await syncAndroidAutofillStore(immediate: true);
        return true;
      }
      return false;
    } catch (e) {
      _logger.warning('Failed silent restore and unlock: $e');
      return false;
    }
  }

  Future<int> reopenQuickUnlock(
    AppLocalizations? loc, [
    TaskProgress? progress,
    bool silentOnly = false,
  ]) => _quickUnlockCheckRunning ??= (() async {
    try {
      final appData = await appDataBloc.store.load();
      if (appData.previousFiles.isEmpty) {
        _logger.fine(
          'No previous files in app data. Skipping quick unlock check.',
        );
        return 0;
      }
      _logger.finer('Checking quick unlock.');
      final unlockFiles = await quickUnlockStorage.loadQuickUnlockFile(
        appDataBloc,
        silentOnly: silentOnly,
      );
      var filesOpened = 0;
      for (final file in unlockFiles.entries.where(
        (entry) => !_isOpen(entry.key),
      )) {
        try {
          if (loc != null) {
            progress?.progressLabel = loc.openFileProgress(
              file.key.displayName,
              filesOpened + 1,
              unlockFiles.length,
            );
          }
          final open = StreamIterator(
            openFile(file.key, file.value, addToQuickUnlock: false),
          );
          await open.moveNext();
          filesOpened++;
          _openedFilesQuickUnlock.add(file.key);
          unawaited(
            continueLoadInBackground(
              open,
              debugName:
                  '${file.key.displayName} … (${filesOpened + 1} / ${unlockFiles.length})',
              fileSource: file.key,
            ),
          );
        } catch (e, stackTrace) {
          _logger.severe(
            'Panic, error while trying to open file from '
            'quick unlock. ignoring file for now. ${file.key}',
            e,
            stackTrace,
          );
        }
      }
      analytics.events.trackQuickUnlock(value: filesOpened);
      _openedFilesQuickUnlock.clear();
      _openedFilesQuickUnlock.addAll(unlockFiles.keys);
      return filesOpened;
    } catch (e, stackTrace) {
      if (e is AuthException && e.code == AuthExceptionCode.userCanceled) {
        _logger.info('User canceled quick unlock.');
        return 0;
      }
      _logger.severe('Error during quick unlock.', e, stackTrace);
      return 0;
    }
  })().whenComplete(() => _quickUnlockCheckRunning = null);

  Future<void> close(KdbxFile file) async {
    _logger.fine('Close file.');
    analytics.events.trackCloseFile();
    final openedFile = fileForKdbxFile(file);
    final fileSource = openedFile.fileSource;
    _pendingAutofillMirrorSyncs.remove(openedFile.openedFile.uuid);
    if (_pendingAutofillMirrorSyncs.isEmpty) {
      _autofillMirrorDebounceTimer?.cancel();
      _autofillMirrorDebounceTimer = null;
    }
    _openedFiles.add(
      OpenedKdbxFiles(Map.from(_openedFiles.value._files)..remove(fileSource)),
    );
    file.dispose();
    // Closing a database stops it being offered. The mirror outlives the app,
    // so nothing else would ever take it away, and a database the user closed
    // going on answering autofill requests is not what closing looks like.
    await autofillMirror.removeFile(openedFile.openedFile.uuid);
    await _publishAutofillIdentities();
    await _syncAndroidAutofillStore(immediate: true);
    if (_openedFilesQuickUnlock.remove(fileSource)) {
      _logger.fine('file was in quick unlock.');
    } else {
      _logger.fine('file was not in quick unlock.');
    }
    if (_openedFiles.value.isEmpty) {
      QuickUnlockStorage.clearSession();
    } else {
      QuickUnlockStorage.cacheSessionCredentials({
        for (final opened in _openedFiles.value.values)
          opened.fileSource: opened.kdbxFile.credentials,
      });
    }
  }

  /// Replaces an active vault's backing [FileSource] safely without closing the in-memory KDBX file.
  Future<void> replaceFileSource(
    FileSource oldSource,
    FileSource newSource,
  ) async {
    final currentOpened = _openedFiles.value;
    final opened = currentOpened[oldSource];
    if (opened == null) {
      return;
    }

    final updatedOpenedFile = KdbxOpenedFile(
      fileSource: newSource,
      kdbxFile: opened.kdbxFile,
      openedFile: opened.openedFile,
      kdbxFileContent: newSource.lastContent ?? opened.kdbxFileContent,
    );

    final newFiles = Map<FileSource, KdbxOpenedFile>.from(currentOpened._files);
    newFiles.remove(oldSource);
    newFiles[newSource] = updatedOpenedFile;

    _openedFiles.add(OpenedKdbxFiles(newFiles));
    _openedFilesByKdbxFile[opened.kdbxFile] = updatedOpenedFile;

    if (_openedFilesQuickUnlock.remove(oldSource)) {
      _openedFilesQuickUnlock.add(newSource);
    }

    // Persist new path and identifier to AppDataBloc
    await appDataBloc.update((b, data) {
      final newOpened = OpenedFile.fromFileSource(
        newSource,
        newSource.databaseName,
        (builder) {
          builder.colorCode = opened.openedFile.colorCode;
          builder.biometricStoreName = opened.openedFile.biometricStoreName;
          builder.autofillEnabled = opened.openedFile.autofillEnabled;
        },
      );
      b.previousFiles.removeWhere((f) => f.uuid == oldSource.uuid);
      b.previousFiles.add(newOpened);
    });

    try {
      KeyNestVaultScope.instance.notifyScopeChanged();
    } catch (_) {}
  }

  Future<void> closeAllFiles({required bool clearQuickUnlock}) async {
    _logger.finer('Closing all files, clearing quick unlock.');
    if (!clearQuickUnlock && _pendingAutofillMirrorSyncs.isNotEmpty) {
      await flushPendingAutofillMirror();
    } else {
      _autofillMirrorDebounceTimer?.cancel();
      _autofillMirrorDebounceTimer = null;
      _pendingAutofillMirrorSyncs.clear();
    }
    for (final file in _openedFiles.value.values) {
      file.kdbxFile.dispose();
    }
    QuickUnlockStorage.clearSession();
    KeyNestClipboard.clearNow();
    if (clearQuickUnlock) {
      // clear all quick unlock data.
      _openedFilesQuickUnlock.clear();
      await quickUnlockStorage.updateQuickUnlockFile({});
      // The autofill mirror keeps exactly the same company as quick unlock:
      // both are a cached way in that outlives the app, so "close everything
      // and forget how to get back in" has to mean both or it means neither.
      // Locking, which keeps quick unlock, keeps the mirror for the same
      // reason — autofill working while the app is locked is the point of it.
      await autofillMirror.clear();
      await autofillIdentities.publish({});
      analytics.events.trackCloseAllFiles(count: _openedFiles.value.length);
    } else {
      analytics.events.trackLockAllFiles(count: _openedFiles.value.length);
    }
    _openedFiles.add(OpenedKdbxFiles({}));
    KeyNestPendingLoginMemory.instance.clear();
    await AutofillService().clearCredentials();
    await AutofillService().clearPendingSaveRequest();
  }

  static Future<ReadFileResponse> staticReadKdbxFile(
    KdbxReadArgs readArgs,
  ) async {
    initIsolate();
    final kdbxFormat = KdbxFormat(FlutterArgon2());
    return readKdbxFile(kdbxFormat, readArgs);
  }

  static Future<ReadFileResponse> readKdbxFile(
    KdbxFormat kdbxFormat,
    KdbxReadArgs readArgs,
  ) async {
    try {
      _logger.finer('reading kdbx file ...');
      final fileContent = readArgs.content;
      final kdbxFile = await kdbxFormat.read(fileContent, readArgs.credentials);
      _logger.finer('done reading');
      return ReadFileResponse(kdbxFile, null, null);
    } catch (e, stackTrace) {
      _logger.warning('Error while reading kdbx file.', e, stackTrace);
      return ReadFileResponse(null, e.toString(), e.runtimeType.toString());
    }
  }

  /// Creates a new file in the application document directory by the given name.
  /// Throws a [FileExistsException] if a file of the same name already exists.
  Future<FileSource> createFile({
    required String password,
    required String databaseName,
    Uint8List? keyFileBytes,
    bool openAfterCreate = false,
    CloudStorageSaveTarget? target,
    FileSource? customFileSource,
    bool addToQuickUnlock = false,
  }) async {
    analytics.events.trackCreateFile();
    assert(!(databaseName.endsWith(AppConstants.kdbxExtension)));
    final Credentials credentials;
    if (keyFileBytes != null && keyFileBytes.isNotEmpty) {
      final keyResult = KeyNestKeyFile.parse(keyFileBytes);
      credentials = KeyFileComposite(
        password: password.isNotEmpty
            ? PasswordCredentials(ProtectedValue.fromString(password))
            : null,
        keyFile: KeyFileCredentials.fromBytes(keyResult.keyBytes),
      );
    } else {
      credentials = Credentials(ProtectedValue.fromString(password));
    }
    final kdbxFile = kdbxFormat.create(
      credentials,
      databaseName,
      generator: Env.KeyNest,
    );
    final bytes = await _saveFileToBytes<Uint8List>(
      kdbxFile,
      (bytes) async => bytes,
    );
    FileSource fileSource;
    if (customFileSource != null) {
      await customFileSource.contentWrite(bytes, metadata: <String, dynamic>{});
      fileSource = customFileSource;
    } else if (target == null) {
      final localSource = await _localFileSourceForDbName(databaseName);
      await localSource.contentWrite(bytes, metadata: <String, dynamic>{});
      fileSource = localSource;
    } else {
      final entity = await target.provider.createEntity(
        CloudStorageSelectorSaveResult(
          target.parent,
          _fileNameForDbName(databaseName),
        ),
        bytes,
      );
      fileSource = entity;
    }
    if (openAfterCreate) {
      final opened = await openFile(
        fileSource,
        credentials,
        addToQuickUnlock: addToQuickUnlock,
      ).last;
      final kdbx = opened.kdbxOpenedFile?.kdbxFile;
      if (kdbx != null) {
        try {
          unawaited(
            KeyNestCloudSyncManager.instance.markVaultDirty(fileSource.uuid),
          );
          KeyNestCloudSyncManager.instance.schedulePostSaveSync(
            kdbxFile: kdbx,
            kdbxBloc: this,
          );
        } catch (_) {}
      }
    }
    return fileSource;
  }

  /// Public accessor to serialize a [KdbxFile] to raw bytes.
  Future<T> saveFileToBytes<T>(
    KdbxFile file,
    FileSaveCallback<T> saveBytes,
  ) => _saveFileToBytes<T>(file, saveBytes);

  String _fileNameForDbName(String databaseName) =>
      [databaseName, AppConstants.kdbxExtension].join();

  Future<FileSource> _localFileSourceForDbName(String databaseName) async {
    if (KeyNestPlatform.isWeb) {
      _logger.finer('in web mode - using FileSourceWeb.');
      return FileSourceWeb(
        databaseName: databaseName,
        uuid: AppDataBloc.createUuid(),
      );
    }
    final fileName = _fileNameForDbName(databaseName);
    final appDir = await PathUtils().getAppDocDirectory(ensureCreated: true);
    final localSource = FileSourceLocal(
      appDir.childFile(fileName),
      databaseName: databaseName,
      uuid: AppDataBloc.createUuid(),
    );
    if (localSource.file.existsSync()) {
      throw FileExistsException(path: localSource.file.path);
    }
    return localSource;
  }

  /// Creates a new password entry in [file] (default: the primary kdbx file),
  /// and adds it to [group] (default: main root group).
  KdbxEntry createEntry({
    KdbxFile? file,
    KdbxGroup? group,
  }) {
    file ??= group?.file;
    if (file == null) {
      if (openedFilesKdbx.isEmpty) {
        return throw StateError('No kdbxfiles are open. Specify a file.');
      }
      file = openedFilesKdbx.first;
    }
    final rootGroup = group ?? file.body.rootGroup;
    final entry = KdbxEntry.create(file, rootGroup);
    rootGroup.addEntry(entry);
    return entry;
  }

  @NonNls
  static const _customDataSaveCount = 'com.moshinop.keynest.save';

  /// Wrapper around [file.save()], which adds a bit of meta data
  /// before storing it.
  Future<T> _saveFileToBytes<T>(
    KdbxFile file,
    FileSaveCallback<T> saveBytes,
  ) async {
    _activeSaveCount++;
    try {
      final generator = file.body.meta.generator.get();
      if (generator == null || generator.isEmpty) {
        file.body.meta.generator.set(nonNls('KeyNest (save)'));
      }
      final String saveCounter =
          file.body.meta.customData[_customDataSaveCount] ?? nonNls('0');
      final newCounter = (int.tryParse(saveCounter) ?? 0) + 1;
      file.body.meta.customData[_customDataSaveCount] = newCounter.toString();
      analytics.events.trackSaveCount(generator: generator, value: newCounter);
      return await file.saveTo(saveBytes);
    } finally {
      _activeSaveCount--;
      if (_activeSaveCount <= 0) {
        for (final waiter in _activeSaveWaiters) {
          if (!waiter.isCompleted) {
            waiter.complete();
          }
        }
        _activeSaveWaiters.clear();
      }
    }
  }

  Future<FileContent> saveFile(
    KdbxFile file, {
    FileSource? toFileSource,
    Credentials? updateCredentials,
  }) async {
    final oldCredentials = file.credentials;
    if (updateCredentials != null) {
      file.credentials = updateCredentials;
    }

    final fileSource = toFileSource ?? fileForKdbxFile(file).fileSource;

    Future<void> updateQuickUnlock() async {
      if (updateCredentials == null) {
        return;
      }
      try {
        await _updateQuickUnlockStore(ifRequiredFor: fileSource);
      } on AuthException catch (e) {
        if (e.code == AuthExceptionCode.userCanceled) {
          // ignore;
          return;
        }
        rethrow;
      }
    }

    try {
      try {
        Uint8List? writtenBytes;
        final ret = await _saveFileToBytes(file, (bytes) async {
          writtenBytes = bytes;
          return await fileSource.contentWrite(bytes, metadata: null);
        });
        analytics.events.trackSave(
          type: fileSource.typeDebug,
          value: ret.content.length,
        );
        analytics.trackTiming(
          'saveFileSize',
          ret.content.length,
          category: 'fileSize',
          label: 'save',
        );
        await updateQuickUnlock();
        if (updateCredentials != null && KeyNestPlatform.isAndroid) {
          await AutofillService().clearCredentials();
          await _syncAndroidAutofillStore(immediate: true);
        }
        await _syncAutofillMirrorAfterSave(file, writtenBytes, ret);
        try {
          KeyNestVaultScope.instance.notifyScopeChanged();
        } catch (_) {}
        try {
          unawaited(KeyNestCloudSyncManager.instance.markVaultDirty(fileSource.uuid));
          KeyNestCloudSyncManager.instance.schedulePostSaveSync(
            kdbxFile: file,
            kdbxBloc: this,
          );
        } catch (_) {}
        return ret;
      } on StorageConflictException catch (e, stackTrace) {
        _logger.fine(
          'Got conflict while writing file. Trying to merge.',
          e,
          stackTrace,
        );
        final content = await fileSource.content(updateCache: false).last;
        final remoteFile = await kdbxFormat.read(
          content.content,
          oldCredentials,
        );
        final mergeResult = DropboxVaultMergeEngine.merge(
          localFile: file,
          remoteFile: remoteFile,
        );
        final mergeContext = MergeContext(
          objectIndex: {},
          deletedObjects: {
            // ignore: invalid_use_of_visible_for_testing_member
            for (final d in file.body.deletedObjects) d.uuid: d,
          },
        );
        for (
          int i = 0;
          i < mergeResult.addedCount + mergeResult.updatedCount;
          i++
        ) {
          mergeContext.trackChange(null, debug: 'merged');
        }
        try {
          _logger.fine('mergeResult: $mergeResult');
          Uint8List? writtenBytes;
          final ret = await _saveFileToBytes(file, (bytes) async {
            writtenBytes = bytes;
            return await fileSource.contentWrite(
              bytes,
              metadata: content.metadata,
            );
          });
          await _syncAutofillMirrorAfterSave(file, writtenBytes, ret);
          delegate?.conflictMerged(fileSource, file, mergeContext);
          analytics.events.trackSaveConflict(
            type: fileSource.typeDebug,
            value:
                mergeResult.addedCount +
                mergeResult.updatedCount +
                mergeResult.deletedCount,
            success: true,
          );
          analytics.events.trackSave(
            type: fileSource.typeDebug,
            value: ret.content.length,
          );
          analytics.trackTiming(
            'saveFileSize',
            ret.content.length,
            category: 'fileSize',
            label: 'save',
          );
          await updateQuickUnlock();
          try {
            unawaited(KeyNestCloudSyncManager.instance.markVaultDirty(fileSource.uuid));
            KeyNestCloudSyncManager.instance.schedulePostSaveSync(
              kdbxFile: file,
              kdbxBloc: this,
            );
          } catch (_) {}
          return ret;
        } catch (e) {
          analytics.events.trackSaveConflict(
            type: fileSource.typeDebug,
            value: mergeResult.totalChanges(),
            success: false,
          );
          rethrow;
        }
      }
    } catch (e) {
      if (updateCredentials != null) {
        file.credentials = oldCredentials;
      }
      rethrow;
    }
  }

  KdbxOpenedFile fileForKdbxFile(KdbxFile file) {
    final cached = _openedFilesByKdbxFile[file];
    if (cached != null) {
      return cached;
    }
    for (final of in _openedFiles.value.values) {
      if (identical(of.kdbxFile, file) || of.kdbxFile == file) {
        _openedFilesByKdbxFile[file] = of;
        return of;
      }
    }
    throw StateError('Missing file source for kdbxFile.');
  }

  KdbxOpenedFile? fileForFileSource(FileSource fileSource) =>
      _openedFiles.value[fileSource];

  Future<KdbxOpenedFile> saveAs(
    KdbxOpenedFile oldFile,
    FileSource output,
  ) async {
    final content = await saveFile(oldFile.kdbxFile, toFileSource: output);
    return await _savedAs(oldFile, output, content);
  }

  Future<KdbxOpenedFile> _savedAs(
    KdbxOpenedFile oldFile,
    FileSource output,
    FileContent fileContent,
  ) async {
    final oldSource = oldFile.fileSource;
    final resolvedName = () {
      final nameFromOutput = output.displayName;
      if (nameFromOutput.isNotEmpty &&
          nameFromOutput != 'Vault' &&
          nameFromOutput.toLowerCase() != 'vault') {
        return nameFromOutput;
      }
      return oldFile.openedFile.name;
    }();
    final newOpenedFile = await appDataBloc.openedFile(
      output,
      name: resolvedName,
      oldFile: oldFile.openedFile,
    );
    final newFile = KdbxOpenedFile(
      fileSource: output,
      openedFile: newOpenedFile,
      kdbxFile: oldFile.kdbxFile,
      kdbxFileContent: fileContent,
    );
    _openedFiles.add(
      OpenedKdbxFiles({
        ...Map.fromEntries(
          _openedFiles.value._files.entries.where(
            (entry) => entry.key != oldSource,
          ),
        ),
        newFile.fileSource: newFile,
      }),
    );
    final oldRef = await KeyNestKeyFileStore.instance.getReference(
      oldSource.uuid,
    );
    if (oldRef != null) {
      await KeyNestKeyFileStore.instance.saveReference(
        vaultUuid: output.uuid,
        displayName: oldRef.displayName,
        filePath: oldRef.filePath,
        filePickerIdentifier: oldRef.filePickerIdentifier,
        macOsBookmark: oldRef.macOsBookmark,
        formatName: oldRef.formatName,
      );
    }
    // TODO also do not update quick unlock if this file is not in quick unlock.
    if (_openedFilesQuickUnlock.isNotEmpty) {
      try {
        await _updateQuickUnlockStore();
      } on AuthException catch (e, stackTrace) {
        if (e.code == AuthExceptionCode.userCanceled) {
          _logger.warning(
            'User cancelled saving quick unlock. ignoring for now.',
            e,
            stackTrace,
          );
        } else {
          rethrow;
        }
      }
    }
    return newFile;
  }

  Future<KdbxOpenedFile> saveAsNewFile(
    KdbxOpenedFile oldFile,
    CloudStorageSelectorSaveResult createFileInfo,
    CloudStorageProvider cs,
  ) async {
    return await _saveFileToBytes(oldFile.kdbxFile, (bytes) async {
      final entity = await cs.createEntity(createFileInfo, bytes);
      final lastContent = entity.lastContent!;
      assert(bytes == lastContent.content);
      return await _savedAs(oldFile, entity, lastContent);
    });
  }

  Future<FileSource> saveLocally(FileSource? source) async {
    final file = _openedFiles.value[source];
    if (file == null) {
      throw StateError('file for $source is not open.');
    }
    final databaseName = file.fileSource.displayName;
    final localSource = await _localFileSourceForDbName(databaseName);
    return (await saveAs(file, localSource)).fileSource;
  }

  Map<String, KdbxEntry>? _entryUuidLookup;

  KdbxEntry? findEntryByUuid(String uuid) {
    final entryUuidLookup = _entryUuidLookup ??= Map.fromEntries(
      openedFilesKdbx.expand(
        (file) => file.body.rootGroup.getAllEntries().map(
          (e) => MapEntry(e.uuid.uuid, e),
        ),
      ),
    );

    return entryUuidLookup[uuid];
  }

  void clearEntryByUuidLookup() => _entryUuidLookup = null;

  Stream<ReloadStatus> reload(KdbxOpenedFile file) async* {
    Uint8List? bytes;
    final currentOpened = _openedFilesByKdbxFile[file.kdbxFile] ?? file;
    final dirtyObjects = currentOpened.kdbxFile.dirtyObjects;
    try {
      if (currentOpened.kdbxFile.isDirty) {
        bytes = await currentOpened.kdbxFile.save();
      }
      yield ReloadStatus.downloading;
      final reloadedContent = await currentOpened.fileSource.content().last;
      assert(reloadedContent.source == FileContentSource.origin);
      if (ByteUtils.eq(
        reloadedContent.content,
        currentOpened.kdbxFileContent.content,
      )) {
        yield ReloadStatus.didNotChange;
        return;
      }

      // try loading the new file.
      yield ReloadStatus.decrypting;
      final readArgs = KdbxReadArgs(
        reloadedContent.content,
        file.kdbxFile.credentials,
      );
      final kdbxReadFile = await readKdbxFile(kdbxFormat, readArgs);

      _logger.info('\n\n\n===========\n\n\n');
      _logger.info('starting merge.');
      DropboxVaultMergeEngine.merge(
        localFile: file.kdbxFile,
        remoteFile: kdbxReadFile.file!,
      );

      _logger.info('\n\nDONE MERGE\n\n\n\n');

      yield ReloadStatus.merged;
    } finally {
      if (bytes != null && !file.kdbxFile.isDirty) {
        dirtyObjects.forEach(file.kdbxFile.dirtyObject);
      }
    }
  }

  Future<AttachmentProvider> attachmentProviderForFileSource(
    KdbxFile file,
  ) async {
    return AttachmentProviderLocal();
  }

  static bool hasVaultWithBiometricsEnrolled(AppData? appData) {
    if (appData == null || appData.previousFiles.isEmpty) {
      return false;
    }
    return appData.previousFiles.any((f) => f.biometricStoreName != null);
  }

  static Future<bool> hasAvailableVault(
    AppData? appData,
    CloudStorageBloc cloudStorageBloc,
  ) async {
    if (appData == null || appData.previousFiles.isEmpty) {
      return false;
    }
    for (final f in appData.previousFiles) {
      if (await f.checkExists(cloudStorageBloc)) {
        return true;
      }
    }
    return false;
  }
}

abstract class AttachmentProvider {
  Future<Uint8List> readAttachmentBytes(KdbxFile file, KdbxBinary binary);
  Future<void> attachFile({
    required KdbxEntry entry,
    required String fileName,
    required Uint8List bytes,
  });
}

class AttachmentProviderLocal extends AttachmentProvider {
  @override
  Future<Uint8List> readAttachmentBytes(
    KdbxFile file,
    KdbxBinary binary,
  ) async {
    return binary.value;
  }

  @override
  Future<void> attachFile({
    required KdbxEntry entry,
    required String fileName,
    required Uint8List bytes,
  }) async {
    entry.createBinary(
      isProtected: false,
      name: fileName,
      bytes: bytes,
    );
  }
}

enum ReloadStatus {
  error,
  downloading,
  decrypting,
  didNotChange,
  merged,
}

class KdbxReadArgs {
  KdbxReadArgs(this.content, this.credentials);

  final Uint8List content;
  final Credentials credentials;
}
