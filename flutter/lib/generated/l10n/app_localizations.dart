import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Application title shown in the taskbar
  ///
  /// In en, this message translates to:
  /// **'Devinorium'**
  String get appTitle;

  /// No description provided for @connectionFailed.
  ///
  /// In en, this message translates to:
  /// **'connection failed'**
  String get connectionFailed;

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'import failed'**
  String get importFailed;

  /// No description provided for @totpPrompt.
  ///
  /// In en, this message translates to:
  /// **'Enter your 6-digit TOTP code.'**
  String get totpPrompt;

  /// No description provided for @selectProjectFirst.
  ///
  /// In en, this message translates to:
  /// **'Select a project first'**
  String get selectProjectFirst;

  /// No description provided for @newThread.
  ///
  /// In en, this message translates to:
  /// **'New thread'**
  String get newThread;

  /// No description provided for @invalidPermissionRequest.
  ///
  /// In en, this message translates to:
  /// **'Invalid permission request: {error}'**
  String invalidPermissionRequest(String error);

  /// No description provided for @failedToDecodePermissionRequest.
  ///
  /// In en, this message translates to:
  /// **'Failed to decode permission request'**
  String get failedToDecodePermissionRequest;

  /// No description provided for @invalidAskRequest.
  ///
  /// In en, this message translates to:
  /// **'Invalid ask request'**
  String get invalidAskRequest;

  /// No description provided for @failedToDecodeAskRequest.
  ///
  /// In en, this message translates to:
  /// **'Failed to decode ask request'**
  String get failedToDecodeAskRequest;

  /// No description provided for @serverUrlNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'server URL not configured'**
  String get serverUrlNotConfigured;

  /// No description provided for @authenticationTokenNotSet.
  ///
  /// In en, this message translates to:
  /// **'authentication token not set'**
  String get authenticationTokenNotSet;

  /// No description provided for @httpErrorStatus.
  ///
  /// In en, this message translates to:
  /// **'HTTP {statusCode}'**
  String httpErrorStatus(int statusCode);

  /// No description provided for @httpErrorWithText.
  ///
  /// In en, this message translates to:
  /// **'HTTP {statusCode}: {text}'**
  String httpErrorWithText(int statusCode, String text);

  /// No description provided for @unexpectedResponseShape.
  ///
  /// In en, this message translates to:
  /// **'unexpected response shape'**
  String get unexpectedResponseShape;

  /// No description provided for @expectedAList.
  ///
  /// In en, this message translates to:
  /// **'expected a list'**
  String get expectedAList;

  /// No description provided for @sseOnlySupportedOnWeb.
  ///
  /// In en, this message translates to:
  /// **'SSE streaming is only supported on the web'**
  String get sseOnlySupportedOnWeb;

  /// No description provided for @noResponseBody.
  ///
  /// In en, this message translates to:
  /// **'no response body'**
  String get noResponseBody;

  /// No description provided for @unexpectedStreamChunkType.
  ///
  /// In en, this message translates to:
  /// **'Unexpected stream chunk type'**
  String get unexpectedStreamChunkType;

  /// No description provided for @genericRequestError.
  ///
  /// In en, this message translates to:
  /// **'{error}'**
  String genericRequestError(String error);

  /// No description provided for @signInToYourAccount.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your account'**
  String get signInToYourAccount;

  /// No description provided for @totpCode.
  ///
  /// In en, this message translates to:
  /// **'TOTP code'**
  String get totpCode;

  /// No description provided for @totpHint.
  ///
  /// In en, this message translates to:
  /// **'000000'**
  String get totpHint;

  /// No description provided for @atLeast12Characters.
  ///
  /// In en, this message translates to:
  /// **'At least 12 characters'**
  String get atLeast12Characters;

  /// No description provided for @createUser.
  ///
  /// In en, this message translates to:
  /// **'Create user'**
  String get createUser;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get required;

  /// No description provided for @invalidNumber.
  ///
  /// In en, this message translates to:
  /// **'Must be a valid number'**
  String get invalidNumber;

  /// No description provided for @otherOption.
  ///
  /// In en, this message translates to:
  /// **'Other (type your own)'**
  String get otherOption;

  /// No description provided for @otherHint.
  ///
  /// In en, this message translates to:
  /// **'Type your answer'**
  String get otherHint;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @test.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get test;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// No description provided for @on.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get on;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @enabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get enabled;

  /// No description provided for @disabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get disabled;

  /// No description provided for @light.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get light;

  /// No description provided for @dark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get dark;

  /// No description provided for @system.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signIn;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOut;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @account.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get account;

  /// No description provided for @providers.
  ///
  /// In en, this message translates to:
  /// **'Providers'**
  String get providers;

  /// No description provided for @provider.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get provider;

  /// No description provided for @devices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get devices;

  /// No description provided for @personalization.
  ///
  /// In en, this message translates to:
  /// **'Personalization'**
  String get personalization;

  /// No description provided for @manage.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get manage;

  /// No description provided for @projects.
  ///
  /// In en, this message translates to:
  /// **'Projects'**
  String get projects;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @root.
  ///
  /// In en, this message translates to:
  /// **'root'**
  String get root;

  /// No description provided for @home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// No description provided for @up.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get up;

  /// No description provided for @newProject.
  ///
  /// In en, this message translates to:
  /// **'New project'**
  String get newProject;

  /// No description provided for @newFolder.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get newFolder;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @renameProject.
  ///
  /// In en, this message translates to:
  /// **'Rename project'**
  String get renameProject;

  /// No description provided for @renameThread.
  ///
  /// In en, this message translates to:
  /// **'Rename thread'**
  String get renameThread;

  /// No description provided for @newName.
  ///
  /// In en, this message translates to:
  /// **'New name'**
  String get newName;

  /// No description provided for @options.
  ///
  /// In en, this message translates to:
  /// **'Options'**
  String get options;

  /// No description provided for @ownerBadge.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get ownerBadge;

  /// No description provided for @revoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get revoke;

  /// No description provided for @enable2fa.
  ///
  /// In en, this message translates to:
  /// **'Enable 2FA'**
  String get enable2fa;

  /// No description provided for @totpSetupInstructions.
  ///
  /// In en, this message translates to:
  /// **'Scan this secret in your authenticator app, then enter the current code.'**
  String get totpSetupInstructions;

  /// No description provided for @verify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get verify;

  /// No description provided for @name.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// No description provided for @myProjectHint.
  ///
  /// In en, this message translates to:
  /// **'My project'**
  String get myProjectHint;

  /// No description provided for @path.
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get path;

  /// No description provided for @projectPathHint.
  ///
  /// In en, this message translates to:
  /// **'relative/path or /absolute/project/path'**
  String get projectPathHint;

  /// No description provided for @browseToThisPath.
  ///
  /// In en, this message translates to:
  /// **'Browse to this path'**
  String get browseToThisPath;

  /// No description provided for @selectCurrentFolder.
  ///
  /// In en, this message translates to:
  /// **'Select current folder'**
  String get selectCurrentFolder;

  /// No description provided for @pathTraversalNotAllowed.
  ///
  /// In en, this message translates to:
  /// **'Path traversal is not allowed'**
  String get pathTraversalNotAllowed;

  /// No description provided for @nameAndPathRequired.
  ///
  /// In en, this message translates to:
  /// **'Name and path are required'**
  String get nameAndPathRequired;

  /// No description provided for @noSubfoldersHere.
  ///
  /// In en, this message translates to:
  /// **'No subfolders here'**
  String get noSubfoldersHere;

  /// No description provided for @permissionRequest.
  ///
  /// In en, this message translates to:
  /// **'Permission request'**
  String get permissionRequest;

  /// No description provided for @askRequest.
  ///
  /// In en, this message translates to:
  /// **'Agent question'**
  String get askRequest;

  /// No description provided for @allowThisAction.
  ///
  /// In en, this message translates to:
  /// **'Allow this action?'**
  String get allowThisAction;

  /// No description provided for @allowOnce.
  ///
  /// In en, this message translates to:
  /// **'Allow once'**
  String get allowOnce;

  /// No description provided for @allowAlways.
  ///
  /// In en, this message translates to:
  /// **'Allow always'**
  String get allowAlways;

  /// No description provided for @rejectOnce.
  ///
  /// In en, this message translates to:
  /// **'Reject once'**
  String get rejectOnce;

  /// No description provided for @rejectAlways.
  ///
  /// In en, this message translates to:
  /// **'Reject always'**
  String get rejectAlways;

  /// No description provided for @dropZoneFileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'{name} is too large (max 8 MB)'**
  String dropZoneFileTooLarge(String name);

  /// No description provided for @dropZoneReadFileFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to read file: {error}'**
  String dropZoneReadFileFailed(String error);

  /// No description provided for @dropZoneAttachFilesFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to attach files: {error}'**
  String dropZoneAttachFilesFailed(String error);

  /// No description provided for @dropZonePickFilesFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to pick files: {error}'**
  String dropZonePickFilesFailed(String error);

  /// No description provided for @dropZoneDropHere.
  ///
  /// In en, this message translates to:
  /// **'Drop files here to attach'**
  String get dropZoneDropHere;

  /// No description provided for @files.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get files;

  /// No description provided for @emptyFolder.
  ///
  /// In en, this message translates to:
  /// **'Empty folder'**
  String get emptyFolder;

  /// No description provided for @folderNameHint.
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get folderNameHint;

  /// No description provided for @deleteName.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String deleteName(String name);

  /// No description provided for @searchModels.
  ///
  /// In en, this message translates to:
  /// **'Search models'**
  String get searchModels;

  /// No description provided for @noModelsMatch.
  ///
  /// In en, this message translates to:
  /// **'No models match'**
  String get noModelsMatch;

  /// No description provided for @free.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get free;

  /// No description provided for @promo.
  ///
  /// In en, this message translates to:
  /// **'Promo'**
  String get promo;

  /// No description provided for @newLabel.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get newLabel;

  /// No description provided for @beta.
  ///
  /// In en, this message translates to:
  /// **'Beta'**
  String get beta;

  /// No description provided for @noModelSelected.
  ///
  /// In en, this message translates to:
  /// **'No model selected'**
  String get noModelSelected;

  /// No description provided for @model.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get model;

  /// No description provided for @selected.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get selected;

  /// No description provided for @selectModel.
  ///
  /// In en, this message translates to:
  /// **'Select model'**
  String get selectModel;

  /// No description provided for @modelContextLabel.
  ///
  /// In en, this message translates to:
  /// **'Context'**
  String get modelContextLabel;

  /// No description provided for @modelOutputLabel.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get modelOutputLabel;

  /// No description provided for @costTierLabel.
  ///
  /// In en, this message translates to:
  /// **'Cost tier'**
  String get costTierLabel;

  /// No description provided for @pricingLabel.
  ///
  /// In en, this message translates to:
  /// **'Pricing'**
  String get pricingLabel;

  /// No description provided for @contextWithTokens.
  ///
  /// In en, this message translates to:
  /// **'{count} context'**
  String contextWithTokens(String count);

  /// No description provided for @otherFamily.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get otherFamily;

  /// No description provided for @serverUrl.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get serverUrl;

  /// No description provided for @serverUrlHint.
  ///
  /// In en, this message translates to:
  /// **'example.com'**
  String get serverUrlHint;

  /// No description provided for @serverUrlInvalid.
  ///
  /// In en, this message translates to:
  /// **'Do not include http:// or https:// in the server address'**
  String get serverUrlInvalid;

  /// No description provided for @devicesDescription.
  ///
  /// In en, this message translates to:
  /// **'Active sessions for your account.'**
  String get devicesDescription;

  /// No description provided for @noPairedDevices.
  ///
  /// In en, this message translates to:
  /// **'No devices.'**
  String get noPairedDevices;

  /// No description provided for @deviceToken.
  ///
  /// In en, this message translates to:
  /// **'Device {tokenPrefix}'**
  String deviceToken(String tokenPrefix);

  /// No description provided for @current.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get current;

  /// No description provided for @paired.
  ///
  /// In en, this message translates to:
  /// **'Paired'**
  String get paired;

  /// No description provided for @revokeDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke device?'**
  String get revokeDeviceTitle;

  /// No description provided for @revokeDeviceBody.
  ///
  /// In en, this message translates to:
  /// **'This device will be signed out immediately.'**
  String get revokeDeviceBody;

  /// No description provided for @disable2faTitle.
  ///
  /// In en, this message translates to:
  /// **'Disable 2FA?'**
  String get disable2faTitle;

  /// No description provided for @disable2faConfirmation.
  ///
  /// In en, this message translates to:
  /// **'This will remove TOTP-based two-factor authentication from your account. Are you sure?'**
  String get disable2faConfirmation;

  /// No description provided for @disable2fa.
  ///
  /// In en, this message translates to:
  /// **'Disable 2FA'**
  String get disable2fa;

  /// No description provided for @twoFactorAuthentication.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication'**
  String get twoFactorAuthentication;

  /// No description provided for @twoFactorShort.
  ///
  /// In en, this message translates to:
  /// **'2FA'**
  String get twoFactorShort;

  /// No description provided for @user.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get user;

  /// No description provided for @active.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get active;

  /// No description provided for @noUsersYet.
  ///
  /// In en, this message translates to:
  /// **'No users yet.'**
  String get noUsersYet;

  /// No description provided for @command.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get command;

  /// No description provided for @providerIsReachable.
  ///
  /// In en, this message translates to:
  /// **'Provider is reachable'**
  String get providerIsReachable;

  /// No description provided for @providerCommandHint.
  ///
  /// In en, this message translates to:
  /// **'devin'**
  String get providerCommandHint;

  /// No description provided for @providerTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Provider test failed: {error}'**
  String providerTestFailed(String error);

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @menu.
  ///
  /// In en, this message translates to:
  /// **'Menu'**
  String get menu;

  /// No description provided for @newThreadIn.
  ///
  /// In en, this message translates to:
  /// **'New thread in {projectName}'**
  String newThreadIn(String projectName);

  /// No description provided for @noProjectsYet.
  ///
  /// In en, this message translates to:
  /// **'No projects yet.\nCreate one to get started.'**
  String get noProjectsYet;

  /// No description provided for @noThreadsYet.
  ///
  /// In en, this message translates to:
  /// **'No threads yet'**
  String get noThreadsYet;

  /// No description provided for @deleteThreadConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this thread? This cannot be undone.'**
  String get deleteThreadConfirm;

  /// No description provided for @deleteThreadTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete thread (Shift+click to skip confirmation)'**
  String get deleteThreadTooltip;

  /// No description provided for @deleteProjectConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{name}\" from Devinorium? This deletes the project and all its threads from the database. The folder on disk is not touched.'**
  String deleteProjectConfirm(String name);

  /// No description provided for @deleteProject.
  ///
  /// In en, this message translates to:
  /// **'Delete project'**
  String get deleteProject;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @checkingConnection.
  ///
  /// In en, this message translates to:
  /// **'Checking connection…'**
  String get checkingConnection;

  /// No description provided for @topics.
  ///
  /// In en, this message translates to:
  /// **'Topics'**
  String get topics;

  /// No description provided for @timeAgoJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get timeAgoJustNow;

  /// No description provided for @timeAgoMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count}m ago'**
  String timeAgoMinutes(int count);

  /// No description provided for @timeAgoHours.
  ///
  /// In en, this message translates to:
  /// **'{count}h ago'**
  String timeAgoHours(int count);

  /// No description provided for @timeAgoDays.
  ///
  /// In en, this message translates to:
  /// **'{count}d ago'**
  String timeAgoDays(int count);

  /// No description provided for @timeAgoMonths.
  ///
  /// In en, this message translates to:
  /// **'{count}mo ago'**
  String timeAgoMonths(int count);

  /// No description provided for @timeAgoYears.
  ///
  /// In en, this message translates to:
  /// **'{count}y ago'**
  String timeAgoYears(int count);

  /// No description provided for @selectOrCreateThread.
  ///
  /// In en, this message translates to:
  /// **'Select or create a thread'**
  String get selectOrCreateThread;

  /// No description provided for @fileManager.
  ///
  /// In en, this message translates to:
  /// **'File manager'**
  String get fileManager;

  /// No description provided for @selectOrCreateThreadToChat.
  ///
  /// In en, this message translates to:
  /// **'Select or create a thread to start chatting.'**
  String get selectOrCreateThreadToChat;

  /// No description provided for @startConversationHint.
  ///
  /// In en, this message translates to:
  /// **'Start the conversation by sending a message below.'**
  String get startConversationHint;

  /// No description provided for @messageRoleYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get messageRoleYou;

  /// No description provided for @messageRoleAssistant.
  ///
  /// In en, this message translates to:
  /// **'Assistant'**
  String get messageRoleAssistant;

  /// No description provided for @messageRoleError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get messageRoleError;

  /// No description provided for @thinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get thinking;

  /// No description provided for @hideThinking.
  ///
  /// In en, this message translates to:
  /// **'Hide thinking'**
  String get hideThinking;

  /// No description provided for @showThinking.
  ///
  /// In en, this message translates to:
  /// **'Show thinking'**
  String get showThinking;

  /// No description provided for @composerHint.
  ///
  /// In en, this message translates to:
  /// **'Ask a question or drop files here'**
  String get composerHint;

  /// No description provided for @permissionModeNormal.
  ///
  /// In en, this message translates to:
  /// **'Ask every time'**
  String get permissionModeNormal;

  /// No description provided for @permissionModeAcceptEdits.
  ///
  /// In en, this message translates to:
  /// **'Confirm edits'**
  String get permissionModeAcceptEdits;

  /// No description provided for @permissionModeSmart.
  ///
  /// In en, this message translates to:
  /// **'Smart confirm'**
  String get permissionModeSmart;

  /// No description provided for @permissionModeBypass.
  ///
  /// In en, this message translates to:
  /// **'Auto-run'**
  String get permissionModeBypass;

  /// No description provided for @preview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get preview;

  /// No description provided for @output.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get output;

  /// No description provided for @changed.
  ///
  /// In en, this message translates to:
  /// **'Changed'**
  String get changed;

  /// No description provided for @tagNeedsApproval.
  ///
  /// In en, this message translates to:
  /// **'Needs approval'**
  String get tagNeedsApproval;

  /// No description provided for @tagRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get tagRunning;

  /// No description provided for @tagWorking.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get tagWorking;

  /// No description provided for @tagFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get tagFailed;

  /// No description provided for @tagDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get tagDone;

  /// No description provided for @tagStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get tagStopped;

  /// No description provided for @noValue.
  ///
  /// In en, this message translates to:
  /// **'—'**
  String get noValue;

  /// No description provided for @tokensMillionSuffix.
  ///
  /// In en, this message translates to:
  /// **'{count}M'**
  String tokensMillionSuffix(String count);

  /// No description provided for @tokensThousandSuffix.
  ///
  /// In en, this message translates to:
  /// **'{count}K'**
  String tokensThousandSuffix(String count);

  /// No description provided for @tokensCount.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String tokensCount(String count);

  /// No description provided for @sizeBytes.
  ///
  /// In en, this message translates to:
  /// **'{count} B'**
  String sizeBytes(String count);

  /// No description provided for @sizeKilobytes.
  ///
  /// In en, this message translates to:
  /// **'{count} KB'**
  String sizeKilobytes(String count);

  /// No description provided for @sizeMegabytes.
  ///
  /// In en, this message translates to:
  /// **'{count} MB'**
  String sizeMegabytes(String count);

  /// No description provided for @breadcrumbSeparator.
  ///
  /// In en, this message translates to:
  /// **' / '**
  String get breadcrumbSeparator;

  /// No description provided for @messageLoading.
  ///
  /// In en, this message translates to:
  /// **'...'**
  String get messageLoading;

  /// No description provided for @readFileTitle.
  ///
  /// In en, this message translates to:
  /// **'Read {fileName}'**
  String readFileTitle(String fileName);

  /// No description provided for @readFileLineCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 line} other{{count} lines}}'**
  String readFileLineCount(int count);

  /// No description provided for @readFileLineRange.
  ///
  /// In en, this message translates to:
  /// **'{start}-{end}'**
  String readFileLineRange(int start, int end);

  /// No description provided for @readFileNoContent.
  ///
  /// In en, this message translates to:
  /// **'No content'**
  String get readFileNoContent;

  /// No description provided for @editFileNoDiff.
  ///
  /// In en, this message translates to:
  /// **'No diff content yet'**
  String get editFileNoDiff;

  /// No description provided for @editFileOpenInFiles.
  ///
  /// In en, this message translates to:
  /// **'Open in files'**
  String get editFileOpenInFiles;

  /// No description provided for @gitBranches.
  ///
  /// In en, this message translates to:
  /// **'Branches'**
  String get gitBranches;

  /// No description provided for @pull.
  ///
  /// In en, this message translates to:
  /// **'Pull'**
  String get pull;

  /// No description provided for @push.
  ///
  /// In en, this message translates to:
  /// **'Push'**
  String get push;

  /// No description provided for @notAGitRepo.
  ///
  /// In en, this message translates to:
  /// **'This project is not a Git repository.'**
  String get notAGitRepo;

  /// No description provided for @searchBranches.
  ///
  /// In en, this message translates to:
  /// **'Search branches'**
  String get searchBranches;

  /// No description provided for @createBranch.
  ///
  /// In en, this message translates to:
  /// **'Create branch'**
  String get createBranch;

  /// No description provided for @branchName.
  ///
  /// In en, this message translates to:
  /// **'Branch name'**
  String get branchName;

  /// No description provided for @baseBranchOptional.
  ///
  /// In en, this message translates to:
  /// **'Base branch (optional)'**
  String get baseBranchOptional;

  /// No description provided for @switchAfterCreate.
  ///
  /// In en, this message translates to:
  /// **'Switch to new branch'**
  String get switchAfterCreate;

  /// No description provided for @createWorktree.
  ///
  /// In en, this message translates to:
  /// **'Create worktree'**
  String get createWorktree;

  /// No description provided for @worktreeName.
  ///
  /// In en, this message translates to:
  /// **'Worktree name'**
  String get worktreeName;

  /// No description provided for @baseBranch.
  ///
  /// In en, this message translates to:
  /// **'Base branch'**
  String get baseBranch;

  /// No description provided for @newBranchInWorktree.
  ///
  /// In en, this message translates to:
  /// **'Create new branch in worktree'**
  String get newBranchInWorktree;

  /// No description provided for @worktrees.
  ///
  /// In en, this message translates to:
  /// **'Worktrees'**
  String get worktrees;

  /// No description provided for @git.
  ///
  /// In en, this message translates to:
  /// **'Git'**
  String get git;

  /// No description provided for @gitConnections.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get gitConnections;

  /// No description provided for @gitlab.
  ///
  /// In en, this message translates to:
  /// **'GitLab'**
  String get gitlab;

  /// No description provided for @github.
  ///
  /// In en, this message translates to:
  /// **'GitHub'**
  String get github;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get comingSoon;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get notConnected;

  /// No description provided for @connectedAs.
  ///
  /// In en, this message translates to:
  /// **'Connected as {account}'**
  String connectedAs(String account);

  /// No description provided for @token.
  ///
  /// In en, this message translates to:
  /// **'Token'**
  String get token;

  /// No description provided for @hostname.
  ///
  /// In en, this message translates to:
  /// **'Hostname'**
  String get hostname;

  /// No description provided for @gitlabComHint.
  ///
  /// In en, this message translates to:
  /// **'gitlab.com'**
  String get gitlabComHint;

  /// No description provided for @gitlabConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'GitLab connect failed: {error}'**
  String gitlabConnectFailed(String error);

  /// No description provided for @gitlabDisconnectFailed.
  ///
  /// In en, this message translates to:
  /// **'GitLab disconnect failed: {error}'**
  String gitlabDisconnectFailed(String error);

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get loading;

  /// No description provided for @gitlabNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'GitLab CLI (glab) is not installed'**
  String get gitlabNotInstalled;

  /// No description provided for @none.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get none;

  /// No description provided for @createAndSwitchBranch.
  ///
  /// In en, this message translates to:
  /// **'Create and switch'**
  String get createAndSwitchBranch;

  /// No description provided for @createAndNewBranch.
  ///
  /// In en, this message translates to:
  /// **'Create and new branch'**
  String get createAndNewBranch;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @stopGenerating.
  ///
  /// In en, this message translates to:
  /// **'Stop generating'**
  String get stopGenerating;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @completionNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notify when a thread completes'**
  String get completionNotifications;

  /// No description provided for @completionNotificationsDescription.
  ///
  /// In en, this message translates to:
  /// **'Show a browser notification when a thread run finishes while this tab is in the background.'**
  String get completionNotificationsDescription;

  /// No description provided for @completionSound.
  ///
  /// In en, this message translates to:
  /// **'Play sound on completion'**
  String get completionSound;

  /// No description provided for @completionSoundDescription.
  ///
  /// In en, this message translates to:
  /// **'Play a short tone when a thread run finishes while this tab is in the background.'**
  String get completionSoundDescription;

  /// No description provided for @threadCompletedTitle.
  ///
  /// In en, this message translates to:
  /// **'Thread completed'**
  String get threadCompletedTitle;

  /// No description provided for @threadCompletedBody.
  ///
  /// In en, this message translates to:
  /// **'{title} has finished running.'**
  String threadCompletedBody(String title);

  /// No description provided for @threadFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Thread failed'**
  String get threadFailedTitle;

  /// No description provided for @threadFailedBody.
  ///
  /// In en, this message translates to:
  /// **'{title} encountered an error.'**
  String threadFailedBody(String title);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
