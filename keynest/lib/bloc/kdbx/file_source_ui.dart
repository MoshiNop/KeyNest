import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:keynest/bloc/kdbx/file_source.dart';
import 'package:keynest/utils/keynest_icons.dart';

sealed class IconDataWrapperBase {
  IconDataWrapperBase._();
  factory IconDataWrapperBase.iconData(IconData iconData) =>
      IconDataWrapper(iconData: iconData);
  factory IconDataWrapperBase.faIconData(FaIconData faIconData) =>
      FaIconDataWrapper(faIconData: faIconData);

  Widget widget({Color? color, double? size});
}

class IconDataWrapper extends IconDataWrapperBase {
  IconDataWrapper({required this.iconData}) : super._();

  final IconData iconData;

  @override
  Widget widget({Color? color, double? size}) =>
      Icon(iconData, color: color, size: size);
}

class FaIconDataWrapper extends IconDataWrapperBase {
  FaIconDataWrapper({required this.faIconData}) : super._();

  final FaIconData faIconData;

  @override
  Widget widget({Color? color, double? size}) =>
      FaIcon(faIconData, color: color, size: size);
}

extension FileSourceIconUi on FileSourceIcon {
  IconDataWrapperBase get iconData {
    switch (this) {
      case FileSourceIcon.dropbox:
        return .faIconData(FontAwesomeIcons.dropbox);
      case FileSourceIcon.googleDrive:
        return .faIconData(FontAwesomeIcons.googleDrive);
      case FileSourceIcon.webDav:
        return .faIconData(FontAwesomeIcons.cloudArrowUp);
      case FileSourceIcon.oneDrive:
        return .faIconData(FontAwesomeIcons.microsoft);
      case FileSourceIcon.hdd:
        return .faIconData(FontAwesomeIcons.hardDrive);
      case FileSourceIcon.externalLink:
        return .faIconData(FontAwesomeIcons.upRightFromSquare);
      case FileSourceIcon.keyNest:
        return .iconData(KeyNestIcons.keyNestLogo);
    }
  }
}
