import 'dart:async';
import 'dart:convert';

import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';
import 'package:built_value/standard_json_plugin.dart';
import 'package:clock/clock.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:file/local.dart';
import 'package:flutter/material.dart' show Color;
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx/file_source_web_none.dart'
    if (dart.library.js) 'package:keynest/bloc/kdbx/file_source_web.dart'
    if (dart.library.html) 'package:keynest/bloc/kdbx/file_source_web.dart'
    if (dart.library.js_interop) 'package:keynest/bloc/kdbx/file_source_web.dart';
import 'package:keynest/cloud_storage/cloud_storage_bloc.dart';
import 'package:keynest/env/_base.dart';
import 'package:keynest/utils/path_utils.dart';
import 'package:keynest/utils/uuid_util.dart';
import 'package:logging/logging.dart';
import 'package:simple_json_persistence/simple_json_persistence.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

part 'app_data.g.dart';

final _logger = Logger('app_data');

enum OpenedFilesSourceType { Local, Url, CloudStorage, LocalWeb }

class SimpleEnumSerializer<T> extends PrimitiveSerializer<T> {
  SimpleEnumSerializer(this.enumValues);

  final List<T> enumValues;

  @override
  T deserialize(
    Serializers serializers,
    Object serialized, {
    FullType specifiedType = FullType.unspecified,
  }) {
    assert(serialized is String);
    return enumValues.singleWhere((val) => val.toString() == serialized);
  }

  @override
  Object serialize(
    Serializers serializers,
    T object, {
    FullType specifiedType = FullType.unspecified,
  }) {
    return object.toString();
  }

  @override
  Iterable<Type> get types => [T];

  @override
  String get wireName => T.toString();
}

abstract class OpenedFile implements Built<OpenedFile, OpenedFileBuilder> {
  factory OpenedFile([void Function(OpenedFileBuilder b) updates]) =
      _$OpenedFile;

  OpenedFile._();

  static Serializer<OpenedFile> get serializer => _$openedFileSerializer;

  static const SOURCE_CLOUD_STORAGE_ID = 'storageId'; // NON-NLS
  static const SOURCE_CLOUD_STORAGE_DATA = 'data'; // NON-NLS

  /// unique id to identify this open file across sessions.
  String get uuid;

  @BuiltValueField(compare: false)
  DateTime? get lastOpenedAt;

  OpenedFilesSourceType get sourceType;

  String get sourcePath;

  String get name;

  /// when the user to choose to store password behind biometric keystore
  /// we generate a (more or less) random name to store it into.
  String? get biometricStoreName;

  String? get macOsSecureBookmark;

  /// stores the identifier as returned by [FilePickerWritable]
  String? get filePickerIdentifier;

  int? get colorCode;

  /// Whether this database may be offered by the OS credential provider.
  ///
  /// Null means "never chosen", and defaults to on: a database that is open is
  /// offered. Opting out is explicit and is remembered as false, so this cannot
  /// silently turn itself back on for someone who switched it off.
  ///
  /// Enabling copies the vault into the shared app group container and caches
  /// its key — encrypted, and biometry bound, respectively. See
  /// [AutofillMirror] for what that does and does not expose.
  bool? get autofillEnabled;

  /// [autofillEnabled], with "never chosen" resolved. Read this, not the field.
  bool get autofillEnabledOrDefault => autofillEnabled ?? true;

  Color? get color => colorCode == null ? null : Color(colorCode!);

  bool isSameFileAs(OpenedFile other) {
    if (other.sourceType != sourceType) {
      return false;
    }
    if (filePickerIdentifier != null && other.filePickerIdentifier != null) {
      if (filePickerIdentifier == other.filePickerIdentifier) {
        return true;
      }
      try {
        final uri1 = json.decode(filePickerIdentifier!)['uri'];
        final uri2 = json.decode(other.filePickerIdentifier!)['uri'];
        if (uri1 != null && uri1 == uri2) {
          return true;
        }
      } catch (_) {}
    }
    return other.sourcePath == sourcePath;
  }

  static OpenedFile fromFileSource(
    FileSource fileSource,
    String? dbName, [
    void Function(OpenedFileBuilder b)? customize,
  ]) => OpenedFile(
    (b) {
      b.lastOpenedAt = clock.now().toUtc();
      b.uuid = fileSource.uuid;
      final effectiveName = () {
        final fsName = fileSource.displayName;
        if (fsName.isNotEmpty &&
            fsName != 'Vault' &&
            fsName.toLowerCase() != 'vault') {
          return fsName;
        }
        if (dbName != null && dbName.trim().isNotEmpty) {
          final cleanDb = FileSource.cleanDisplayName(dbName);
          if (cleanDb.isNotEmpty &&
              cleanDb != 'Vault' &&
              cleanDb.toLowerCase() != 'vault') {
            return cleanDb;
          }
        }
        if (fsName.isNotEmpty) {
          return fsName;
        }
        if (dbName != null && dbName.trim().isNotEmpty) {
          return FileSource.cleanDisplayName(dbName);
        }
        return 'Vault';
      }();
      if (fileSource is FileSourceLocal) {
        b
          ..sourceType = OpenedFilesSourceType.Local
          ..sourcePath = fileSource.file.absolute.path
          ..macOsSecureBookmark = fileSource.macOsSecureBookmark
          ..filePickerIdentifier = fileSource.filePickerIdentifier
          ..name = effectiveName;
      } else if (fileSource is FileSourceWeb) {
        b
          ..sourceType = OpenedFilesSourceType.LocalWeb
          ..sourcePath = effectiveName
          ..name = effectiveName;
      } else if (fileSource is FileSourceUrl) {
        b
          ..sourceType = OpenedFilesSourceType.Url
          ..sourcePath = fileSource.url.toString()
          ..name = effectiveName;
      } else if (fileSource is FileSourceCloudStorage) {
        b
          ..sourceType = OpenedFilesSourceType.CloudStorage
          ..sourcePath = json.encode({
            SOURCE_CLOUD_STORAGE_ID: fileSource.provider.id,
            SOURCE_CLOUD_STORAGE_DATA: fileSource.fileInfo,
          })
          ..name = effectiveName;
      } else {
        throw ArgumentError.value(
          fileSource,
          'fileSource',
          'Unsupported file type ${fileSource.runtimeType}',
        );
      }
      if (customize != null) {
        customize(b);
      }
    },
  );

  FileSource toFileSource(CloudStorageBloc cloudStorageBloc) {
    switch (sourceType) {
      case OpenedFilesSourceType.Local:
        return FileSourceLocal(
          (const LocalFileSystem()).file(sourcePath),
          macOsSecureBookmark: macOsSecureBookmark,
          filePickerIdentifier: filePickerIdentifier,
          uuid: uuid,
          databaseName: name,
        );
      case OpenedFilesSourceType.LocalWeb:
        return FileSourceWeb(
          databaseName: name,
          uuid: uuid,
        );
      case OpenedFilesSourceType.Url:
        return FileSourceUrl(
          Uri.parse(sourcePath),
          uuid: uuid,
          databaseName: name,
        );
      case OpenedFilesSourceType.CloudStorage:
        final sourceInfo = json.decode(sourcePath) as Map<String, dynamic>;
        final storageId = sourceInfo[SOURCE_CLOUD_STORAGE_ID] as String?;
        final provider = cloudStorageBloc.providerById(storageId);
        if (provider == null) {
          throw StateError(
            'Invalid cloud storage provider id $storageId '
            '(${cloudStorageBloc.availableCloudStorage.map((e) => e.id).join(',')})',
          );
        }
        return provider.toFileSourceFromFileInfo(
          (sourceInfo[SOURCE_CLOUD_STORAGE_DATA] as Map)
              .cast<String, String?>(),
          uuid: uuid,
          databaseName: name,
          initialCachedContent: null,
        );

      // default:
      //   throw ArgumentError.value(
      //       sourceType, 'sourceType', 'Unsupported value.');
    }
  }

  Future<bool> checkExists(CloudStorageBloc cloudStorageBloc) async {
    try {
      final source = toFileSource(cloudStorageBloc);
      return await source.checkExists();
    } catch (e) {
      _logger.fine('OpenedFile checkExists error for $sourcePath: $e');
      return false;
    }
  }
}

enum AppDataTheme { dark, light }

abstract class AppData implements Built<AppData, AppDataBuilder>, HasToJson {
  factory AppData([void Function(AppDataBuilder b)? updates]) = _$AppData;

  AppData._();

  static Serializer<AppData> get serializer => _$appDataSerializer;

  static const manualUserTypeAdmin = 'admin'; // NON-NLS

  BuiltList<OpenedFile> get previousFiles;

  int? get passwordGeneratorLength;

  BuiltSet<String> get passwordGeneratorCharacterSets;

  String? get manualUserType;

  DateTime? get firstLaunchedAt;

  /// Theme of the app, either light or dark (null means system default)
  AppDataTheme? get theme;

  ///UUid's of local Files whose warnings were dismissed
  BuiltList<String>? get dismissedBackupLocalFiles;

  bool? get dismissedAutofillSuggestion;

  double? get themeVisualDensity;

  double? get themeFontSizeFactor;

  bool? get diacOptIn;

  /// remember which build id was used, so we might be
  /// able to show a changelog in the future..
  int? get lastBuildId;

  /// Android only: disable screenshots, etc. (FLAG_SECURE)
  bool? get secureWindow;
  bool get secureWindowOrDefault => secureWindow ?? true;

  /// allows overriding system locale to a specific language.
  String? get localeOverride;

  /// whether to fetch icons for password entries with websites from
  /// the internet, instead of showing kdbx icons.
  bool? get fetchWebsiteIcons;

  /// whether to use cloud attachments.
  bool? get keyNestCloudAttachments;
  bool get keyNestCloudAttachmentsOrDefault => keyNestCloudAttachments ?? false;

  /// whether to register system wide global shortcuts.
  bool get systemWideShortcuts;

  /// Fields used for searching. By default [CommonFields.defaultSearchFields]
  /// Values must be comma separated or `*` for all fields.
  String? get searchFields;

  @BuiltValueHook(initializeBuilder: true)
  static void _setDefaults(AppDataBuilder b) => b..systemWideShortcuts = false;

  @override
  Map<String, dynamic> toJson() =>
      serializers.serialize(this) as Map<String, dynamic>;

  OpenedFile? recentFileByUuid(String uuid) {
    return previousFiles.firstWhereOrNull((f) => f.uuid == uuid);
  }
}

@SerializersFor([
  AppData,
  OpenedFile,
])
Serializers serializers =
    (_$serializers.toBuilder()
          ..add(
            SimpleEnumSerializer<OpenedFilesSourceType>(
              OpenedFilesSourceType.values,
            ),
          )
          ..add(SimpleEnumSerializer<AppDataTheme>(AppDataTheme.values))
          ..addPlugin(StandardJsonPlugin()))
        .build();

class AppDataBloc {
  AppDataBloc(this.env) {
    _init();
  }

  final Env env;

  final store = SimpleJsonPersistence.getForTypeWithDefault(
    (json) => serializers.deserializeWith(AppData.serializer, json)!,
    name: nonNls('AppData'),
    defaultCreator: () =>
        AppData((b) => b..firstLaunchedAt = clock.now().toUtc()),
    storeBackend: createStoreBackend(
      () async => (await PathUtils().getAppDataDirectory()).path,
    ),
  );

  static String createUuid() => UuidUtil.createUuid();

  Future<void> _init() async {
    await Future<dynamic>.delayed(const Duration(milliseconds: 100));
    final data = await store.load();
    final appInfo = await env.getAppInfo();
    if (data.firstLaunchedAt == null ||
        data.lastBuildId != appInfo.buildNumber) {
      await update(
        (b, data) => b
          ..lastBuildId = appInfo.buildNumber
          ..firstLaunchedAt ??= clock.now().toUtc(),
      );
    }
  }

  /// Automatically prunes any local files from [previousFiles] that no longer
  /// exist on the filesystem (e.g. deleted by the user or wiped on reinstall).
  Future<void> pruneNonExistentFiles(CloudStorageBloc cloudStorageBloc) async {
    try {
      final data = await store.load();
      if (data.previousFiles.isEmpty) {
        return;
      }
      final toRemove = <OpenedFile>[];
      for (final f in data.previousFiles) {
        if (f.filePickerIdentifier != null) {
          continue;
        }
        final exists = await f.checkExists(cloudStorageBloc);
        if (!exists) {
          _logger.info(
            'Pruning non-existent vault from previousFiles: ${f.name} (${f.sourcePath})',
          );
          toRemove.add(f);
        }
      }
      if (toRemove.isNotEmpty) {
        await update((b, data) {
          toRemove.forEach(b.previousFiles.remove);
        });
        _logger.info(
          'Pruned ${toRemove.length} non-existent vaults from previousFiles.',
        );
      }
    } catch (e, stack) {
      _logger.warning('Failed to prune non-existent files: $e', e, stack);
    }
  }

  /// Clears all previous files (used on fresh installs to discard cloud-restored ghost vaults).
  Future<void> clearAllPreviousFiles() async {
    try {
      await update((b, data) {
        b.previousFiles.clear();
      });
      _logger.info('Cleared all previousFiles records.');
    } catch (e, stack) {
      _logger.warning('Failed to clear previousFiles: $e', e, stack);
    }
  }

  ///
  /// if [oldFile] is defined non-essential data (e.g. colorCode) is copied from it.
  Future<OpenedFile> openedFile(
    FileSource file, {
    required String? name,
    OpenedFile? oldFile,
    Color? defaultColor,
    String? biometricStoreName,
  }) async => await update((b, data) {
    final recentFile = data.recentFileByUuid(file.uuid) ?? oldFile;
    final colorCode =
        recentFile?.colorCode ?? oldFile?.colorCode ?? defaultColor?.toARGB32();
    // Carried like colorCode, and for the same reason: this record is built
    // fresh on every open, so anything not copied here is a setting the user
    // silently loses by closing the database. Autofill and biometric enrollment
    // have to survive, or settings the user chose are silently lost.
    final autofillEnabled =
        recentFile?.autofillEnabled ?? oldFile?.autofillEnabled;
    final resolvedBiometricStoreName =
        biometricStoreName ??
        recentFile?.biometricStoreName ??
        oldFile?.biometricStoreName;
    final openedFile = OpenedFile.fromFileSource(
      file,
      name,
      (b) => b
        ..colorCode = colorCode
        ..autofillEnabled = autofillEnabled
        ..biometricStoreName = resolvedBiometricStoreName,
    );
    _logger.finest('openedFile: $openedFile');
    // TODO remove potential old storages?
    b.previousFiles.removeWhere((file) => file.isSameFileAs(openedFile));
    b.previousFiles.add(openedFile);
    return openedFile;
  });

  Future<void> _updateQueue = Future.value();

  Future<T> update<T>(
    T Function(AppDataBuilder builder, AppData data) updater,
  ) {
    final completer = Completer<T>();
    _updateQueue = _updateQueue.then((_) async {
      try {
        final appData = store.cachedValue ?? await store.load();
        late T ret;
        final newAppData = appData.rebuild((b) => ret = updater(b, appData));
        await store.save(newAppData);
        completer.complete(ret);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<AppDataTheme?> updateNextTheme() async {
    final updated = await update((builder, data) {
      final nextTheme = data.theme == null
          ? AppDataTheme.light
          : data.theme == AppDataTheme.light
          ? AppDataTheme.dark
          : null;
      return builder.theme = nextTheme;
    });
    return updated;
  }
}
