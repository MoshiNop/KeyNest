import 'dart:io' as io;
import 'dart:typed_data';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:keynest/bloc/app_data.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/bloc/kdbx/file_source_local.dart';
import 'package:keynest/bloc/kdbx/file_source_ui.dart';
import 'package:keynest/bloc/kdbx_bloc.dart';
import 'package:keynest/cloud_storage/cloud_storage_provider.dart';
import 'package:keynest/cloud_storage/cloud_storage_ui.dart';
import 'package:keynest/l10n-generated/app_localizations.dart';
import 'package:keynest/utils/constants.dart';
import 'package:keynest/utils/platform.dart';
import 'package:logging/logging.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('manage_file');

typedef FileSourceChanged = void Function(FileSource newFileSource);
typedef OnSave = void Function(Future<KdbxOpenedFile> saveFuture);

class SaveFileAs extends StatefulWidget {
  const SaveFileAs({
    required this.title,
    required this.file,
    this.icon,
    this.cs,
    required this.onSave,
    this.subtitle,
  }) : assert((icon != null && subtitle != null) || cs != null);

  final OnSave onSave;
  final KdbxOpenedFile file;
  final String title;
  final String? subtitle;
  final Icon? icon;
  final CloudStorageProvider? cs;
  bool get local => cs == null;

  @override
  _SaveFileAsState createState() => _SaveFileAsState();
}

class _SaveFileAsState extends State<SaveFileAs> with FutureTaskStateMixin {
  @override
  Widget build(BuildContext context) {
    final kdbxBloc = context.watch<KdbxBloc>();
    return ListTile(
      leading: widget.icon ?? widget.cs!.displayIcon.iconData.widget(),
      title: Text(widget.title),
      subtitle: Text(widget.subtitle ?? widget.cs!.displayName),
      onTap: () async {
        _logger.fine('saving. ${widget.local}');
        if (widget.local) {
          final fs = await _selectLocalFileSource();
          if (fs != null) {
            widget.onSave(kdbxBloc.saveAs(widget.file, fs));
          }
        } else {
          final result = await _saveAsCloudStorage(widget.cs!);
          if (result != null) {
            widget.onSave(
              kdbxBloc.saveAsNewFile(widget.file, result, widget.cs!),
            );
          }
        }
      },
    );
  }

  Future<FileSource?> _selectLocalFileSource() async {
    final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
    if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
      final fileName =
          path.basenameWithoutExtension(widget.file.fileSource.displayPath) +
          AppConstants.kdbxExtension;
      final bytes = await kdbxBloc.saveFileToBytes<Uint8List>(
        widget.file.kdbxFile,
        (b) async => b,
      );
      final fileInfo = await FileSourceLocal.createFileInNewTempDirectory(
        fileName,
        (tempFile) async {
          return await FilePickerWritable().openFileForCreate(
            fileName: fileName,
            writer: (file) async {
              _logger.fine('Writing encrypted kdbx bytes into $file');
              await file.writeAsBytes(bytes, flush: true);
            },
          );
        },
      );

      if (fileInfo == null) {
        _logger.info('User cancelled file picker.');
        return null;
      }
      _logger.fine('writing to ${fileInfo.uri} / ${fileInfo.fileName}');
      return FileSourceLocal(
        FileSourceLocal.localFile(fileInfo.fileName!),
        databaseName: widget.file.fileSource.displayName,
        uuid: AppDataBloc.createUuid(),
        filePickerIdentifier: fileInfo.toJsonString(),
      );
    }
    final loc = AppLocalizations.of(context);
    final pathFile = await getSaveLocation(
      suggestedName: path.basename(widget.file.fileSource.displayPath),
      confirmButtonText: loc.saveButtonLabel,
    );
    if (pathFile == null) {
      // Operation was canceled by the user.
      return null;
    }

    final outputFile = io.File(pathFile.path);
    String? macOsBookmark;
    if (KeyNestPlatform.isMacOS) {
      // create a dummy file, so we can create a secure bookmark.
      await outputFile.writeAsString(nonNls('.'));
      macOsBookmark = await SecureBookmarks().bookmark(outputFile);
    }
    return FileSourceLocal(
      FileSourceLocal.localFile(pathFile.path),
      uuid: AppDataBloc.createUuid(),
      macOsSecureBookmark: macOsBookmark,
    );
  }

  Future<CloudStorageSelectorSaveResult?> _saveAsCloudStorage(
    CloudStorageProvider cs,
  ) async {
    _logger.fine('pushing cloud storage selector.');
    final createFileInfo = await Navigator.of(context).push(
      CloudStorageSelector.route(
        cs,
        CloudStorageBrowserConfig(
          defaultFileName: path.basename(widget.file.fileSource.displayPath),
          isSave: true,
        ),
      ),
    );
    _logger.fine('done. $createFileInfo');
    return createFileInfo;
  }
}
