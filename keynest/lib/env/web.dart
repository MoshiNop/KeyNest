import 'package:keynest/env/_base.dart';
import 'package:keynest/env/env.dart';

Future<void> main() async => await WebProduction().start();

class WebProduction extends EnvAppBase {
  WebProduction() : super(EnvType.production);

  @override
  bool get featureCloudStorageProprietary => true;

  @override
  bool get featureCloudStorageWebDav => true;

  @override
  EnvSecrets? get secrets => EnvSecrets.nullSecrets;
}
