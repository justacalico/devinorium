import 'package:flutter/widgets.dart';

import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
export 'package:devinorium_frontend/generated/l10n/app_localizations.dart';

AppLocalizations l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
