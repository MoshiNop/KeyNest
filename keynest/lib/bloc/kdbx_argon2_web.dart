import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:argon2_ffi_base/argon2_ffi_base.dart';
import 'package:keynest/bloc/jsinterop/argon2_browser.dart';

class FlutterArgon2 extends Argon2 {
  @override
  Uint8List argon2(Argon2Arguments args) {
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> argon2Async(Argon2Arguments args) async {
    final passBuffer = Uint8List.fromList(args.key);
    try {
      final passJs = passBuffer.toJS;
      final saltJs = args.salt.toJS;
      return await argon2BrowserHash(
        Argon2BrowserOptions(
          pass: passJs,
          salt: saltJs,
          time: args.iterations,
          mem: args.memory,
          hashLen: args.length,
          parallelism: args.parallelism,
          type: args.type,
        ),
      );
    } finally {
      passBuffer.fillRange(0, passBuffer.length, 0);
    }
  }

  @override
  bool get isFfi => false;

  @override
  bool get isImplemented => true;
}
