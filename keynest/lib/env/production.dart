import 'package:keynest/env/_base.dart';
import 'package:keynest/env/env.dart';

Future<void> main() async => await Production().start();

class Production extends EnvAppBase {
  Production() : super(EnvType.production);

  @override
  EnvSecrets get secrets => const EnvSecrets(
    analyticsAmplitudeApiKey: null,
    analyticsGoogleAnalyticsId: null,
    analyticsMatomo: null,
    googleClientId: null,
    googleClientSecret: null,
    dropboxKey: null,
    dropboxSecret: null,
    microsoftClientId: null,
    microsoftClientSecret: null,
  );
}
