import 'package:flutter/foundation.dart';

import 'file_export_io.dart'
    if (dart.library.js_interop) 'file_export_web.dart'
    as impl;

class FileExportHelper {
  @visibleForTesting
  static Future<String?> Function({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  })?
  overrideSaveOrDownload;

  static Future<String?> exportFile({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  }) async {
    if (overrideSaveOrDownload != null) {
      return await overrideSaveOrDownload!(
        bytes: bytes,
        filename: filename,
        mimeType: mimeType,
      );
    }
    return await impl.saveOrDownloadFile(
      bytes: bytes,
      filename: filename,
      mimeType: mimeType,
    );
  }
}
