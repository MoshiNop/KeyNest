import 'dart:io' as io;
import 'dart:typed_data';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:keynest/utils/platform.dart';

Future<String?> saveOrDownloadFile({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
}) async {
  if (KeyNestPlatform.isIOS || KeyNestPlatform.isAndroid) {
    String? savedName;
    await FilePickerWritable().openFileForCreate(
      fileName: filename,
      writer: (file) async {
        await file.writeAsBytes(bytes);
        savedName = filename;
      },
    );
    return savedName;
  } else {
    final location = await getSaveLocation(suggestedName: filename);
    if (location != null) {
      final file = io.File(location.path);
      await file.writeAsBytes(bytes);
      return location.path;
    }
    return null;
  }
}
