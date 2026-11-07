import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

@NonNls
class AppConstants {
  static const keyNest = 'KeyNest'; // NON-NLS
  static const keyNestCloud = 'KeyNest Cloud'; // NON-NLS

  static const routeOpenFile = '/openFile'; // NON-NLS
  static const routeOpenFileParamFile = 'file'; // NON-NLS
  /// KeyNest Cloud based share code
  static const routeOpenFileParamToken = 'token'; // NON-NLS
  static const routeOpen = '/open'; // NON-NLS

  static const kdbxExtension = '.kdbx'; // NON-NLS
  static const pngExtension = '.png'; // NON-NLS
  static const pngExtensionNoDot = 'png'; // NON-NLS

  static const contentTypeTextPlain = 'text/plain'; // NON-NLS

  static const keyNestHost = 'github.com';
  static const keyNestUrl = 'https://github.com/MoshiNop/keynest';
  static const keyNestCloudInfoUrl =
      'https://github.com/MoshiNop/keynest#readme';
  static final keyNestInstall = Uri.parse(
    'https://github.com/MoshiNop/keynest/releases',
  );
  static const keyNestWebApp = 'https://github.com/MoshiNop/keynest';
  static final keyNestWebAppUri = Uri.parse('$keyNestWebApp/');

  static const utmCampaign = 'utm_campaign';
  static const utmSource = 'utm_source';
  static const utmSourceValue = 'app';
}

extension UriAnalytics on Uri {
  Uri utmCampaign(@NonNls String campaign) {
    return replace(
      queryParameters: <String, List<String>>{
        ...queryParametersAll,
        AppConstants.utmCampaign: [campaign],
        AppConstants.utmSource: [AppConstants.utmSourceValue],
      },
    );
  }
}

@NonNls
class CharConstants {
  static const empty = ''; // NON-NLS
  static const underScore = '_'; // NON-NLS
  static const plus = '+'; // NON-NLS

  static const space = ' '; // NON-NLS
  static const curlyOpen = '{'; // NON-NLS

  static const chevronRight = ' » '; // NON-NLS

  static const slash = '/'; // NON-NLS
  static const newLine = '\n'; // NON-NLS

  static const colon = ':'; // NON-NLS
  static const comma = ',';

  static const semiColon = ';'; // NON-NLS

  static const equalSign = '=';

  static const star = '*';

  static const questionMark = '?';
}

class AssetConstants {
  @NonNls
  static String logoIcon = 'assets/images/logo_icon.png';
}

class UrlConstants {
  static const forumUrl =
      'https://github.com/MoshiNop/keynest/discussions'; // NON-NLS
}
