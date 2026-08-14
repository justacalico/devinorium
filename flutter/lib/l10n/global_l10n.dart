import 'package:flutter/widgets.dart';

import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';

AppLocalizations _appL10n = lookupAppLocalizations(const Locale('en'));

AppLocalizations get appL10n => _appL10n;

void setAppL10n(Locale locale) {
  final tag = locale.toLanguageTag();
  final code = tag.contains('-') ? tag.substring(0, tag.indexOf('-')) : tag;
  final target = <String>['en'].contains(code) ? Locale(code) : const Locale('en');
  _appL10n = lookupAppLocalizations(target);
}
