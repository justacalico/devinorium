// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Devinorium';

  @override
  String get connectionFailed => 'connection failed';

  @override
  String get importFailed => 'import failed';

  @override
  String get totpPrompt => 'Enter your 6-digit TOTP code.';

  @override
  String get selectProjectFirst => 'Select a project first';

  @override
  String get newThread => 'New thread';

  @override
  String invalidPermissionRequest(String error) {
    return 'Invalid permission request: $error';
  }

  @override
  String get failedToDecodePermissionRequest =>
      'Failed to decode permission request';

  @override
  String get invalidAskRequest => 'Invalid ask request';

  @override
  String get failedToDecodeAskRequest => 'Failed to decode ask request';

  @override
  String get serverUrlNotConfigured => 'server URL not configured';

  @override
  String get authenticationTokenNotSet => 'authentication token not set';

  @override
  String httpErrorStatus(int statusCode) {
    return 'HTTP $statusCode';
  }

  @override
  String httpErrorWithText(int statusCode, String text) {
    return 'HTTP $statusCode: $text';
  }

  @override
  String get unexpectedResponseShape => 'unexpected response shape';

  @override
  String get expectedAList => 'expected a list';

  @override
  String get sseOnlySupportedOnWeb =>
      'SSE streaming is only supported on the web';

  @override
  String get noResponseBody => 'no response body';

  @override
  String get unexpectedStreamChunkType => 'Unexpected stream chunk type';

  @override
  String genericRequestError(String error) {
    return '$error';
  }

  @override
  String get signInToYourAccount => 'Sign in to your account';

  @override
  String get totpCode => 'TOTP code';

  @override
  String get totpHint => '000000';

  @override
  String get atLeast12Characters => 'At least 12 characters';

  @override
  String get createUser => 'Create user';

  @override
  String get cancel => 'Cancel';

  @override
  String get create => 'Create';

  @override
  String get delete => 'Delete';

  @override
  String get ok => 'OK';

  @override
  String get back => 'Back';

  @override
  String get close => 'Close';

  @override
  String get required => 'Required';

  @override
  String get invalidNumber => 'Must be a valid number';

  @override
  String get otherOption => 'Other (type your own)';

  @override
  String get otherHint => 'Type your answer';

  @override
  String get username => 'Username';

  @override
  String get password => 'Password';

  @override
  String get test => 'Test';

  @override
  String get error => 'Error';

  @override
  String get on => 'On';

  @override
  String get off => 'Off';

  @override
  String get enabled => 'Enabled';

  @override
  String get disabled => 'Disabled';

  @override
  String get light => 'Light';

  @override
  String get dark => 'Dark';

  @override
  String get system => 'System';

  @override
  String get save => 'Save';

  @override
  String get signIn => 'Sign in';

  @override
  String get signOut => 'Sign out';

  @override
  String get settings => 'Settings';

  @override
  String get account => 'Account';

  @override
  String get providers => 'Providers';

  @override
  String get provider => 'Provider';

  @override
  String get devices => 'Devices';

  @override
  String get personalization => 'Personalization';

  @override
  String get manage => 'Manage';

  @override
  String get projects => 'Projects';

  @override
  String get language => 'Language';

  @override
  String get theme => 'Theme';

  @override
  String get root => 'root';

  @override
  String get home => 'Home';

  @override
  String get up => 'Up';

  @override
  String get newProject => 'New project';

  @override
  String get newFolder => 'New folder';

  @override
  String get rename => 'Rename';

  @override
  String get renameProject => 'Rename project';

  @override
  String get renameThread => 'Rename thread';

  @override
  String get newName => 'New name';

  @override
  String get options => 'Options';

  @override
  String get ownerBadge => 'Owner';

  @override
  String get revoke => 'Revoke';

  @override
  String get enable2fa => 'Enable 2FA';

  @override
  String get totpSetupInstructions =>
      'Scan this secret in your authenticator app, then enter the current code.';

  @override
  String get verify => 'Verify';

  @override
  String get name => 'Name';

  @override
  String get myProjectHint => 'My project';

  @override
  String get path => 'Path';

  @override
  String get projectPathHint => 'relative/path or /absolute/project/path';

  @override
  String get browseToThisPath => 'Browse to this path';

  @override
  String get selectCurrentFolder => 'Select current folder';

  @override
  String get pathTraversalNotAllowed => 'Path traversal is not allowed';

  @override
  String get nameAndPathRequired => 'Name and path are required';

  @override
  String get noSubfoldersHere => 'No subfolders here';

  @override
  String get permissionRequest => 'Permission request';

  @override
  String get askRequest => 'Agent question';

  @override
  String get allowThisAction => 'Allow this action?';

  @override
  String get allowOnce => 'Allow once';

  @override
  String get allowAlways => 'Allow always';

  @override
  String get rejectOnce => 'Reject once';

  @override
  String get rejectAlways => 'Reject always';

  @override
  String dropZoneFileTooLarge(String name) {
    return '$name is too large (max 8 MB)';
  }

  @override
  String dropZoneReadFileFailed(String error) {
    return 'Failed to read file: $error';
  }

  @override
  String dropZoneAttachFilesFailed(String error) {
    return 'Failed to attach files: $error';
  }

  @override
  String dropZonePickFilesFailed(String error) {
    return 'Failed to pick files: $error';
  }

  @override
  String get dropZoneDropHere => 'Drop files here to attach';

  @override
  String get files => 'Files';

  @override
  String get emptyFolder => 'Empty folder';

  @override
  String get folderNameHint => 'Folder name';

  @override
  String deleteName(String name) {
    return 'Delete $name?';
  }

  @override
  String get searchModels => 'Search models';

  @override
  String get noModelsMatch => 'No models match';

  @override
  String get free => 'Free';

  @override
  String get promo => 'Promo';

  @override
  String get newLabel => 'New';

  @override
  String get beta => 'Beta';

  @override
  String get noModelSelected => 'No model selected';

  @override
  String get model => 'Model';

  @override
  String get selected => 'Selected';

  @override
  String get selectModel => 'Select model';

  @override
  String get modelContextLabel => 'Context';

  @override
  String get modelOutputLabel => 'Output';

  @override
  String get costTierLabel => 'Cost tier';

  @override
  String get pricingLabel => 'Pricing';

  @override
  String contextWithTokens(String count) {
    return '$count context';
  }

  @override
  String get otherFamily => 'Other';

  @override
  String get serverUrl => 'Server URL';

  @override
  String get serverUrlHint => 'example.com';

  @override
  String get serverUrlInvalid =>
      'Do not include http:// or https:// in the server address';

  @override
  String get devicesDescription => 'Active sessions for your account.';

  @override
  String get noPairedDevices => 'No devices.';

  @override
  String deviceToken(String tokenPrefix) {
    return 'Device $tokenPrefix';
  }

  @override
  String get current => 'Current';

  @override
  String get paired => 'Paired';

  @override
  String get revokeDeviceTitle => 'Revoke device?';

  @override
  String get revokeDeviceBody => 'This device will be signed out immediately.';

  @override
  String get disable2faTitle => 'Disable 2FA?';

  @override
  String get disable2faConfirmation =>
      'This will remove TOTP-based two-factor authentication from your account. Are you sure?';

  @override
  String get disable2fa => 'Disable 2FA';

  @override
  String get twoFactorAuthentication => 'Two-factor authentication';

  @override
  String get twoFactorShort => '2FA';

  @override
  String get user => 'User';

  @override
  String get active => 'Active';

  @override
  String get noUsersYet => 'No users yet.';

  @override
  String get command => 'Command';

  @override
  String get providerIsReachable => 'Provider is reachable';

  @override
  String get providerCommandHint => 'devin';

  @override
  String providerTestFailed(String error) {
    return 'Provider test failed: $error';
  }

  @override
  String get languageEnglish => 'English';

  @override
  String get menu => 'Menu';

  @override
  String newThreadIn(String projectName) {
    return 'New thread in $projectName';
  }

  @override
  String get noProjectsYet => 'No projects yet.\nCreate one to get started.';

  @override
  String get noThreadsYet => 'No threads yet';

  @override
  String get deleteThreadConfirm =>
      'Delete this thread? This cannot be undone.';

  @override
  String get deleteThreadTooltip =>
      'Delete thread (Shift+click to skip confirmation)';

  @override
  String get topics => 'Topics';

  @override
  String get timeAgoJustNow => 'just now';

  @override
  String timeAgoMinutes(int count) {
    return '${count}m ago';
  }

  @override
  String timeAgoHours(int count) {
    return '${count}h ago';
  }

  @override
  String timeAgoDays(int count) {
    return '${count}d ago';
  }

  @override
  String timeAgoMonths(int count) {
    return '${count}mo ago';
  }

  @override
  String timeAgoYears(int count) {
    return '${count}y ago';
  }

  @override
  String get selectOrCreateThread => 'Select or create a thread';

  @override
  String get fileManager => 'File manager';

  @override
  String get selectOrCreateThreadToChat =>
      'Select or create a thread to start chatting.';

  @override
  String get startConversationHint =>
      'Start the conversation by sending a message below.';

  @override
  String get messageRoleYou => 'You';

  @override
  String get messageRoleAssistant => 'Assistant';

  @override
  String get messageRoleError => 'Error';

  @override
  String get thinking => 'Thinking';

  @override
  String get hideThinking => 'Hide thinking';

  @override
  String get showThinking => 'Show thinking';

  @override
  String get composerHint => 'Ask a question or drop files here';

  @override
  String get permissionModeNormal => 'Ask every time';

  @override
  String get permissionModeAcceptEdits => 'Confirm edits';

  @override
  String get permissionModeSmart => 'Smart confirm';

  @override
  String get permissionModeBypass => 'Auto-run';

  @override
  String get preview => 'Preview';

  @override
  String get output => 'Output';

  @override
  String get changed => 'Changed';

  @override
  String get tagNeedsApproval => 'Needs approval';

  @override
  String get tagRunning => 'Running';

  @override
  String get tagWorking => 'Working';

  @override
  String get tagFailed => 'Failed';

  @override
  String get tagDone => 'Done';

  @override
  String get tagStopped => 'Stopped';

  @override
  String get noValue => '—';

  @override
  String tokensMillionSuffix(String count) {
    return '${count}M';
  }

  @override
  String tokensThousandSuffix(String count) {
    return '${count}K';
  }

  @override
  String tokensCount(String count) {
    return '$count';
  }

  @override
  String sizeBytes(String count) {
    return '$count B';
  }

  @override
  String sizeKilobytes(String count) {
    return '$count KB';
  }

  @override
  String sizeMegabytes(String count) {
    return '$count MB';
  }

  @override
  String get breadcrumbSeparator => ' / ';

  @override
  String get messageLoading => '...';

  @override
  String readFileTitle(String fileName) {
    return 'Read $fileName';
  }

  @override
  String readFileLineCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return '$_temp0';
  }

  @override
  String readFileLineRange(int start, int end) {
    return '$start-$end';
  }

  @override
  String get readFileNoContent => 'No content';

  @override
  String get gitBranches => 'Branches';

  @override
  String get pull => 'Pull';

  @override
  String get push => 'Push';

  @override
  String get notAGitRepo => 'This project is not a Git repository.';

  @override
  String get searchBranches => 'Search branches';

  @override
  String get createBranch => 'Create branch';

  @override
  String get branchName => 'Branch name';

  @override
  String get baseBranchOptional => 'Base branch (optional)';

  @override
  String get switchAfterCreate => 'Switch to new branch';

  @override
  String get createWorktree => 'Create worktree';

  @override
  String get worktreeName => 'Worktree name';

  @override
  String get baseBranch => 'Base branch';

  @override
  String get newBranchInWorktree => 'Create new branch in worktree';

  @override
  String get worktrees => 'Worktrees';

  @override
  String get git => 'Git';

  @override
  String get gitConnections => 'Connections';

  @override
  String get gitlab => 'GitLab';

  @override
  String get github => 'GitHub';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String get connect => 'Connect';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get notConnected => 'Not connected';

  @override
  String connectedAs(String account) {
    return 'Connected as $account';
  }

  @override
  String get token => 'Token';

  @override
  String get hostname => 'Hostname';

  @override
  String get gitlabComHint => 'gitlab.com';

  @override
  String gitlabConnectFailed(String error) {
    return 'GitLab connect failed: $error';
  }

  @override
  String gitlabDisconnectFailed(String error) {
    return 'GitLab disconnect failed: $error';
  }

  @override
  String get loading => 'Loading…';

  @override
  String get gitlabNotInstalled => 'GitLab CLI (glab) is not installed';

  @override
  String get none => 'None';

  @override
  String get createAndSwitchBranch => 'Create and switch';

  @override
  String get createAndNewBranch => 'Create and new branch';

  @override
  String get send => 'Send';

  @override
  String get stopGenerating => 'Stop generating';
}
