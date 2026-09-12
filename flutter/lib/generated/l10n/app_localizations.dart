import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

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
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// Application title shown in the sidebar
  ///
  /// In en, this message translates to:
  /// **'Devinorium'**
  String get appTitle;

  /// Label for the application name on the About page
  ///
  /// In en, this message translates to:
  /// **'App name'**
  String get appName;

  /// About section title in settings
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// Short description shown on the About page
  ///
  /// In en, this message translates to:
  /// **'Bring your agents anywhere'**
  String get aboutDescription;

  /// Version label on the About page
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get aboutVersion;

  /// License label on the About page
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get aboutLicense;

  /// Source code link label on the About page
  ///
  /// In en, this message translates to:
  /// **'Source code'**
  String get aboutSourceCode;

  /// Support link label on the About page
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get aboutSupport;

  /// Privacy policy link label on the About page
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get aboutPrivacyPolicy;

  /// Error shown when an About page link cannot be opened
  ///
  /// In en, this message translates to:
  /// **'Could not open {url}'**
  String aboutOpenLinkFailed(String url);

  /// Releases link label on the About page
  ///
  /// In en, this message translates to:
  /// **'Releases'**
  String get aboutReleases;

  /// Button on the About page that checks for a newer release
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get aboutCheckForUpdates;

  /// Subtitle under the check-for-updates button on the About page
  ///
  /// In en, this message translates to:
  /// **'Check GitLab for a newer release'**
  String get aboutCheckForUpdatesSubtitle;

  /// Message shown when an update check finds no newer release
  ///
  /// In en, this message translates to:
  /// **'You are on the latest version'**
  String get aboutUpToDate;

  /// Message shown when the update check itself fails
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates'**
  String get aboutUpdateCheckFailed;

  /// Chip shown on the About page when a newer release exists
  ///
  /// In en, this message translates to:
  /// **'Update available: {version}'**
  String appUpdateAvailable(String version);

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

  /// No description provided for @totpOptional.
  ///
  /// In en, this message translates to:
  /// **'Optional — only if your account has 2FA enabled'**
  String get totpOptional;

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

  /// No description provided for @windowClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get windowClose;

  /// No description provided for @windowMinimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize'**
  String get windowMinimize;

  /// No description provided for @windowZoom.
  ///
  /// In en, this message translates to:
  /// **'Zoom'**
  String get windowZoom;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

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

  /// No description provided for @addProject.
  ///
  /// In en, this message translates to:
  /// **'Add project'**
  String get addProject;

  /// No description provided for @addProjectLocalTitle.
  ///
  /// In en, this message translates to:
  /// **'Local folder'**
  String get addProjectLocalTitle;

  /// No description provided for @addProjectLocalDescription.
  ///
  /// In en, this message translates to:
  /// **'Browse a folder on disk'**
  String get addProjectLocalDescription;

  /// No description provided for @addProjectCloneDescription.
  ///
  /// In en, this message translates to:
  /// **'Clone from a remote URL'**
  String get addProjectCloneDescription;

  /// No description provided for @cloneRepo.
  ///
  /// In en, this message translates to:
  /// **'Clone repository'**
  String get cloneRepo;

  /// No description provided for @cloneRepoDescription.
  ///
  /// In en, this message translates to:
  /// **'Clone a remote repository into the configured clone root.'**
  String get cloneRepoDescription;

  /// No description provided for @cloneRepoUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Remote URL'**
  String get cloneRepoUrlLabel;

  /// No description provided for @cloneRepoButton.
  ///
  /// In en, this message translates to:
  /// **'Clone'**
  String get cloneRepoButton;

  /// No description provided for @cloneRepoOpenProject.
  ///
  /// In en, this message translates to:
  /// **'Open project'**
  String get cloneRepoOpenProject;

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

  /// No description provided for @pin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get pin;

  /// No description provided for @unpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get unpin;

  /// No description provided for @pinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinned;

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

  /// No description provided for @attachSourcePhotoLibrary.
  ///
  /// In en, this message translates to:
  /// **'Photo Library'**
  String get attachSourcePhotoLibrary;

  /// No description provided for @attachSourceTakePhotoOrVideo.
  ///
  /// In en, this message translates to:
  /// **'Take Photo or Video'**
  String get attachSourceTakePhotoOrVideo;

  /// No description provided for @attachSourceTakePhoto.
  ///
  /// In en, this message translates to:
  /// **'Take Photo'**
  String get attachSourceTakePhoto;

  /// No description provided for @attachSourceRecordVideo.
  ///
  /// In en, this message translates to:
  /// **'Record Video'**
  String get attachSourceRecordVideo;

  /// No description provided for @attachSourceBrowse.
  ///
  /// In en, this message translates to:
  /// **'Browse'**
  String get attachSourceBrowse;

  /// No description provided for @removeAttachment.
  ///
  /// In en, this message translates to:
  /// **'Remove attachment'**
  String get removeAttachment;

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

  /// Label for the reasoning effort dropdown
  ///
  /// In en, this message translates to:
  /// **'Reasoning'**
  String get reasoning;

  /// Badge shown next to the provider's default reasoning level
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get reasoningDefault;

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

  /// No description provided for @providerVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get providerVersion;

  /// No description provided for @providerUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get providerUpToDate;

  /// No description provided for @providerUpdateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available: {version}'**
  String providerUpdateAvailable(String version);

  /// No description provided for @providerIsReachable.
  ///
  /// In en, this message translates to:
  /// **'Provider is reachable'**
  String get providerIsReachable;

  /// No description provided for @providerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get providerUnavailable;

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

  /// Label for the English language option in settings
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// Label for the Simplified Chinese language option in settings
  ///
  /// In en, this message translates to:
  /// **'Simplified Chinese'**
  String get languageSimplifiedChinese;

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

  /// No description provided for @deleteThread.
  ///
  /// In en, this message translates to:
  /// **'Delete thread'**
  String get deleteThread;

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

  /// Label for the connected server version row in settings
  ///
  /// In en, this message translates to:
  /// **'Server version'**
  String get serverVersion;

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

  /// No description provided for @terminal.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get terminal;

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

  /// Label for the settings dropdown picking the permission level new threads start with
  ///
  /// In en, this message translates to:
  /// **'Default permission level'**
  String get defaultPermissionLevel;

  /// Hint under the default permission level setting clarifying it does not change the open thread
  ///
  /// In en, this message translates to:
  /// **'Applied to new threads'**
  String get defaultPermissionLevelHint;

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

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @commit.
  ///
  /// In en, this message translates to:
  /// **'Commit'**
  String get commit;

  /// No description provided for @commitMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Commit message'**
  String get commitMessageHint;

  /// No description provided for @stage.
  ///
  /// In en, this message translates to:
  /// **'Stage'**
  String get stage;

  /// No description provided for @unstage.
  ///
  /// In en, this message translates to:
  /// **'Unstage'**
  String get unstage;

  /// No description provided for @stageAll.
  ///
  /// In en, this message translates to:
  /// **'Stage all'**
  String get stageAll;

  /// No description provided for @unstageAll.
  ///
  /// In en, this message translates to:
  /// **'Unstage all'**
  String get unstageAll;

  /// No description provided for @stagedChanges.
  ///
  /// In en, this message translates to:
  /// **'Staged changes'**
  String get stagedChanges;

  /// No description provided for @notGitRepo.
  ///
  /// In en, this message translates to:
  /// **'Not a git repository'**
  String get notGitRepo;

  /// No description provided for @gitUnsupportedBackend.
  ///
  /// In en, this message translates to:
  /// **'This server is too old for the Git panel. Update the backend and restart the app.'**
  String get gitUnsupportedBackend;

  /// No description provided for @gitCommitAllConfirm.
  ///
  /// In en, this message translates to:
  /// **'There are no staged changes. Stage all changes and commit?'**
  String get gitCommitAllConfirm;

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @discardAll.
  ///
  /// In en, this message translates to:
  /// **'Discard all'**
  String get discardAll;

  /// No description provided for @discardFileConfirm.
  ///
  /// In en, this message translates to:
  /// **'Discard all changes to {path}? This cannot be undone.'**
  String discardFileConfirm(String path);

  /// No description provided for @discardUntrackedConfirm.
  ///
  /// In en, this message translates to:
  /// **'Permanently delete {path}? This cannot be undone.'**
  String discardUntrackedConfirm(String path);

  /// No description provided for @discardAllConfirm.
  ///
  /// In en, this message translates to:
  /// **'Discard all {count} changed files? This cannot be undone.'**
  String discardAllConfirm(int count);

  /// No description provided for @history.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get history;

  /// No description provided for @noCommits.
  ///
  /// In en, this message translates to:
  /// **'No commits yet'**
  String get noCommits;

  /// No description provided for @noDiffAvailable.
  ///
  /// In en, this message translates to:
  /// **'No diff preview available'**
  String get noDiffAvailable;

  /// No description provided for @openFile.
  ///
  /// In en, this message translates to:
  /// **'Open file'**
  String get openFile;

  /// No description provided for @copySha.
  ///
  /// In en, this message translates to:
  /// **'Copy commit SHA'**
  String get copySha;

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

  /// No description provided for @mainWorktree.
  ///
  /// In en, this message translates to:
  /// **'Main worktree'**
  String get mainWorktree;

  /// No description provided for @worktreeBranchLocked.
  ///
  /// In en, this message translates to:
  /// **'Switch back to the main worktree to change branches'**
  String get worktreeBranchLocked;

  /// No description provided for @envModeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Run mode'**
  String get envModeTooltip;

  /// No description provided for @localMode.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get localMode;

  /// No description provided for @localModeShort.
  ///
  /// In en, this message translates to:
  /// **'local'**
  String get localModeShort;

  /// No description provided for @worktreeMode.
  ///
  /// In en, this message translates to:
  /// **'Worktree'**
  String get worktreeMode;

  /// No description provided for @worktreeModeShort.
  ///
  /// In en, this message translates to:
  /// **'worktree'**
  String get worktreeModeShort;

  /// No description provided for @deleteWorktree.
  ///
  /// In en, this message translates to:
  /// **'Delete worktree'**
  String get deleteWorktree;

  /// No description provided for @deleteWorktreeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the worktree at {path}? Any uncommitted changes in it will be lost.'**
  String deleteWorktreeConfirm(String path);

  /// No description provided for @deleteWorktreeThreadsConfirm.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{The thread \"{names}\" uses this worktree. Deleting it will delete the thread too. Are you sure?} other{{count} threads use this worktree ({names}). Deleting it will delete them too. Are you sure?}}'**
  String deleteWorktreeThreadsConfirm(int count, String names);

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

  /// No description provided for @gitlabConnectHint.
  ///
  /// In en, this message translates to:
  /// **'Run glab auth login in your terminal, then tap Connect.'**
  String get gitlabConnectHint;

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

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previous;

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

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @copiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copiedToClipboard;

  /// No description provided for @mergeRequest.
  ///
  /// In en, this message translates to:
  /// **'Merge request'**
  String get mergeRequest;

  /// No description provided for @linkMergeRequest.
  ///
  /// In en, this message translates to:
  /// **'Link merge request'**
  String get linkMergeRequest;

  /// No description provided for @unlinkMergeRequest.
  ///
  /// In en, this message translates to:
  /// **'Unlink merge request'**
  String get unlinkMergeRequest;

  /// No description provided for @mergeRequestUrlHint.
  ///
  /// In en, this message translates to:
  /// **'GitLab merge request URL'**
  String get mergeRequestUrlHint;

  /// No description provided for @invalidMergeRequestUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid GitLab merge request URL'**
  String get invalidMergeRequestUrl;

  /// No description provided for @overview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get overview;

  /// No description provided for @changes.
  ///
  /// In en, this message translates to:
  /// **'Changes'**
  String get changes;

  /// No description provided for @comments.
  ///
  /// In en, this message translates to:
  /// **'Comments'**
  String get comments;

  /// No description provided for @pipelines.
  ///
  /// In en, this message translates to:
  /// **'Pipelines'**
  String get pipelines;

  /// No description provided for @noDescription.
  ///
  /// In en, this message translates to:
  /// **'No description provided.'**
  String get noDescription;

  /// No description provided for @noChanges.
  ///
  /// In en, this message translates to:
  /// **'No changed files.'**
  String get noChanges;

  /// No description provided for @changesFileCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 file} other{{count} files}}'**
  String changesFileCount(int count);

  /// No description provided for @noComments.
  ///
  /// In en, this message translates to:
  /// **'No comments yet.'**
  String get noComments;

  /// No description provided for @noPipelines.
  ///
  /// In en, this message translates to:
  /// **'No pipelines yet.'**
  String get noPipelines;

  /// No description provided for @noJobs.
  ///
  /// In en, this message translates to:
  /// **'No jobs yet.'**
  String get noJobs;

  /// No description provided for @noJobLog.
  ///
  /// In en, this message translates to:
  /// **'No log output yet.'**
  String get noJobLog;

  /// No description provided for @jobLogLive.
  ///
  /// In en, this message translates to:
  /// **'LIVE'**
  String get jobLogLive;

  /// No description provided for @openInBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open in browser'**
  String get openInBrowser;

  /// No description provided for @openLink.
  ///
  /// In en, this message translates to:
  /// **'Open link'**
  String get openLink;

  /// No description provided for @copyLink.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get copyLink;

  /// No description provided for @linkToThread.
  ///
  /// In en, this message translates to:
  /// **'Link to thread'**
  String get linkToThread;

  /// No description provided for @unlinkFromThread.
  ///
  /// In en, this message translates to:
  /// **'Unlink from thread'**
  String get unlinkFromThread;

  /// No description provided for @draft.
  ///
  /// In en, this message translates to:
  /// **'Draft'**
  String get draft;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @merge.
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get merge;

  /// No description provided for @mergeWhenPipelineSucceeds.
  ///
  /// In en, this message translates to:
  /// **'Merge when pipeline succeeds'**
  String get mergeWhenPipelineSucceeds;

  /// No description provided for @cancelAutoMerge.
  ///
  /// In en, this message translates to:
  /// **'Cancel auto merge'**
  String get cancelAutoMerge;

  /// No description provided for @closeMergeRequest.
  ///
  /// In en, this message translates to:
  /// **'Close merge request'**
  String get closeMergeRequest;

  /// No description provided for @reopenMergeRequest.
  ///
  /// In en, this message translates to:
  /// **'Reopen merge request'**
  String get reopenMergeRequest;

  /// No description provided for @mergeRequestDraftBlocked.
  ///
  /// In en, this message translates to:
  /// **'Mark the merge request ready before merging.'**
  String get mergeRequestDraftBlocked;

  /// No description provided for @mergeRequestConflictsBlocked.
  ///
  /// In en, this message translates to:
  /// **'Resolve the conflicts before merging.'**
  String get mergeRequestConflictsBlocked;

  /// No description provided for @mergeRequestAutoMergeSet.
  ///
  /// In en, this message translates to:
  /// **'This merge request will merge once the pipeline succeeds.'**
  String get mergeRequestAutoMergeSet;

  /// No description provided for @mergeRequestWorking.
  ///
  /// In en, this message translates to:
  /// **'Working...'**
  String get mergeRequestWorking;

  /// No description provided for @issue.
  ///
  /// In en, this message translates to:
  /// **'Issue'**
  String get issue;

  /// No description provided for @issueOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get issueOpen;

  /// No description provided for @issueClosed.
  ///
  /// In en, this message translates to:
  /// **'Closed'**
  String get issueClosed;

  /// No description provided for @issueLabels.
  ///
  /// In en, this message translates to:
  /// **'Labels'**
  String get issueLabels;

  /// No description provided for @issueNoDescription.
  ///
  /// In en, this message translates to:
  /// **'No description provided.'**
  String get issueNoDescription;

  /// No description provided for @issueComments.
  ///
  /// In en, this message translates to:
  /// **'Comments'**
  String get issueComments;

  /// No description provided for @issueLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load issue'**
  String get issueLoadFailed;

  /// No description provided for @issueOpenInBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open in browser'**
  String get issueOpenInBrowser;

  /// No description provided for @cloneRoot.
  ///
  /// In en, this message translates to:
  /// **'Clone root'**
  String get cloneRoot;

  /// No description provided for @cloneRootDescription.
  ///
  /// In en, this message translates to:
  /// **'Directory where cloned repositories are placed.'**
  String get cloneRootDescription;

  /// No description provided for @cloneRootNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set yet'**
  String get cloneRootNotSet;

  /// No description provided for @cloneRootSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get cloneRootSave;

  /// No description provided for @cloneRootBrowse.
  ///
  /// In en, this message translates to:
  /// **'Browse...'**
  String get cloneRootBrowse;

  /// No description provided for @cloneRootOnlyOwner.
  ///
  /// In en, this message translates to:
  /// **'Only the owner can change the clone root.'**
  String get cloneRootOnlyOwner;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search threads...'**
  String get searchHint;

  /// No description provided for @searchKeyboardShortcut.
  ///
  /// In en, this message translates to:
  /// **'⌘K'**
  String get searchKeyboardShortcut;

  /// No description provided for @searchKeyboardShortcutNonMac.
  ///
  /// In en, this message translates to:
  /// **'Ctrl+H'**
  String get searchKeyboardShortcutNonMac;

  /// No description provided for @noSearchResults.
  ///
  /// In en, this message translates to:
  /// **'No threads found.'**
  String get noSearchResults;

  /// No description provided for @threadStatusWorking.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get threadStatusWorking;

  /// No description provided for @threadStatusDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get threadStatusDone;

  /// No description provided for @threadStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get threadStatusFailed;

  /// No description provided for @threadStatusApproval.
  ///
  /// In en, this message translates to:
  /// **'Approval'**
  String get threadStatusApproval;

  /// No description provided for @threadStatusInput.
  ///
  /// In en, this message translates to:
  /// **'Input'**
  String get threadStatusInput;

  /// No description provided for @showMoreThreads.
  ///
  /// In en, this message translates to:
  /// **'Show {count} more'**
  String showMoreThreads(int count);

  /// No description provided for @loadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get loadMore;

  /// Servers section title in settings and the sidebar switcher
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get servers;

  /// Menu item to open the server settings
  ///
  /// In en, this message translates to:
  /// **'Manage servers'**
  String get manageServers;

  /// Tooltip for the quick server switcher
  ///
  /// In en, this message translates to:
  /// **'Switch server'**
  String get switchServer;

  /// Empty state shown when no servers are saved
  ///
  /// In en, this message translates to:
  /// **'No servers configured.'**
  String get noServersConfigured;

  /// Message shown in settings when running as a web app
  ///
  /// In en, this message translates to:
  /// **'Server switching is not available in the web build.'**
  String get serverSwitchNotAvailableWeb;

  /// Label for the bundled local server profile
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get thisDevice;

  /// Subtitle for the bundled local server entry in the server list
  ///
  /// In en, this message translates to:
  /// **'Bundled server'**
  String get bundledServer;

  /// Fallback label for the implicit web server profile
  ///
  /// In en, this message translates to:
  /// **'web'**
  String get web;

  /// Button and dialog title for adding a new server
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get addServer;

  /// Empty state in the thread page when no server is connected
  ///
  /// In en, this message translates to:
  /// **'No server configured.\nAdd a server in Settings to get started.'**
  String get addServerFromSettingsPrompt;

  /// Button text to activate a different server profile
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get switchServerLabel;

  /// Confirmation before removing a saved server profile
  ///
  /// In en, this message translates to:
  /// **'Remove \"{name}\" from Devinorium? This will delete the saved connection.'**
  String deleteServerConfirm(String name);

  /// Hint for the add-server URL field, which requires a scheme
  ///
  /// In en, this message translates to:
  /// **'http://localhost:7878'**
  String get serverUrlWithSchemeHint;

  /// Validation error when the add-server URL is missing a scheme
  ///
  /// In en, this message translates to:
  /// **'URL must start with http:// or https://'**
  String get serverUrlMustIncludeScheme;

  /// OLED built-in theme option
  ///
  /// In en, this message translates to:
  /// **'OLED'**
  String get oledTheme;

  /// Label for a user-supplied custom theme
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get themeCustom;

  /// Button to open the custom theme import dialog
  ///
  /// In en, this message translates to:
  /// **'Import custom'**
  String get themeImport;

  /// Hint text in the custom theme import dialog
  ///
  /// In en, this message translates to:
  /// **'Paste a restricted CSS file below. Only :root and color values are allowed.'**
  String get themeImportHint;

  /// Error shown when a custom theme file cannot be parsed
  ///
  /// In en, this message translates to:
  /// **'Failed to import theme'**
  String get themeImportError;

  /// Label for the theme creator metadata field
  ///
  /// In en, this message translates to:
  /// **'Creator'**
  String get themeCreator;

  /// Label for the theme version metadata field
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get themeVersion;

  /// Label for the theme description metadata field
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get themeDescription;

  /// Label for the content tab in the file viewer
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get fileViewerContent;

  /// Label for the diff tab in the file viewer
  ///
  /// In en, this message translates to:
  /// **'Diff'**
  String get fileViewerDiff;

  /// Label shown when a file cannot be previewed as text
  ///
  /// In en, this message translates to:
  /// **'Binary file'**
  String get fileViewerBinaryFile;

  /// Error shown when the file viewer fails to load a file
  ///
  /// In en, this message translates to:
  /// **'Failed to load file'**
  String get fileViewerLoadError;

  /// No description provided for @agentsMode.
  ///
  /// In en, this message translates to:
  /// **'Agents'**
  String get agentsMode;

  /// No description provided for @editorMode.
  ///
  /// In en, this message translates to:
  /// **'Editor'**
  String get editorMode;

  /// No description provided for @chat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get chat;

  /// No description provided for @editorSelectFile.
  ///
  /// In en, this message translates to:
  /// **'Select a file from the tree to edit'**
  String get editorSelectFile;

  /// No description provided for @editorUnsavedChanges.
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes'**
  String get editorUnsavedChanges;

  /// No description provided for @editorSaveBeforeClose.
  ///
  /// In en, this message translates to:
  /// **'Save changes to {name}?'**
  String editorSaveBeforeClose(String name);

  /// No description provided for @editorReload.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get editorReload;

  /// No description provided for @binaryFileNotEditable.
  ///
  /// In en, this message translates to:
  /// **'{name} is a binary file and cannot be edited'**
  String binaryFileNotEditable(String name);

  /// No description provided for @editorDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get editorDiscard;

  /// Note shown when a diff is truncated
  ///
  /// In en, this message translates to:
  /// **'… {count} more lines not shown'**
  String diffViewMoreLines(int count);

  /// Note shown when a file's content is truncated
  ///
  /// In en, this message translates to:
  /// **'… {count} more lines not shown'**
  String contentViewMoreLines(int count);

  /// Button label to show the rest of a truncated file
  ///
  /// In en, this message translates to:
  /// **'Show all'**
  String get contentViewShowAll;

  /// Button that expands a truncated message
  ///
  /// In en, this message translates to:
  /// **'Show more'**
  String get showMore;

  /// Label shown while additional message content is loading
  ///
  /// In en, this message translates to:
  /// **'Loading more…'**
  String get loadingMore;

  /// Empty state shown when no terminal sessions exist
  ///
  /// In en, this message translates to:
  /// **'No terminal sessions'**
  String get terminalNoSessions;

  /// Label for a terminal tab
  ///
  /// In en, this message translates to:
  /// **'Tab {index}'**
  String terminalTab(int index);

  /// Tooltip for the button that opens a new terminal tab
  ///
  /// In en, this message translates to:
  /// **'New tab'**
  String get terminalNewTab;

  /// Tooltip for closing a terminal tab
  ///
  /// In en, this message translates to:
  /// **'Close tab'**
  String get terminalCloseTab;

  /// Tooltip for closing a terminal session
  ///
  /// In en, this message translates to:
  /// **'Close terminal'**
  String get terminalClose;

  /// Tooltip for adding a local terminal
  ///
  /// In en, this message translates to:
  /// **'Local terminal'**
  String get terminalLocal;

  /// Tooltip for adding a remote terminal
  ///
  /// In en, this message translates to:
  /// **'Remote terminal'**
  String get terminalRemote;

  /// Tooltip for hiding the terminal panel
  ///
  /// In en, this message translates to:
  /// **'Hide terminal'**
  String get terminalHide;

  /// Error shown when a terminal session cannot be started
  ///
  /// In en, this message translates to:
  /// **'Failed to start terminal: {error}'**
  String terminalStartFailed(String error);

  /// Title of the confirmation dialog before closing a terminal
  ///
  /// In en, this message translates to:
  /// **'Close terminal?'**
  String get terminalCloseTitle;

  /// Body of the confirmation dialog before closing a terminal
  ///
  /// In en, this message translates to:
  /// **'This terminal has running processes or output. Close it anyway?'**
  String get terminalCloseBody;

  /// Title of the confirmation dialog before closing a terminal tab
  ///
  /// In en, this message translates to:
  /// **'Close tab?'**
  String get terminalTabCloseTitle;

  /// Body of the confirmation dialog before closing a terminal tab
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{This tab contains 1 active terminal. Close it anyway?} other{This tab contains {count} active terminals. Close it anyway?}}'**
  String terminalTabCloseBody(int count);

  /// Tooltip for hiding the plan overlay
  ///
  /// In en, this message translates to:
  /// **'Hide plan'**
  String get planHide;

  /// Tooltip for showing the plan overlay
  ///
  /// In en, this message translates to:
  /// **'Show plan'**
  String get planShow;

  /// Tooltip for collapsing the plan overlay
  ///
  /// In en, this message translates to:
  /// **'Collapse plan'**
  String get planCollapse;

  /// Tooltip for expanding the plan overlay
  ///
  /// In en, this message translates to:
  /// **'Expand plan'**
  String get planExpand;

  /// Fallback title for the plan overlay
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get planTitle;

  /// Progress line in the plan overlay
  ///
  /// In en, this message translates to:
  /// **'{completed} / {total} {total, plural, =1{step} other{steps}} · {percent}%'**
  String planProgress(int completed, int total, int percent);

  /// Label for the code composer mode
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get composerModeCode;

  /// Label for the plan composer mode
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get composerModePlan;

  /// Label for the ask composer mode
  ///
  /// In en, this message translates to:
  /// **'Ask'**
  String get composerModeAsk;

  /// Message written to a terminal when the local backend is unavailable
  ///
  /// In en, this message translates to:
  /// **'Local terminal is only available on desktop.'**
  String get terminalLocalOnlyDesktop;

  /// Message written to a terminal when the connection fails
  ///
  /// In en, this message translates to:
  /// **'[connection error: {error}]'**
  String terminalConnectionError(String error);

  /// Message written to a terminal when the remote session exits
  ///
  /// In en, this message translates to:
  /// **'[session exited with code {code}]'**
  String terminalSessionExited(String code);

  /// Message written to a terminal when the local PTY errors
  ///
  /// In en, this message translates to:
  /// **'[pty error: {error}]'**
  String terminalPtyError(String error);

  /// Message written to a terminal when the local PTY closes
  ///
  /// In en, this message translates to:
  /// **'[pty closed]'**
  String get terminalPtyClosed;

  /// Message written to a terminal when the local process exits
  ///
  /// In en, this message translates to:
  /// **'[process exited with code {code}]'**
  String terminalProcessExited(String code);

  /// Message written to a terminal when the local shell cannot start
  ///
  /// In en, this message translates to:
  /// **'[failed to start {shell}: {error}]'**
  String terminalShellStartFailed(String shell, String error);

  /// Usage section title in settings
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get usage;

  /// Short description shown under the Usage section title
  ///
  /// In en, this message translates to:
  /// **'Token usage reported by providers, tracked on this server.'**
  String get usageDescription;

  /// Usage window selector label
  ///
  /// In en, this message translates to:
  /// **'Last {count} days'**
  String usageLastDays(int count);

  /// No description provided for @usageTotalTokens.
  ///
  /// In en, this message translates to:
  /// **'Total tokens'**
  String get usageTotalTokens;

  /// No description provided for @usageInput.
  ///
  /// In en, this message translates to:
  /// **'Input'**
  String get usageInput;

  /// No description provided for @usageOutput.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get usageOutput;

  /// No description provided for @usageCached.
  ///
  /// In en, this message translates to:
  /// **'Cached'**
  String get usageCached;

  /// No description provided for @usageReasoning.
  ///
  /// In en, this message translates to:
  /// **'Reasoning'**
  String get usageReasoning;

  /// No description provided for @usageTurns.
  ///
  /// In en, this message translates to:
  /// **'Turns'**
  String get usageTurns;

  /// No description provided for @usageCost.
  ///
  /// In en, this message translates to:
  /// **'Cost'**
  String get usageCost;

  /// No description provided for @usageByDay.
  ///
  /// In en, this message translates to:
  /// **'Usage by day'**
  String get usageByDay;

  /// No description provided for @usageByProvider.
  ///
  /// In en, this message translates to:
  /// **'By provider'**
  String get usageByProvider;

  /// No description provided for @usageByModel.
  ///
  /// In en, this message translates to:
  /// **'By model'**
  String get usageByModel;

  /// No description provided for @usageEmpty.
  ///
  /// In en, this message translates to:
  /// **'No usage recorded yet.'**
  String get usageEmpty;

  /// No description provided for @usageLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load usage'**
  String get usageLoadFailed;

  /// Audit log section title in settings
  ///
  /// In en, this message translates to:
  /// **'Audit log'**
  String get auditLog;

  /// Short description shown under the Audit log section title
  ///
  /// In en, this message translates to:
  /// **'Security-relevant actions recorded by this server, newest first.'**
  String get auditLogDescription;

  /// No description provided for @auditLogEmpty.
  ///
  /// In en, this message translates to:
  /// **'No audit entries yet.'**
  String get auditLogEmpty;

  /// No description provided for @auditLogLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load the audit log'**
  String get auditLogLoadFailed;

  /// No description provided for @auditLogLoadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get auditLogLoadMore;

  /// Shown as the actor for audit entries that have no user
  ///
  /// In en, this message translates to:
  /// **'system'**
  String get auditLogSystem;

  /// Title of the dialog shown on builds from a merge request
  ///
  /// In en, this message translates to:
  /// **'Development merge request'**
  String get devMergeRequestTitle;

  /// Body of the dialog shown on builds from a merge request
  ///
  /// In en, this message translates to:
  /// **'You are on a development merge request (#{id}). Report issues here:\n\n{url}'**
  String devMergeRequestBody(String id, String url);

  /// Body shown when a merge request ID is known but the URL is missing or invalid
  ///
  /// In en, this message translates to:
  /// **'You are on a development merge request (#{id}). The merge request URL is not available in this build.'**
  String devMergeRequestBodyNoUrl(String id);

  /// Button to open the merge request URL
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get devMergeRequestOpen;

  /// Button to copy the merge request URL
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get devMergeRequestCopy;

  /// Button to dismiss the merge request dialog
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get devMergeRequestClose;
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
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
