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
  String get appName => 'App name';

  @override
  String get about => 'About';

  @override
  String get aboutDescription => 'Bring your agents anywhere';

  @override
  String get aboutVersion => 'Version';

  @override
  String get aboutLicense => 'License';

  @override
  String get aboutSourceCode => 'Source code';

  @override
  String get aboutSupport => 'Support';

  @override
  String get aboutPrivacyPolicy => 'Privacy policy';

  @override
  String aboutOpenLinkFailed(String url) {
    return 'Could not open $url';
  }

  @override
  String get aboutReleases => 'Releases';

  @override
  String get aboutCheckForUpdates => 'Check for updates';

  @override
  String get aboutCheckForUpdatesSubtitle => 'Check GitLab for a newer release';

  @override
  String get aboutUpToDate => 'You are on the latest version';

  @override
  String get aboutUpdateCheckFailed => 'Could not check for updates';

  @override
  String appUpdateAvailable(String version) {
    return 'Update available: $version';
  }

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
  String get totpOptional => 'Optional — only if your account has 2FA enabled';

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
  String get windowClose => 'Close';

  @override
  String get windowMinimize => 'Minimize';

  @override
  String get windowZoom => 'Zoom';

  @override
  String get clear => 'Clear';

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
  String get cloneRepo => 'Clone repository';

  @override
  String get cloneRepoDescription =>
      'Clone a remote repository into the configured clone root.';

  @override
  String get cloneRepoUrlLabel => 'Remote URL';

  @override
  String get cloneRepoButton => 'Clone';

  @override
  String get cloneRepoOpenProject => 'Open project';

  @override
  String get newFolder => 'New folder';

  @override
  String get rename => 'Rename';

  @override
  String get renameProject => 'Rename project';

  @override
  String get renameThread => 'Rename thread';

  @override
  String get pin => 'Pin';

  @override
  String get unpin => 'Unpin';

  @override
  String get pinned => 'Pinned';

  @override
  String get newName => 'New name';

  @override
  String get options => 'Options';

  @override
  String get ownerBadge => 'Owner';

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
  String get attachSourcePhotoLibrary => 'Photo Library';

  @override
  String get attachSourceTakePhotoOrVideo => 'Take Photo or Video';

  @override
  String get attachSourceTakePhoto => 'Take Photo';

  @override
  String get attachSourceRecordVideo => 'Record Video';

  @override
  String get attachSourceBrowse => 'Browse';

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
  String get reasoning => 'Reasoning';

  @override
  String get reasoningDefault => 'Default';

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
  String get providerVersion => 'Version';

  @override
  String get providerUpToDate => 'Up to date';

  @override
  String providerUpdateAvailable(String version) {
    return 'Update available: $version';
  }

  @override
  String get providerIsReachable => 'Provider is reachable';

  @override
  String get providerUnavailable => 'Unavailable';

  @override
  String get providerCommandHint => 'devin';

  @override
  String providerTestFailed(String error) {
    return 'Provider test failed: $error';
  }

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSimplifiedChinese => 'Simplified Chinese';

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
  String deleteProjectConfirm(String name) {
    return 'Remove \"$name\" from Devinorium? This deletes the project and all its threads from the database. The folder on disk is not touched.';
  }

  @override
  String get deleteProject => 'Delete project';

  @override
  String get deleteThread => 'Delete thread';

  @override
  String get connected => 'Connected';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get checkingConnection => 'Checking connection…';

  @override
  String get serverVersion => 'Server version';

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
  String get terminal => 'Terminal';

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
  String get defaultPermissionLevel => 'Default permission level';

  @override
  String get defaultPermissionLevelHint => 'Applied to new threads';

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
  String get editFileNoDiff => 'No diff content yet';

  @override
  String get editFileOpenInFiles => 'Open in files';

  @override
  String get gitBranches => 'Branches';

  @override
  String get pull => 'Pull';

  @override
  String get push => 'Push';

  @override
  String get refresh => 'Refresh';

  @override
  String get commit => 'Commit';

  @override
  String get commitMessageHint => 'Commit message';

  @override
  String get stage => 'Stage';

  @override
  String get unstage => 'Unstage';

  @override
  String get stageAll => 'Stage all';

  @override
  String get unstageAll => 'Unstage all';

  @override
  String get stagedChanges => 'Staged changes';

  @override
  String get notGitRepo => 'Not a git repository';

  @override
  String get gitUnsupportedBackend =>
      'This server is too old for the Git panel. Update the backend and restart the app.';

  @override
  String get gitCommitAllConfirm =>
      'There are no staged changes. Stage all changes and commit?';

  @override
  String get createBranch => 'Create branch';

  @override
  String get branchName => 'Branch name';

  @override
  String get baseBranchOptional => 'Base branch (optional)';

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
  String get mainWorktree => 'Main worktree';

  @override
  String get worktreeBranchLocked =>
      'Switch back to the main worktree to change branches';

  @override
  String get envModeTooltip => 'Run mode';

  @override
  String get localMode => 'Local';

  @override
  String get localModeShort => 'local';

  @override
  String get worktreeMode => 'Worktree';

  @override
  String get worktreeModeShort => 'worktree';

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
  String get gitlabConnectHint =>
      'Run glab auth login in your terminal, then tap Connect.';

  @override
  String get none => 'None';

  @override
  String get createAndSwitchBranch => 'Create and switch';

  @override
  String get send => 'Send';

  @override
  String get next => 'Next';

  @override
  String get previous => 'Previous';

  @override
  String get stopGenerating => 'Stop generating';

  @override
  String get notifications => 'Notifications';

  @override
  String get completionNotifications => 'Notify when a thread completes';

  @override
  String get completionNotificationsDescription =>
      'Show a browser notification when a thread run finishes while this tab is in the background.';

  @override
  String get threadCompletedTitle => 'Thread completed';

  @override
  String threadCompletedBody(String title) {
    return '$title has finished running.';
  }

  @override
  String get threadFailedTitle => 'Thread failed';

  @override
  String threadFailedBody(String title) {
    return '$title encountered an error.';
  }

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Copied';

  @override
  String get copiedToClipboard => 'Copied to clipboard';

  @override
  String get mergeRequest => 'Merge request';

  @override
  String get linkMergeRequest => 'Link merge request';

  @override
  String get unlinkMergeRequest => 'Unlink merge request';

  @override
  String get mergeRequestUrlHint => 'GitLab merge request URL';

  @override
  String get invalidMergeRequestUrl => 'Enter a valid GitLab merge request URL';

  @override
  String get overview => 'Overview';

  @override
  String get changes => 'Changes';

  @override
  String get comments => 'Comments';

  @override
  String get pipelines => 'Pipelines';

  @override
  String get noDescription => 'No description provided.';

  @override
  String get noChanges => 'No changed files.';

  @override
  String changesFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String get noComments => 'No comments yet.';

  @override
  String get noPipelines => 'No pipelines yet.';

  @override
  String get noJobs => 'No jobs yet.';

  @override
  String get noJobLog => 'No log output yet.';

  @override
  String get jobLogLive => 'LIVE';

  @override
  String get openInBrowser => 'Open in browser';

  @override
  String get openLink => 'Open link';

  @override
  String get copyLink => 'Copy link';

  @override
  String get linkToThread => 'Link to thread';

  @override
  String get unlinkFromThread => 'Unlink from thread';

  @override
  String get draft => 'Draft';

  @override
  String get retry => 'Retry';

  @override
  String get merge => 'Merge';

  @override
  String get mergeWhenPipelineSucceeds => 'Merge when pipeline succeeds';

  @override
  String get cancelAutoMerge => 'Cancel auto merge';

  @override
  String get closeMergeRequest => 'Close merge request';

  @override
  String get reopenMergeRequest => 'Reopen merge request';

  @override
  String get mergeRequestDraftBlocked =>
      'Mark the merge request ready before merging.';

  @override
  String get mergeRequestConflictsBlocked =>
      'Resolve the conflicts before merging.';

  @override
  String get mergeRequestAutoMergeSet =>
      'This merge request will merge once the pipeline succeeds.';

  @override
  String get mergeRequestWorking => 'Working...';

  @override
  String get issue => 'Issue';

  @override
  String get issueOpen => 'Open';

  @override
  String get issueClosed => 'Closed';

  @override
  String get issueLabels => 'Labels';

  @override
  String get issueNoDescription => 'No description provided.';

  @override
  String get issueComments => 'Comments';

  @override
  String get issueLoadFailed => 'Failed to load issue';

  @override
  String get issueOpenInBrowser => 'Open in browser';

  @override
  String get cloneRoot => 'Clone root';

  @override
  String get cloneRootDescription =>
      'Directory where cloned repositories are placed.';

  @override
  String get cloneRootNotSet => 'Not set yet';

  @override
  String get cloneRootSave => 'Save';

  @override
  String get cloneRootBrowse => 'Browse...';

  @override
  String get cloneRootOnlyOwner => 'Only the owner can change the clone root.';

  @override
  String get search => 'Search';

  @override
  String get searchHint => 'Search threads...';

  @override
  String get searchKeyboardShortcut => '⌘K';

  @override
  String get searchKeyboardShortcutNonMac => 'Ctrl+H';

  @override
  String get noSearchResults => 'No threads found.';

  @override
  String get threadStatusWorking => 'Working';

  @override
  String get threadStatusDone => 'Done';

  @override
  String get threadStatusFailed => 'Failed';

  @override
  String get threadStatusApproval => 'Approval';

  @override
  String get threadStatusInput => 'Input';

  @override
  String showMoreThreads(int count) {
    return 'Show $count more';
  }

  @override
  String get loadMore => 'Load more';

  @override
  String get servers => 'Servers';

  @override
  String get manageServers => 'Manage servers';

  @override
  String get switchServer => 'Switch server';

  @override
  String get noServersConfigured => 'No servers configured.';

  @override
  String get serverSwitchNotAvailableWeb =>
      'Server switching is not available in the web build.';

  @override
  String get thisDevice => 'This device';

  @override
  String get bundledServer => 'Bundled server';

  @override
  String get web => 'web';

  @override
  String get addServer => 'Add server';

  @override
  String get addServerFromSettingsPrompt =>
      'No server configured.\nAdd a server in Settings to get started.';

  @override
  String get switchServerLabel => 'Switch';

  @override
  String deleteServerConfirm(String name) {
    return 'Remove \"$name\" from Devinorium? This will delete the saved connection.';
  }

  @override
  String get serverUrlWithSchemeHint => 'http://localhost:7878';

  @override
  String get serverUrlMustIncludeScheme =>
      'URL must start with http:// or https://';

  @override
  String get oledTheme => 'OLED';

  @override
  String get themeCustom => 'Custom';

  @override
  String get themeImport => 'Import custom';

  @override
  String get themeImportHint =>
      'Paste a restricted CSS file below. Only :root and color values are allowed.';

  @override
  String get themeImportError => 'Failed to import theme';

  @override
  String get themeCreator => 'Creator';

  @override
  String get themeVersion => 'Version';

  @override
  String get themeDescription => 'Description';

  @override
  String get fileViewerContent => 'Content';

  @override
  String get fileViewerDiff => 'Diff';

  @override
  String get fileViewerBinaryFile => 'Binary file';

  @override
  String get fileViewerLoadError => 'Failed to load file';

  @override
  String get agentsMode => 'Agents';

  @override
  String get editorMode => 'Editor';

  @override
  String get chat => 'Chat';

  @override
  String get editorSelectFile => 'Select a file from the tree to edit';

  @override
  String get editorUnsavedChanges => 'Unsaved changes';

  @override
  String editorSaveBeforeClose(String name) {
    return 'Save changes to $name?';
  }

  @override
  String get editorReload => 'Reload';

  @override
  String binaryFileNotEditable(String name) {
    return '$name is a binary file and cannot be edited';
  }

  @override
  String get editorDiscard => 'Discard';

  @override
  String diffViewMoreLines(int count) {
    return '… $count more lines not shown';
  }

  @override
  String contentViewMoreLines(int count) {
    return '… $count more lines not shown';
  }

  @override
  String get contentViewShowAll => 'Show all';

  @override
  String get showMore => 'Show more';

  @override
  String get loadingMore => 'Loading more…';

  @override
  String get terminalNoSessions => 'No terminal sessions';

  @override
  String terminalTab(int index) {
    return 'Tab $index';
  }

  @override
  String get terminalNewTab => 'New tab';

  @override
  String get terminalCloseTab => 'Close tab';

  @override
  String get terminalClose => 'Close terminal';

  @override
  String get terminalLocal => 'Local terminal';

  @override
  String get terminalRemote => 'Remote terminal';

  @override
  String get terminalHide => 'Hide terminal';

  @override
  String terminalStartFailed(String error) {
    return 'Failed to start terminal: $error';
  }

  @override
  String get terminalCloseTitle => 'Close terminal?';

  @override
  String get terminalCloseBody =>
      'This terminal has running processes or output. Close it anyway?';

  @override
  String get terminalTabCloseTitle => 'Close tab?';

  @override
  String terminalTabCloseBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'This tab contains $count active terminals. Close it anyway?',
      one: 'This tab contains 1 active terminal. Close it anyway?',
    );
    return '$_temp0';
  }

  @override
  String get planHide => 'Hide plan';

  @override
  String get planShow => 'Show plan';

  @override
  String get planCollapse => 'Collapse plan';

  @override
  String get planExpand => 'Expand plan';

  @override
  String get planTitle => 'Plan';

  @override
  String planProgress(int completed, int total, int percent) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'steps',
      one: 'step',
    );
    return '$completed / $total $_temp0 · $percent%';
  }

  @override
  String get composerModeCode => 'Code';

  @override
  String get composerModePlan => 'Plan';

  @override
  String get composerModeAsk => 'Ask';

  @override
  String get terminalLocalOnlyDesktop =>
      'Local terminal is only available on desktop.';

  @override
  String terminalConnectionError(String error) {
    return '[connection error: $error]';
  }

  @override
  String terminalSessionExited(String code) {
    return '[session exited with code $code]';
  }

  @override
  String terminalPtyError(String error) {
    return '[pty error: $error]';
  }

  @override
  String get terminalPtyClosed => '[pty closed]';

  @override
  String terminalProcessExited(String code) {
    return '[process exited with code $code]';
  }

  @override
  String terminalShellStartFailed(String shell, String error) {
    return '[failed to start $shell: $error]';
  }

  @override
  String get usage => 'Usage';

  @override
  String get usageDescription =>
      'Token usage reported by providers, tracked on this server.';

  @override
  String usageLastDays(int count) {
    return 'Last $count days';
  }

  @override
  String get usageTotalTokens => 'Total tokens';

  @override
  String get usageInput => 'Input';

  @override
  String get usageOutput => 'Output';

  @override
  String get usageCached => 'Cached';

  @override
  String get usageReasoning => 'Reasoning';

  @override
  String get usageTurns => 'Turns';

  @override
  String get usageCost => 'Cost';

  @override
  String get usageByDay => 'Usage by day';

  @override
  String get usageByProvider => 'By provider';

  @override
  String get usageByModel => 'By model';

  @override
  String get usageEmpty => 'No usage recorded yet.';

  @override
  String get usageLoadFailed => 'Failed to load usage';

  @override
  String get devMergeRequestTitle => 'Development merge request';

  @override
  String devMergeRequestBody(String id, String url) {
    return 'You are on a development merge request (#$id). Report issues here:\n\n$url';
  }

  @override
  String devMergeRequestBodyNoUrl(String id) {
    return 'You are on a development merge request (#$id). The merge request URL is not available in this build.';
  }

  @override
  String get devMergeRequestOpen => 'Open';

  @override
  String get devMergeRequestCopy => 'Copy';

  @override
  String get devMergeRequestClose => 'Close';
}
