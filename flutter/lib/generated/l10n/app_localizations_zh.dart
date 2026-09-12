// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Devinorium';

  @override
  String get appName => '应用名称';

  @override
  String get about => '关于';

  @override
  String get aboutDescription => '让智能体伴你同行';

  @override
  String get aboutVersion => '版本';

  @override
  String get aboutLicense => '许可证';

  @override
  String get aboutSourceCode => '源代码';

  @override
  String get aboutSupport => '支持';

  @override
  String get aboutPrivacyPolicy => '隐私政策';

  @override
  String aboutOpenLinkFailed(String url) {
    return '无法打开 $url';
  }

  @override
  String get aboutReleases => '发布';

  @override
  String get aboutCheckForUpdates => '检查更新';

  @override
  String get aboutCheckForUpdatesSubtitle => '在 GitLab 上检查更新';

  @override
  String get aboutUpToDate => '已是最新版本';

  @override
  String get aboutUpdateCheckFailed => '无法检查更新';

  @override
  String appUpdateAvailable(String version) {
    return '可用更新：$version';
  }

  @override
  String get connectionFailed => '连接失败';

  @override
  String get importFailed => '导入失败';

  @override
  String get totpPrompt => '输入你的 6 位 TOTP 验证码。';

  @override
  String get selectProjectFirst => '请先选择项目';

  @override
  String get newThread => '新会话';

  @override
  String invalidPermissionRequest(String error) {
    return '无效的权限请求：$error';
  }

  @override
  String get failedToDecodePermissionRequest => '无法解码权限请求';

  @override
  String get invalidAskRequest => '无效的询问请求';

  @override
  String get failedToDecodeAskRequest => '无法解码询问请求';

  @override
  String get serverUrlNotConfigured => '未配置服务器 URL';

  @override
  String get authenticationTokenNotSet => '未设置认证令牌';

  @override
  String httpErrorStatus(int statusCode) {
    return 'HTTP $statusCode';
  }

  @override
  String httpErrorWithText(int statusCode, String text) {
    return 'HTTP $statusCode：$text';
  }

  @override
  String get unexpectedResponseShape => '意外的响应格式';

  @override
  String get expectedAList => '应为列表';

  @override
  String get sseOnlySupportedOnWeb => 'SSE 流式仅支持网页端';

  @override
  String get noResponseBody => '无响应体';

  @override
  String get unexpectedStreamChunkType => '意外的流块类型';

  @override
  String genericRequestError(String error) {
    return '$error';
  }

  @override
  String get signInToYourAccount => '登录您的账户';

  @override
  String get totpCode => 'TOTP 验证码';

  @override
  String get totpHint => '000000';

  @override
  String get totpOptional => '可选 — 仅在账户启用 2FA 时填写';

  @override
  String get atLeast12Characters => '至少 12 个字符';

  @override
  String get createUser => '创建用户';

  @override
  String get cancel => '取消';

  @override
  String get create => '创建';

  @override
  String get delete => '删除';

  @override
  String get ok => '确定';

  @override
  String get back => '返回';

  @override
  String get close => '关闭';

  @override
  String get windowClose => '关闭';

  @override
  String get windowMinimize => '最小化';

  @override
  String get windowZoom => '缩放';

  @override
  String get clear => '清除';

  @override
  String get required => '必填';

  @override
  String get invalidNumber => '必须是有效数字';

  @override
  String get otherOption => '其他（输入自定义）';

  @override
  String get otherHint => '输入你的答案';

  @override
  String get username => '用户名';

  @override
  String get password => '密码';

  @override
  String get test => '测试';

  @override
  String get error => '错误';

  @override
  String get on => '开';

  @override
  String get off => '关';

  @override
  String get enabled => '已启用';

  @override
  String get disabled => '已禁用';

  @override
  String get light => '浅色';

  @override
  String get dark => '深色';

  @override
  String get system => '系统';

  @override
  String get save => '保存';

  @override
  String get signIn => '登录';

  @override
  String get signOut => '退出';

  @override
  String get settings => '设置';

  @override
  String get account => '账户';

  @override
  String get providers => '提供商';

  @override
  String get provider => '提供商';

  @override
  String get personalization => '个性化';

  @override
  String get manage => '管理';

  @override
  String get projects => '项目';

  @override
  String get language => '语言';

  @override
  String get theme => '主题';

  @override
  String get root => '根';

  @override
  String get home => '主页';

  @override
  String get up => '上级';

  @override
  String get newProject => '新建项目';

  @override
  String get addProject => '添加项目';

  @override
  String get addProjectLocalTitle => '本地文件夹';

  @override
  String get addProjectLocalDescription => '浏览磁盘上的文件夹';

  @override
  String get addProjectCloneDescription => '从远程 URL 克隆';

  @override
  String get cloneRepo => '克隆存储库';

  @override
  String get cloneRepoDescription => '将远程仓库克隆到配置的克隆根目录';

  @override
  String get cloneRepoUrlLabel => '远程 URL';

  @override
  String get cloneRepoButton => '克隆';

  @override
  String get cloneRepoOpenProject => '打开项目';

  @override
  String get newFolder => '新建文件夹';

  @override
  String get rename => '重命名';

  @override
  String get renameProject => '重命名项目';

  @override
  String get renameThread => '重命名会话';

  @override
  String get pin => '置顶';

  @override
  String get unpin => '取消置顶';

  @override
  String get pinned => '已置顶';

  @override
  String get newName => '新名称';

  @override
  String get options => '选项';

  @override
  String get ownerBadge => '所有者';

  @override
  String get enable2fa => '启用 2FA';

  @override
  String get totpSetupInstructions => '在您的身份验证器应用程序中扫描此密码，然后输入当前代码。';

  @override
  String get verify => '验证';

  @override
  String get name => '名称';

  @override
  String get myProjectHint => '我的项目';

  @override
  String get path => '路径';

  @override
  String get projectPathHint => 'relative/path or /absolute/project/path';

  @override
  String get browseToThisPath => '浏览到此路径';

  @override
  String get selectCurrentFolder => '选择当前文件夹';

  @override
  String get pathTraversalNotAllowed => '不允许路径遍历';

  @override
  String get nameAndPathRequired => '名称和路径必填';

  @override
  String get noSubfoldersHere => '此处无子文件夹';

  @override
  String get permissionRequest => '权限请求';

  @override
  String get askRequest => '智能体问题';

  @override
  String get allowThisAction => '允许此操作？';

  @override
  String get allowOnce => '允许一次';

  @override
  String get allowAlways => '始终允许';

  @override
  String get rejectOnce => '拒绝一次';

  @override
  String get rejectAlways => '始终拒绝';

  @override
  String dropZoneFileTooLarge(String name) {
    return '$name 太大（最大 8 MB）';
  }

  @override
  String dropZoneReadFileFailed(String error) {
    return '读取文件失败：$error';
  }

  @override
  String dropZoneAttachFilesFailed(String error) {
    return '附加文件失败：$error';
  }

  @override
  String dropZonePickFilesFailed(String error) {
    return '选择文件失败：$error';
  }

  @override
  String get dropZoneDropHere => '拖放文件到此处以附加';

  @override
  String get attachSourcePhotoLibrary => '照片图库';

  @override
  String get attachSourceTakePhotoOrVideo => '拍照或录像';

  @override
  String get attachSourceTakePhoto => '拍照';

  @override
  String get attachSourceRecordVideo => '录像';

  @override
  String get attachSourceBrowse => '浏览';

  @override
  String get files => '文件';

  @override
  String get emptyFolder => '空文件夹';

  @override
  String get folderNameHint => '文件夹名称';

  @override
  String deleteName(String name) {
    return '删除 $name？';
  }

  @override
  String get searchModels => '搜索模型';

  @override
  String get noModelsMatch => '没有匹配的模型';

  @override
  String get free => '免费';

  @override
  String get promo => '促销';

  @override
  String get newLabel => '新';

  @override
  String get beta => '测试';

  @override
  String get noModelSelected => '未选择模型';

  @override
  String get model => '模型';

  @override
  String get reasoning => '推理';

  @override
  String get reasoningDefault => '默认';

  @override
  String get selected => '已选择';

  @override
  String get selectModel => '选择模型';

  @override
  String get modelContextLabel => '上下文';

  @override
  String get modelOutputLabel => '输出';

  @override
  String get costTierLabel => '成本等级';

  @override
  String get pricingLabel => '定价';

  @override
  String contextWithTokens(String count) {
    return '$count 上下文长度';
  }

  @override
  String get otherFamily => '其他';

  @override
  String get serverUrl => '服务器 URL';

  @override
  String get serverUrlHint => 'example.com';

  @override
  String get serverUrlInvalid => '服务器地址中请勿包含 http:// 或 https://';

  @override
  String get disable2faTitle => '禁用 2FA？';

  @override
  String get disable2faConfirmation => '这将移除基于 TOTP 的双因素认证。确定吗？';

  @override
  String get disable2fa => '禁用 2FA';

  @override
  String get twoFactorAuthentication => '双因素认证';

  @override
  String get twoFactorShort => '2FA';

  @override
  String get user => '用户';

  @override
  String get active => '活动';

  @override
  String get noUsersYet => '还没有用户。';

  @override
  String get command => '命令';

  @override
  String get providerVersion => '版本';

  @override
  String get providerUpToDate => '最新';

  @override
  String providerUpdateAvailable(String version) {
    return '可用更新：$version';
  }

  @override
  String get providerIsReachable => '提供商可访问';

  @override
  String get providerUnavailable => '不可用';

  @override
  String get providerCommandHint => 'devin';

  @override
  String providerTestFailed(String error) {
    return '提供商测试失败：$error';
  }

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSimplifiedChinese => '简体中文';

  @override
  String get menu => '菜单';

  @override
  String newThreadIn(String projectName) {
    return '在 $projectName 中新建会话';
  }

  @override
  String get noProjectsYet => '还没有项目。\n创建一个以开始使用。';

  @override
  String get noThreadsYet => '还没有会话';

  @override
  String get deleteThreadConfirm => '删除此会话？此操作无法撤销。';

  @override
  String deleteProjectConfirm(String name) {
    return '从 Devinorium 移除“$name”？这将删除项目及其所有会话，但不会删除磁盘上的文件夹。';
  }

  @override
  String get deleteProject => '删除项目';

  @override
  String get deleteThread => '删除会话';

  @override
  String get connected => '已连接';

  @override
  String get disconnected => '已断开';

  @override
  String get checkingConnection => '检查连接中…';

  @override
  String get serverVersion => '服务器版本';

  @override
  String get topics => '主题';

  @override
  String get timeAgoJustNow => '刚刚';

  @override
  String timeAgoMinutes(int count) {
    return '$count 分钟前';
  }

  @override
  String timeAgoHours(int count) {
    return '$count 小时前';
  }

  @override
  String timeAgoDays(int count) {
    return '$count 天前';
  }

  @override
  String timeAgoMonths(int count) {
    return '$count 个月前';
  }

  @override
  String timeAgoYears(int count) {
    return '$count 年前';
  }

  @override
  String get selectOrCreateThread => '选择或创建会话';

  @override
  String get terminal => '终端';

  @override
  String get selectOrCreateThreadToChat => '选择或创建会话以开始聊天';

  @override
  String get startConversationHint => '在下方发送消息以开始对话';

  @override
  String get messageRoleYou => '你';

  @override
  String get messageRoleAssistant => '助手';

  @override
  String get messageRoleError => '错误';

  @override
  String get thinking => '思考中';

  @override
  String get hideThinking => '隐藏思考';

  @override
  String get showThinking => '显示思考';

  @override
  String get composerHint => '在此提问或拖放文件';

  @override
  String get permissionModeNormal => '每次都询问';

  @override
  String get permissionModeAcceptEdits => '确认编辑';

  @override
  String get permissionModeSmart => '智能确认';

  @override
  String get permissionModeBypass => '自动运行';

  @override
  String get defaultPermissionLevel => '默认权限级别';

  @override
  String get defaultPermissionLevelHint => '应用于新会话';

  @override
  String get preview => '预览';

  @override
  String get output => '输出';

  @override
  String get changed => '已更改';

  @override
  String get tagNeedsApproval => '需审批';

  @override
  String get tagRunning => '运行中';

  @override
  String get tagWorking => '处理中';

  @override
  String get tagFailed => '失败';

  @override
  String get tagDone => '完成';

  @override
  String get tagStopped => '已停止';

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
    return '读取 $fileName';
  }

  @override
  String readFileLineCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 行',
      one: '1 行',
    );
    return '$_temp0';
  }

  @override
  String readFileLineRange(int start, int end) {
    return '$start-$end';
  }

  @override
  String get readFileNoContent => '无内容';

  @override
  String get editFileNoDiff => '尚无差异内容';

  @override
  String get editFileOpenInFiles => '在文件中打开';

  @override
  String get gitBranches => '分支';

  @override
  String get pull => '拉取';

  @override
  String get push => '推送';

  @override
  String get refresh => '刷新';

  @override
  String get commit => '提交';

  @override
  String get commitMessageHint => '提交信息';

  @override
  String get stage => '暂存';

  @override
  String get unstage => '取消暂存';

  @override
  String get stageAll => '全部暂存';

  @override
  String get unstageAll => '全部取消暂存';

  @override
  String get stagedChanges => '已暂存的更改';

  @override
  String get notGitRepo => '不是 git 仓库';

  @override
  String get gitUnsupportedBackend => '当前服务器版本过旧，不支持 Git 面板。请更新后端并重启应用。';

  @override
  String get gitCommitAllConfirm => '没有已暂存的更改。是否暂存全部更改并提交？';

  @override
  String get createBranch => '创建分支';

  @override
  String get branchName => '分支名称';

  @override
  String get baseBranchOptional => '基础分支（可选）';

  @override
  String get createWorktree => '创建工作树';

  @override
  String get worktreeName => '工作树名称';

  @override
  String get baseBranch => '基础分支';

  @override
  String get newBranchInWorktree => '在工作树中创建新分支';

  @override
  String get worktrees => '工作树';

  @override
  String get mainWorktree => '主工作树';

  @override
  String get worktreeBranchLocked => '切换回主工作树以更改分支';

  @override
  String get envModeTooltip => '运行模式';

  @override
  String get localMode => '本地';

  @override
  String get localModeShort => '本地';

  @override
  String get worktreeMode => '工作树';

  @override
  String get worktreeModeShort => '工作树';

  @override
  String get git => 'Git';

  @override
  String get gitConnections => '连接';

  @override
  String get gitlab => 'GitLab';

  @override
  String get github => 'GitHub';

  @override
  String get comingSoon => '即将推出';

  @override
  String get connect => '连接';

  @override
  String get disconnect => '断开';

  @override
  String get notConnected => '未连接';

  @override
  String connectedAs(String account) {
    return '以 $account 身份连接';
  }

  @override
  String get token => '令牌';

  @override
  String get hostname => '主机名';

  @override
  String get gitlabComHint => 'gitlab.com';

  @override
  String gitlabConnectFailed(String error) {
    return 'GitLab 连接失败：$error';
  }

  @override
  String gitlabDisconnectFailed(String error) {
    return 'GitLab 断开失败：$error';
  }

  @override
  String get loading => '加载中…';

  @override
  String get gitlabNotInstalled => '未安装 GitLab CLI（glab）。';

  @override
  String get gitlabConnectHint => '在终端中运行 glab auth login，然后点击连接。';

  @override
  String get none => '无';

  @override
  String get createAndSwitchBranch => '创建并切换';

  @override
  String get send => '发送';

  @override
  String get next => '下一步';

  @override
  String get previous => '上一步';

  @override
  String get stopGenerating => '停止生成';

  @override
  String get notifications => '通知';

  @override
  String get completionNotifications => '会话完成时通知';

  @override
  String get completionNotificationsDescription => '当会话在后台完成运行时显示浏览器通知';

  @override
  String get threadCompletedTitle => '会话完成';

  @override
  String threadCompletedBody(String title) {
    return '$title 已运行完成';
  }

  @override
  String get threadFailedTitle => '会话失败';

  @override
  String threadFailedBody(String title) {
    return '$title 遇到错误';
  }

  @override
  String get copy => '复制';

  @override
  String get copied => '已复制';

  @override
  String get copiedToClipboard => '已复制到剪贴板';

  @override
  String get mergeRequest => '合并请求';

  @override
  String get linkMergeRequest => '关联合并请求';

  @override
  String get unlinkMergeRequest => '取消关联合并请求';

  @override
  String get mergeRequestUrlHint => 'GitLab 合并请求 URL';

  @override
  String get invalidMergeRequestUrl => '请输入有效的 GitLab 合并请求 URL';

  @override
  String get overview => '概览';

  @override
  String get changes => '更改';

  @override
  String get comments => '评论';

  @override
  String get pipelines => '流水线';

  @override
  String get noDescription => '未提供描述';

  @override
  String get noChanges => '没有已更改的文件';

  @override
  String changesFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文件',
      one: '1 个文件',
    );
    return '$_temp0';
  }

  @override
  String get noComments => '暂无评论';

  @override
  String get noPipelines => '暂无流水线';

  @override
  String get noJobs => '暂无作业';

  @override
  String get noJobLog => '暂无作业日志';

  @override
  String get jobLogLive => '实时';

  @override
  String get openInBrowser => '在浏览器中打开';

  @override
  String get openLink => '打开链接';

  @override
  String get copyLink => '复制链接';

  @override
  String get linkToThread => '关联到会话';

  @override
  String get unlinkFromThread => '取消关联会话';

  @override
  String get draft => '草稿';

  @override
  String get retry => '重试';

  @override
  String get merge => '合并';

  @override
  String get mergeWhenPipelineSucceeds => '流水线成功后合并';

  @override
  String get cancelAutoMerge => '取消自动合并';

  @override
  String get closeMergeRequest => '关闭合并请求';

  @override
  String get reopenMergeRequest => '重新打开合并请求';

  @override
  String get mergeRequestDraftBlocked => '合并前请将合并请求标记为可合并';

  @override
  String get mergeRequestConflictsBlocked => '合并前请解决冲突';

  @override
  String get mergeRequestAutoMergeSet => '此合并请求将在流水线成功后自动合并';

  @override
  String get mergeRequestWorking => '处理中…';

  @override
  String get issue => '议题';

  @override
  String get issueOpen => '打开';

  @override
  String get issueClosed => '已关闭';

  @override
  String get issueLabels => '标签';

  @override
  String get issueNoDescription => '未提供描述';

  @override
  String get issueComments => '评论';

  @override
  String get issueLoadFailed => '加载议题失败';

  @override
  String get issueOpenInBrowser => '在浏览器中打开';

  @override
  String get cloneRoot => '克隆根目录';

  @override
  String get cloneRootDescription => '克隆仓库所在的目录';

  @override
  String get cloneRootNotSet => '尚未设置';

  @override
  String get cloneRootSave => '保存';

  @override
  String get cloneRootBrowse => '浏览…';

  @override
  String get cloneRootOnlyOwner => '只有所有者可以更改克隆根目录';

  @override
  String get search => '搜索';

  @override
  String get searchHint => '搜索会话…';

  @override
  String get searchKeyboardShortcut => '⌘K';

  @override
  String get searchKeyboardShortcutNonMac => 'Ctrl+H';

  @override
  String get noSearchResults => '未找到会话';

  @override
  String get threadStatusWorking => '进行中';

  @override
  String get threadStatusDone => '完成';

  @override
  String get threadStatusFailed => '失败';

  @override
  String get threadStatusApproval => '审批';

  @override
  String get threadStatusInput => '输入';

  @override
  String showMoreThreads(int count) {
    return '显示另外 $count 个';
  }

  @override
  String get loadMore => '加载更多';

  @override
  String get servers => '服务器';

  @override
  String get manageServers => '管理服务器';

  @override
  String get switchServer => '切换服务器';

  @override
  String get noServersConfigured => '未配置服务器';

  @override
  String get serverSwitchNotAvailableWeb => '网页版不支持服务器切换';

  @override
  String get thisDevice => '本机';

  @override
  String get bundledServer => '内置服务器';

  @override
  String get web => '网页';

  @override
  String get addServer => '添加服务器';

  @override
  String get addServerFromSettingsPrompt => '未配置服务器。\n在设置中添加服务器以开始使用。';

  @override
  String get switchServerLabel => '切换';

  @override
  String deleteServerConfirm(String name) {
    return '从 Devinorium 移除“$name”？这将删除保存的连接。';
  }

  @override
  String get serverUrlWithSchemeHint => 'http://localhost:7878';

  @override
  String get serverUrlMustIncludeScheme => 'URL 必须以 http:// 或 https:// 开头';

  @override
  String get oledTheme => 'OLED';

  @override
  String get themeCustom => '自定义';

  @override
  String get themeImport => '导入自定义';

  @override
  String get themeImportHint => '在下方粘贴受限 CSS 文件。仅允许 :root 和颜色值。';

  @override
  String get themeImportError => '导入主题失败';

  @override
  String get themeCreator => '创作者';

  @override
  String get themeVersion => '版本';

  @override
  String get themeDescription => '描述';

  @override
  String get fileViewerContent => '内容';

  @override
  String get fileViewerDiff => '差异';

  @override
  String get fileViewerBinaryFile => '二进制文件';

  @override
  String get fileViewerLoadError => '加载文件失败';

  @override
  String get agentsMode => '智能体';

  @override
  String get editorMode => '编辑器';

  @override
  String get chat => '聊天';

  @override
  String get editorSelectFile => '从树中选择一个文件以编辑';

  @override
  String get editorUnsavedChanges => '未保存更改';

  @override
  String editorSaveBeforeClose(String name) {
    return '保存对 $name 的更改？';
  }

  @override
  String get editorReload => '重新加载';

  @override
  String binaryFileNotEditable(String name) {
    return '$name 是二进制文件，无法编辑';
  }

  @override
  String get editorDiscard => '放弃';

  @override
  String diffViewMoreLines(int count) {
    return '… 还有 $count 行未显示';
  }

  @override
  String contentViewMoreLines(int count) {
    return '… 还有 $count 行未显示';
  }

  @override
  String get contentViewShowAll => '显示全部';

  @override
  String get showMore => '显示更多';

  @override
  String get loadingMore => '加载更多…';

  @override
  String get terminalNoSessions => '没有终端会话';

  @override
  String terminalTab(int index) {
    return '标签页 $index';
  }

  @override
  String get terminalNewTab => '新建标签页';

  @override
  String get terminalCloseTab => '关闭标签页';

  @override
  String get terminalClose => '关闭终端';

  @override
  String get terminalLocal => '本地终端';

  @override
  String get terminalRemote => '远程终端';

  @override
  String get terminalHide => '隐藏终端';

  @override
  String terminalStartFailed(String error) {
    return '无法启动终端：$error';
  }

  @override
  String get terminalCloseTitle => '关闭终端？';

  @override
  String get terminalCloseBody => '此终端正在运行进程或输出。仍然关闭？';

  @override
  String get terminalTabCloseTitle => '关闭标签页？';

  @override
  String terminalTabCloseBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '此标签页包含 $count 个活动终端。仍要关闭吗？',
      one: '此标签页包含 1 个活动终端。仍要关闭吗？',
    );
    return '$_temp0';
  }

  @override
  String get planHide => '隐藏计划';

  @override
  String get planShow => '显示计划';

  @override
  String get planCollapse => '收起计划';

  @override
  String get planExpand => '展开计划';

  @override
  String get planTitle => '计划';

  @override
  String planProgress(int completed, int total, int percent) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '步',
      one: '步',
    );
    return '$completed / $total $_temp0 · $percent%';
  }

  @override
  String get composerModeCode => '代码';

  @override
  String get composerModePlan => '计划';

  @override
  String get composerModeAsk => '提问';

  @override
  String get terminalLocalOnlyDesktop => '本地终端仅适用于桌面端';

  @override
  String terminalConnectionError(String error) {
    return '[连接错误：$error]';
  }

  @override
  String terminalSessionExited(String code) {
    return '[会话已退出，代码 $code]';
  }

  @override
  String terminalPtyError(String error) {
    return '[PTY 错误：$error]';
  }

  @override
  String get terminalPtyClosed => '[PTY 已关闭]';

  @override
  String terminalProcessExited(String code) {
    return '[进程已退出，代码 $code]';
  }

  @override
  String terminalShellStartFailed(String shell, String error) {
    return '[无法启动 $shell：$error]';
  }

  @override
  String get usage => '用量';

  @override
  String get usageDescription => '由提供商报告的令牌用量，由本服务器追踪';

  @override
  String usageLastDays(int count) {
    return '最近 $count 天';
  }

  @override
  String get usageTotalTokens => '总令牌数';

  @override
  String get usageInput => '输入';

  @override
  String get usageOutput => '输出';

  @override
  String get usageCached => '缓存';

  @override
  String get usageReasoning => '推理';

  @override
  String get usageTurns => '轮次';

  @override
  String get usageCost => '费用';

  @override
  String get usageByDay => '按天';

  @override
  String get usageByProvider => '按提供商';

  @override
  String get usageByModel => '按模型';

  @override
  String get usageEmpty => '暂无使用记录';

  @override
  String get usageLoadFailed => '加载用量失败';

  @override
  String get auditLog => '审计日志';

  @override
  String get auditLogDescription => '本服务器记录的安全相关操作，按时间倒序排列。';

  @override
  String get auditLogEmpty => '还没有审计记录。';

  @override
  String get auditLogLoadFailed => '加载审计日志失败';

  @override
  String get auditLogLoadMore => '加载更多';

  @override
  String get auditLogSystem => '系统';

  @override
  String get devMergeRequestTitle => '开发合并请求';

  @override
  String devMergeRequestBody(String id, String url) {
    return '你正在一个开发合并请求 (#$id) 上。在此处反馈问题：\n\n$url';
  }

  @override
  String devMergeRequestBodyNoUrl(String id) {
    return '你正在一个开发合并请求 (#$id) 上。此构建中没有合并请求 URL。';
  }

  @override
  String get devMergeRequestOpen => '打开';

  @override
  String get devMergeRequestCopy => '复制';

  @override
  String get devMergeRequestClose => '关闭';
}
