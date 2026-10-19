import 'package:keynest/env/_base.dart';
import 'package:keynest/env/env.dart';

Future<void> main() async => await TestDriverEnv().start();

class TestDriverEnv extends EnvAppBase {
  TestDriverEnv() : super(EnvType.production);

  @override
  bool get overrideFlutterOnError => false;

  @override
  bool get diacHidden => true;
  @override
  bool get diacDefaultDisabled => true;

  @override
  EnvSecrets get secrets => EnvSecrets.nullSecrets;

  @override
  bool get featureFetchWebsiteIconEnabledByDefault => false;

  @override
  bool get featureOnboarding => false;
}
