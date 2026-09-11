# Changelog
All notable changes to this project will be documented in this file. See [conventional commits](https://www.conventionalcommits.org/) for commit guidelines.

- - -
## v0.61.0 - 2026-09-11
#### Features
- 计划面板默认折叠 - (bdb1f98) - HttpAnimations

- - -

## v0.60.0 - 2026-09-11
#### Features
- 统一应用内消息提示样式 - (b176187) - HttpAnimations

- - -

## v0.59.0 - 2026-09-11
#### Features
- 为 Linux 构建添加 RPM 安装包 - (13ac7cc) - HttpAnimations

- - -

## v0.58.1 - 2026-09-11
#### Bug Fixes
- 编辑器文件操作跟随线程 worktree 工作目录 - (ff8e80b) - HttpAnimations

- - -

## v0.58.0 - 2026-09-11
#### Features
- 本地服务器支持多实例共享并在断线时自愈 - (8e04c43) - HttpAnimations
- 界面区分内置本地服务器并隐藏无关操作 - (e64a73b) - HttpAnimations
- 桌面端启动时拉起内置本地服务器 - (3c8b070) - HttpAnimations
- 服务器支持本地模式固定令牌认证 - (74f808f) - HttpAnimations
#### Bug Fixes
- 回环检测接受方括号 IPv6 且空令牌不跳过 .env - (3845ada) - HttpAnimations
- 本地档案失败路径保持重连检查并统一销毁防护 - (085f69c) - HttpAnimations
- 端点不变时保留 API 实例且删除晋升原子化 - (fdc4a4b) - HttpAnimations
- 健康检查只在认证失效时重启本地服务器 - (bd3b54d) - HttpAnimations
- 本地服务器的启动中止不消耗重试预算且端点文件校验权限 - (b8105dc) - HttpAnimations
- 移除未使用的主档案查询 - (196014e) - HttpAnimations
- 本地档案加载失败时保持重连检查并防止销毁后回调 - (1b2ccbd) - HttpAnimations
- 序列化服务器档案写入并关闭被替换的客户端 - (e36833e) - HttpAnimations
- Windows 锁只锁独立字节且解锁先于关句柄 - (d58cac1) - HttpAnimations
- 本地模式下不再加载 .env 文件 - (2b5e168) - HttpAnimations
- IPv6 回环地址的绑定地址补方括号 - (b08f692) - HttpAnimations
- local 账号改用哨兵密码且仅恢复自身 owner 标记 - (f2d77c4) - HttpAnimations
- 会话认证先尝试 Bearer 再回退 Cookie - (6768625) - HttpAnimations
- 修复停止与启动竞争时的本地服务器泄漏 - (f4cf0df) - HttpAnimations
- 本地档案在切换与启动失败时自动恢复 - (10a7637) - HttpAnimations
- 本地档案令牌不落盘并隐藏 local 账号行 - (b59c9d8) - HttpAnimations
- 收紧本地服务器进程与令牌文件的管理 - (2cd9714) - HttpAnimations
- local 账户已存在时恢复 owner 标记 - (237cbaa) - HttpAnimations
- 本地模式绑定非回环地址时拒绝启动 - (b5513ef) - HttpAnimations
- Bearer 认证头优先于会话 Cookie - (6037098) - HttpAnimations
- 单实例锁支持 Windows 平台 - (df0fcc4) - HttpAnimations
#### Reverts
- 恢复误删的主档案查询 - (8e3cdcd) - HttpAnimations

- - -

## v0.57.0 - 2026-09-11
#### Features
- 编辑器模式下自动打开 AI 修改的文件 - (c5fdbec) - HttpAnimations

- - -

## v0.56.1 - 2026-09-10
#### Bug Fixes
- 设置页按每个 provider 显示各自版本 - (1ec4095) - HttpAnimations

- - -

## v0.56.0 - 2026-09-10
#### Features
- 支持从文件面板拖拽文件/文件夹到输入框作为引用 - (5ad600b) - HttpAnimations
- 启动时探测 Provider 可用性并置灰缺失的 CLI - (2748b28) - HttpAnimations

- - -

## v0.55.0 - 2026-09-10
#### Features
- 在模型选择器中显示价格并为免费模型添加礼物图标 - (87bd91b) - HttpAnimations
- 助手回复时自动链接项目远程对应的 GitLab 合并请求 - (1fa2edf) - HttpAnimations
- 为侧边栏线程添加合并请求徽章和链接菜单 - (09fa0e2) - HttpAnimations
- 添加开发合并请求启动提示对话框 - (7149efa) - HttpAnimations
#### Bug Fixes
- 隐藏 .git 与 .devinorium-attachments 目录 - (3ea2d1f) - HttpAnimations
- 补充中文本地化缺失的合并请求文案 - (90471ce) - HttpAnimations
- 自动链接合并请求后前端实时刷新 - (82943df) - HttpAnimations
- 修复开发合并请求提示重复显示 URL - (03a1dfe) - HttpAnimations
- 移除开发合并请求对话框中的硬编码来源说明 - (b8fa652) - HttpAnimations
- 修复 ACP 版本检测因可执行文件忙导致的测试不稳定 - (7db23e5) - HttpAnimations
#### Performance
- 优化活跃长线程打开与流式更新性能 - (b0a6f33) - HttpAnimations

- - -

## v0.54.0 - 2026-09-10
#### Features
- 添加简体中文语言支持 - (c974025) - HttpAnimations
#### Bug Fixes
- 修正打开线程时计时未包含首屏消息加载时间 - (d20ffff) - HttpAnimations

- - -

## v0.53.1 - 2026-09-10
#### Bug Fixes
- 修复附件添加后不立即显示的问题 - (a668a41) - HttpAnimations

- - -

## v0.53.0 - 2026-09-10
#### Features
- 更新关于页描述文案 - (cefadb6) - HttpAnimations

- - -

## v0.52.1 - 2026-09-10
#### Bug Fixes
- 修复侧边栏线程工作树状态同步 - (833a40b) - HttpAnimations

- - -

## v0.52.0 - 2026-09-10
#### Features
- 将提供者图标移到线程标题左侧 - (b0af930) - HttpAnimations
- 在侧边栏线程标题下方显示工作区名称 - (6c25169) - HttpAnimations

- - -

## v0.51.0 - 2026-09-10
#### Features
- 添加网页版登录提示 - (fc5428d) - HttpAnimations

- - -

## v0.50.1 - 2026-09-10
#### Bug Fixes
- 修复线程内容周期性闪烁问题 - (470d12a) - HttpAnimations

- - -

## v0.50.0 - 2026-09-09
#### Features
- 检测并关联代理运行中创建的工作区 - (028f8e3) - HttpAnimations
- 底部工作区指示器跟随实际工作区更新 - (914f080) - HttpAnimations
#### Bug Fixes
- 修复 clippy 检查与格式化问题 - (34d52fd) - HttpAnimations

- - -

## v0.49.0 - 2026-09-09
#### Features
- 将侧边栏线程的删除按钮移入三点菜单 - (6978ada) - HttpAnimations

- - -

## v0.48.0 - 2026-09-09
#### Features
- 为会话持久化并展示关联的 GitLab 合并请求 - (9c0903e) - HttpAnimations
#### Bug Fixes
- 会话列表显示关联合并请求的编号 - (1a4cc2e) - HttpAnimations

- - -

## v0.47.0 - 2026-09-09
#### Features
- 添加线程环境模式并自动创建工作树 - (ad86a06) - HttpAnimations

- - -

## v0.46.0 - 2026-09-09
#### Features
- 在侧边栏线程标题显示提供商图标 - (069a18e) - HttpAnimations
#### Bug Fixes
- 修复 provider_icons 语义测试中的 await 警告 - (f18cf76) - HttpAnimations

- - -

## v0.45.0 - 2026-09-09
#### Features
- 为模型选择器和设置页使用供应商官方图标 - (d80ec23) - HttpAnimations

- - -

## v0.44.0 - 2026-09-09
#### Features
- 合并模型选择器并按 provider 元数据提供推理档位 - (d72f982) - HttpAnimations
#### Bug Fixes
- 延迟模型选择弹窗的目录加载，避免 build 阶段触发通知 - (22cc7f5) - HttpAnimations
- 模型选择器按 provider 缓存模型列表，避免切 provider 时重复请求 - (45cae63) - HttpAnimations

- - -

## v0.43.0 - 2026-09-09
#### Features
- 新增 Codex CLI 提供商，通过 codex app-server JSON-RPC 驱动 - (72b3615) - HttpAnimations

- - -

## v0.42.0 - 2026-09-08
#### Features
- 跟踪提供商和模型的 token 用量并新增用量页面 - (2e53e25) - HttpAnimations

- - -

## v0.41.4 - 2026-09-08
#### Bug Fixes
- 修复 iOS 云终端退格键无响应 - (36a49cd) - 珍惜

- - -

## v0.41.3 - 2026-09-08
#### Bug Fixes
- iOS 附件支持从相册或相机选择 - (a69c0c7) - HttpAnimations

- - -

## v0.41.2 - 2026-09-08
#### Bug Fixes
- 补齐剩余界面字符串的本地化 - (3e2ae0d) - HttpAnimations

- - -

## v0.41.1 - 2026-09-07
#### Bug Fixes
- 统一语义颜色到主题系统 - (3a8b1a0) - HttpAnimations

- - -

## v0.41.0 - 2026-09-07
#### Features
- 恢复合并后自动发布版本 - (4ba396a) - HttpAnimations
#### Bug Fixes
- 修复自动发布取标签冲突与 Openlyst 触发 - (1988405) - HttpAnimations

- - -

## v0.40.2 - 2026-09-06
#### Bug Fixes
- 为 GitHub Actions 获取标签 - (3c4d214) - HttpAnimations
- 移除 GitHub Actions 工作流中重复的 with 块 - (e0c1f28) - HttpAnimations
- 为 GitHub Actions 检出步骤启用完整历史 - (9e1381e) - HttpAnimations

- - -

## v0.40.1 - 2026-09-06
#### Bug Fixes
- 捕获桌面通知命令缺失时的异常 - (7f1477c) - HttpAnimations
- 发送消息后即时同步会话标题 - (e320248) - HttpAnimations

- - -

## v0.40.0 - 2026-09-06
#### Features
- 在自动运行模式下为提示框添加红色渐变边框 - (c08857f) - HttpAnimations
#### Bug Fixes
- 增加服务器下拉框与代理/编辑器标签按钮的间距 - (85e95fe) - 珍惜/Zhenxi
- 小屏下默认关闭编辑器 agents 面板 - (48c9a94) - HttpAnimations
- 修复合并请求标题栏分支名过长导致的溢出问题 - (9b44e1f) - HttpAnimations
- 修复消息结束后输入框在移动端自动聚焦的问题 - (a45a833) - HttpAnimations
- 修复移动端 composer 下拉控件堆叠问题 - (3699a8d) - HttpAnimations

- - -

## v0.39.0 - 2026-09-05
#### Features
- 合并请求变更页显示增删行数 - (583c1ad) - HttpAnimations
- 实现桌面端文件附件（拖放、粘贴、文件选择） - (733954c) - HttpAnimations
#### Bug Fixes
- 根布局添加 SafeArea 避免 Android 状态栏遮挡内容 - (3579cc1) - HttpAnimations
- 修复前端休眠后连接恢复 - (ad493fe) - HttpAnimations
- 修复模型选择器打开时搜索框自动聚焦弹出键盘的问题 - (f7ecee2) - HttpAnimations
- 终端支持 Ctrl+Shift+C/V 复制粘贴 - (f7afd4b) - HttpAnimations
#### Performance
- 全面优化前端加载与渲染性能 - (118eb3e) - HttpAnimations

- - -

## v0.38.0 - 2026-09-05
#### Features
- 切换模式时自动同步侧边栏文件标签 - (799f188) - HttpAnimations
- 编辑器添加语法高亮 - (7f848a2) - HttpAnimations
- 添加 Lystcode 编辑器模式 - (4c33750) - HttpAnimations
- 添加文件写入接口与校验 - (ae22fca) - HttpAnimations
#### Bug Fixes
- 编辑器无活跃线程时不显示文件列表 - (6c37f29) - HttpAnimations
- 文件树中键单击在新标签页打开文件 - (37b30b8) - HttpAnimations
- 编辑器标签页支持中键关闭 - (0af1356) - HttpAnimations
- 编辑器默认不展开终端 - (31a6035) - HttpAnimations
- 移除文件面板关闭按钮并统一侧边栏样式 - (dcf639e) - HttpAnimations
- 文件面板合并进统一侧边栏 - (f5a5fef) - HttpAnimations
- 终端移动到编辑器内容区底部 - (dfe6b57) - HttpAnimations
- 编辑器终端移到文件面板一侧 - (f003d8c) - HttpAnimations
- 修复右侧面板拖拽方向与预期相反 - (2292242) - HttpAnimations
- 让面板拖拽分隔条更明显、更易命中 - (3aadb9d) - HttpAnimations
- 增宽编辑器右侧面板和主界面文件面板的最大宽度 - (44fbdb0) - HttpAnimations
- 编辑器新打开的文件使用预览标签页 - (d73c370) - HttpAnimations
- 编辑器窄屏浮动切换按钮在面板打开时显示关闭图标 - (182b033) - HttpAnimations
- 文件树随线程/项目切换更新，无项目时显示空状态 - (4891a9e) - HttpAnimations
- 主界面侧边栏和文件面板支持拖拽调整宽度 - (fba69af) - HttpAnimations
- 编辑器左右面板支持拖拽调整宽度 - (7943c5b) - HttpAnimations

- - -

## v0.37.0 - 2026-09-04
#### Features
- 在设置中显示提供程序版本并提示可用更新 - (9e55a86) - HttpAnimations

- - -

## v0.36.0 - 2026-09-04
#### Features
- 设置 Flutter 全平台应用图标 - (3e00894) - HttpAnimations

- - -

## v0.35.0 - 2026-09-04
#### Features
- 添加侧边栏搜索 Ctrl+H 快捷键并补充测试 - (b9d11ed) - HttpAnimations

- - -

## v0.34.0 - 2026-09-04
#### Features
- 把服务器版本号从侧边栏标题移到设置页 - (706c023) - HttpAnimations
- 在设置中添加“关于”页面 - (ce42b9d) - HttpAnimations
#### Bug Fixes
- 关于页面改成图标列表，支持链接改为 work items - (ca73d83) - HttpAnimations
- 修复关于页面的版本加载、链接打开反馈和无障碍问题 - (4137831) - HttpAnimations

- - -

## v0.33.0 - 2026-09-03
#### Features
- 主题选择器改为下拉菜单 - (28821fe) - HttpAnimations

- - -

## v0.32.1 - 2026-09-03
#### Bug Fixes
- 服务器列表 URL 过长时省略显示 - (7884688) - HttpAnimations

- - -

## v0.32.0 - 2026-09-03
#### Features
- 前端拉取并显示服务器版本 - (dcdbfca) - HttpAnimations
- 添加后端服务器版本接口 - (0162fc4) - HttpAnimations

- - -

## v0.31.1 - 2026-09-03
#### Bug Fixes
- 修复深色模式偏灰问题 - (ceb38af) - HttpAnimations

- - -

## v0.31.0 - 2026-09-03
#### Features
- 将文件面板改为展开的文件夹树 - (c07e548) - HttpAnimations
- 添加文件查看器和 Git diff 支持 - (3057bc6) - HttpAnimations

- - -

## v0.30.1 - 2026-09-03
#### Bug Fixes
- 替换示例应用 ID 为 gitlab.openlyst.devinorium - (b3a3048) - HttpAnimations

- - -

## v0.30.0 - 2026-09-02
#### Features
- 添加 Rust 主题 CSS 解析器用于后端校验 - (2e1b4f1) - HttpAnimations
- 添加主题提供者 - (37b6913) - HttpAnimations
- 添加亮色、暗色和 OLED 内置主题 - (84dd883) - HttpAnimations
- 添加 CSS 颜色主题解析器 - (aa20e47) - HttpAnimations
- 添加主题数据模型 - (44400a6) - HttpAnimations
#### Bug Fixes
- 内联 theme 解析器 format 参数 - (35c1092) - HttpAnimations
- 使用 strip_prefix 修复 clippy manual_strip 警告 - (eb56e09) - HttpAnimations
- 修复主题选择器文字换行 - (87c17a5) - HttpAnimations
- 修复解析器行号、元数据错误、分号处理及 UI 布局 - (0f25dbd) - HttpAnimations
- 修正解析器行号、元数据提取和 UI 文案 - (cfec87b) - HttpAnimations
- 完善自定义主题选择器、空名称回退和无效主题回退 - (ae347d5) - HttpAnimations
- 统一 Dart 和 Rust 主题解析器的注释、at-rule 与空属性名处理 - (ffa3d5e) - HttpAnimations
- 让未知内置主题 ID 默认回退到亮色模式 - (9415307) - HttpAnimations
- 让主题解析器拒绝 :root 之外的 at-rules 和选择器 - (1bbf032) - HttpAnimations

- - -

## v0.29.0 - 2026-09-02
#### Features
- 添加 GitLab CI/CD 任务实时日志 - (82acd59) - HttpAnimations

- - -

## v0.28.2 - 2026-09-02
#### Bug Fixes
- 补充各平台网络访问权限 - (5f6bf8f) - HttpAnimations

- - -

## v0.28.1 - 2026-09-02
#### Bug Fixes
- 修复服务器设置中的 URL 验证、国际化文案和删除确认 - (bfa1ad6) - HttpAnimations

- - -

## v0.28.0 - 2026-09-02
#### Features
- 在侧边栏添加快速服务器切换器 - (7287d9a) - HttpAnimations

- - -

## v0.27.0 - 2026-09-02
#### Features
- 添加取消自动合并按钮 - (6bbbdb1) - HttpAnimations

- - -

## v0.26.0 - 2026-09-01
#### Features
- 在文件面板中显示 Git 状态 - (5e22677) - 珍惜

- - -

## v0.25.0 - 2026-09-01
#### Features
- 在设置页添加服务器管理 UI - (8ba920b) - HttpAnimations
- 重构 AppState 和认证状态以支持多服务器 - (59cd134) - HttpAnimations
- 添加多服务器状态管理 - (b9cba32) - HttpAnimations
- 添加服务器配置、注册表和迁移 - (5d8429d) - HttpAnimations

- - -

## v0.24.0 - 2026-08-31
#### Features
- 发布前端二进制到 GitLab releases - (52cc985) - HttpAnimations

- - -

## v0.23.0 - 2026-08-31
#### Features
- 线程失败时通过 kDebugMode 守护的日志输出调试信息 - (5a3ae66) - HttpAnimations

- - -

## v0.22.0 - 2026-08-31
#### Features
- 合并请求操作按钮改为紧凑 macOS 风格 - (bae5476) - HttpAnimations
- 前端实现乐观消息发送与回显 - (31ee222) - HttpAnimations
- 后端添加 client_message_id 支持并保证唯一性 - (92d98cf) - HttpAnimations
- 添加可展开的流水线任务视图 - (56a4dee) - HttpAnimations
- 添加 GitLab 流水线任务后端接口 - (7e107f1) - HttpAnimations
- 将桌面窗口控制按钮从顶栏移到侧边栏 - (72bfed3) - HttpAnimations
- 实现 /ask 前缀切换 composer 为 ask 模式并剥离前缀发送 - (cde3ce3) - HttpAnimations
- 版本号使用胶囊样式显示 - (e032635) - HttpAnimations
- 在侧边栏标题旁显示版本号 - (620c63a) - HttpAnimations
#### Bug Fixes
- 设置侧边栏新增克隆根条目以对齐管理主题索引 - (7b1f050) - HttpAnimations
- 顶栏状态药丸与标题同行显示 - (71bad27) - HttpAnimations
- 将标题栏文本左对齐并截断过长内容 - (5e55745) - HttpAnimations
- 修复展开其他项目时同时重新展开活跃线程项目的问题 - (132a15c) - HttpAnimations
- 修复顶栏按钮被拖拽区域覆盖导致无法点击的问题 - (ec0412f) - HttpAnimations
- 侧边栏标题左对齐 - (debae54) - HttpAnimations

- - -

## v0.21.0 - 2026-08-30
#### Features
- 切换分支后自动获取远程状态以显示拉取提示 - (423126a) - HttpAnimations

- - -

## v0.20.0 - 2026-08-30
#### Features
- 添加项目线程“显示更多”折叠按钮 - (7e1de3e) - HttpAnimations
#### Bug Fixes
- 会话创建时立即持久化 devin_session_id 并等待回调完成 - (6be9bc9) - HttpAnimations
- 在模型失败时持久化部分回复以保留上下文 - (7b0b78f) - HttpAnimations

- - -

## v0.19.0 - 2026-08-29
#### Features
- 实现消息滚动分块加载和卸载 - (a37563d) - HttpAnimations
- 实现 Flutter 消息分页、折叠和流式 UI - (d82877c) - HttpAnimations
- 实现消息 turns 分页、size budget 和流式加载后端 - (1e142e8) - HttpAnimations
#### Bug Fixes
- 修复线程顶部滚动锁定并优化分页加载 - (8875d49) - HttpAnimations

- - -

## v0.18.0 - 2026-08-29
#### Features
- 添加线程打开耗时调试日志 - (b7ec85d) - HttpAnimations

- - -

## v0.17.0 - 2026-08-28
#### Features
- 重新设计侧边栏为紧凑美观的 t3code 风格 - (d9433ca) - HttpAnimations
- 分支和工作树创建改为对话框提示 - (60a11ea) - HttpAnimations
- 将分支工具栏改为 t3code 紧凑菜单风格 - (b19eb32) - HttpAnimations
- 在聊天编辑器下方添加分支和工作树工具栏 - (7722d15) - HttpAnimations

- - -

## v0.16.0 - 2026-08-27
#### Features
- 添加服务器端 git clone 功能 - (67adeb2) - HttpAnimations
- 关闭非空终端和标签页时添加确认对话框 - (f0a33fa) - HttpAnimations
- 终端标签页作为工作区，支持添加多个终端窗口 - (80c6d64) - HttpAnimations
- 终端支持浏览器式标签页 - (c436a20) - HttpAnimations
- 终端按线程隔离并保持会话存活 - (8fe87e5) - HttpAnimations
- 将终端改为底部可调整面板并移除状态文字 - (009dd8b) - HttpAnimations
- 添加前端本地和远程终端 UI 与 WebSocket 连接 - (4b72a31) - HttpAnimations
- 添加后端远程终端管理器与 WebSocket 路由 - (6a31a12) - HttpAnimations
#### Bug Fixes
- 居中对齐终端会话卡片的关闭按钮 - (d8bd437) - HttpAnimations
- 移除终端面板的关闭全部按钮 - (41ce879) - HttpAnimations
- 移除终端工具栏的状态点 - (ce86bfc) - HttpAnimations
- 将本地 PTY 恢复为规范模式以修复输入回显 - (6a10ce0) - HttpAnimations
- 移除终端管理器中的冗余闭包 - (aec41de) - HttpAnimations

- - -

## v0.15.0 - 2026-08-27
#### Features
- 将 AskRequestPanel 改为分步问答向导 - (409d5b7) - HttpAnimations

- - -

## v0.14.0 - 2026-08-26
#### Features
- 持久化计划覆盖层折叠与隐藏状态 - (a4e46f2) - HttpAnimations
- 删除线程时添加滑出并收起动画 - (ec79bb7) - HttpAnimations
- 重新设计计划为顶部可折叠覆盖层 - (ec647ce) - HttpAnimations
- 实现 Flutter 计划模型、状态和侧边栏 UI - (189b802) - HttpAnimations
- 将计划检测接入线程运行、SSE 和 API 端点 - (162d8a9) - HttpAnimations
- 添加后端计划解析器、数据库模型和持久化 - (1a804e1) - HttpAnimations
- 关联 MR 徽标点击打开内置合并请求面板 - (6ea53e9) - HttpAnimations
- 线程页应用栏展示关联合并请求徽标 - (5658395) - HttpAnimations
- 前端添加 MergeRequestLink 模型与关联 MR 状态加载 - (624ad24) - HttpAnimations
- 添加按分支查询关联合并请求的 API 路由与测试 - (59fe527) - HttpAnimations
- 添加 GitService::remote_url 与 GitLab 远程地址解析 - (fb25e20) - HttpAnimations
- 添加可复用的文件夹选择器并接入克隆根设置 - (8cf7f9b) - HttpAnimations
- 添加 clone root 前端页面、状态与 API 客户端 - (95a3fe2) - HttpAnimations
- 添加 clone root 后端迁移、数据库字段与 API - (2b94e38) - HttpAnimations
- 在应用内渲染 GitLab 议题链接 - (b0c83c0) - HttpAnimations
- 为助手消息添加模型名称标签 - (28d284f) - HttpAnimations
- 在 GitLab 合并请求视图中添加关闭、重新打开、合并和流水线成功后合并操作 - (b75b81e) - HttpAnimations
- 在 MR 查看器中添加流水线标签页并修复静态分析警告 - (3eab45e) - HttpAnimations
- 在 MR 查看器中显示 GitLab 流水线状态 - (2499687) - HttpAnimations
- 优化 Git 设置页面并添加 GitHub/GitLab 图标 - (5d8bb44) - HttpAnimations
- 添加 GitLab 合并请求查看面板 - (3e98d7a) - HttpAnimations
- 在账户区域显示连接状态图标 - (70f03bd) - HttpAnimations
- 实现前端分块懒加载和文件分页 - (6a273e2) - HttpAnimations
- 实现后端分页支持和批量运行状态接口 - (a24d460) - HttpAnimations
- 为置顶项目与线程添加左侧视觉标识 - (092a414) - HttpAnimations
- 添加项目和线程置顶功能 - (f114ac5) - HttpAnimations
- 使用 Flutter 自定义桌面标题栏替换原生 GTK 标题栏 - (bf56925) - HttpAnimations
- 添加 Markdown 代码块语法高亮、语言标签和复制按钮 - (847b4e6) - HttpAnimations
- 添加项目类型检测和图标显示 - (82697df) - HttpAnimations
- 线程完成时发送通知和提示音 - (2234894) - HttpAnimations
- 创建新线程时自动清理空线程 - (4556d8b) - HttpAnimations
- 文件管理器显示文件类型图标和颜色 - (13ec3e4) - HttpAnimations
- 添加侧边栏连接状态指示器 - (bea61b8) - HttpAnimations
- 添加删除项目 UI - (f77afa4) - HttpAnimations
- 加载线程时显示加载指示器 - (1916950) - HttpAnimations
- 在输入框上方显示运行计时器 - (20bee8e) - HttpAnimations
- 命令执行工具改为 t3code 风格终端卡片 - (08d6186) - HttpAnimations
- 命令执行工具调用渲染在思考块外部 - (78b5200) - HttpAnimations
- 文件编辑改为 t3code 风格的内联差异卡片 - (38266f9) - HttpAnimations
- 文件编辑工具调用渲染在思考块外部 - (8493ef1) - HttpAnimations
- 前端添加 EditFileTool 组件渲染文件编辑差异 - (304f8eb) - HttpAnimations
- 后端保留 ACP Diff 内容并在 ToolCallEvent 添加 diffs 字段 - (937d5fd) - HttpAnimations
- ask 单选支持 Other 自由输入选项 - (48aa547) - HttpAnimations
- ask 请求现在显示在聊天输入区 - (5aa5cb9) - HttpAnimations
- 在 Flutter 中添加 ask 模型、流事件处理与对话框 - (4cfb01c) - HttpAnimations
- 添加 ask 请求回调、响应端点与重连状态保持 - (b8cc40c) - HttpAnimations
- 在 RunState 与 AppState 中持久化 ask 请求状态 - (47f561e) - HttpAnimations
- ACP 初始化时宣告 elicitation 能力并处理 elicitation/create - (c6c6513) - HttpAnimations
- 添加 ask 请求类型与 ACP 转换 - (e38b151) - HttpAnimations
- 实现项目和线程重命名前端界面 - (4d16802) - HttpAnimations
- 添加项目重命名后端接口 - (3282782) - HttpAnimations
- 支持在获取会话详情时附带消息列表 - (e3ac78c) - HttpAnimations
- 为 getThread 添加 includeMessages 参数 - (13e4cc1) - HttpAnimations
- 客户端工厂接入请求预加载包装器 - (d46e5cf) - HttpAnimations
- 添加 API 请求缓存包装器 - (7c05bae) - HttpAnimations
- 添加请求预加载与缓存工具 - (2c1bad9) - HttpAnimations
- 分支选择弹窗默认分支置顶并与其他分支分隔 - (382e3ff) - HttpAnimations
- 在分支列表中添加拉取按钮 - (17cf38f) - HttpAnimations
- 添加前端状态管理分支拉取 - (3b6ccd3) - HttpAnimations
- 添加前端分支拉取 API 封装 - (68eab54) - HttpAnimations
- 添加分支拉取 API 端点 - (1fe5be2) - HttpAnimations
- 添加后端分支拉取服务 - (8f444b8) - HttpAnimations
- 为线程卡片添加统一背景 - (2ae28c7) - HttpAnimations
- 重新设计侧边栏为更圆润现代的样式 - (11002c9) - HttpAnimations
- 登录页服务器 URL 拆分为协议下拉框和地址输入框 - (b3c7aaa) - HttpAnimations
- 移除配对文件登录，支持直接 URL、用户名密码登录 - (50b4854) - HttpAnimations
- 添加停止运行模型的功能 - (07698e0) - HttpAnimations
- 前端从运行快照恢复流式状态并在线程列表显示运行中 - (6879da1) - HttpAnimations
- 在线程运行状态中累积流式输出并生成快照 - (98b5704) - HttpAnimations
- 在作曲器中粘贴文件路径时直接添加附件 - (d759191) - HttpAnimations
- 在输入框按 Shift+Tab 循环切换作曲器模式 - (996c036) - HttpAnimations
- 实现 composer 模式选择与后端透传 - (edc24a6) - HttpAnimations
- 让消息列表和输入框占满整个窗口宽度 - (25be53b) - HttpAnimations
- Shift+点击删除线程时跳过确认对话框 - (334a2be) - HttpAnimations
- 让消息里的链接可点击并在外部浏览器打开 - (6529acd) - HttpAnimations
- 实现消息有序 parts 渲染，保留思考、文本和工具调用流顺序 - (60f3763) - HttpAnimations
- 在 Git 分支对话框中显示领先/落后计数并添加拉取/推送按钮 - (9c8fede) - HttpAnimations
- 项目列表返回 is_repo 和 branch，侧边栏直接展示 - (98fcbaf) - HttpAnimations
- 添加 Git API 集成测试与工作目录校验 - (02781f5) - HttpAnimations
- 集成 Git 连接与修正测试编译 - (7e7fc66) - HttpAnimations
- 线程页显示当前分支 - (c31790e) - HttpAnimations
- 侧边栏显示 Git 分支与工作树入口 - (5675c6b) - HttpAnimations
- 添加分支与工作树管理弹窗 - (e9016c6) - HttpAnimations
- 前端添加 Git 模型与 API - (8c0a15a) - HttpAnimations
- 添加项目 Git API 路由 - (7b536d0) - HttpAnimations
- 添加 GitService 与仓库检测 - (cf3e6d1) - HttpAnimations
- 为 threads 表添加 branch 和 worktree_path 字段 - (2397ef9) - HttpAnimations
#### Bug Fixes
- 修复单实例锁并发测试在 CI 上的竞态失败 - (1ccd39f) - HttpAnimations
- 修复大线程分页测试在慢 CI 上超时失败 - (96bd06e) - HttpAnimations
- 删除线程动画向左滑动并加快 - (90bba19) - HttpAnimations
- 修复计划 XML 泄漏并调整计划面板样式 - (5644d86) - HttpAnimations
- 计划解析器 panic 不再崩溃后端 - (e282fc5) - HttpAnimations
- 修复 PlanParser trim_buffer 多字节 UTF-8 字符边界 panic - (4967390) - HttpAnimations
- 移除 dialogs.dart 中未使用的 models 导入 - (ec3a9fa) - HttpAnimations
- 克隆根路径保存前进行规范化并阻止路径穿越 - (8cf4e78) - HttpAnimations
- 修复 glab 命令偶发的 Text file busy 错误 - (9492890) - HttpAnimations
- 合并超时时轮询 GitLab 状态而不是直接报错 - (a29e835) - HttpAnimations
- 合并操作使用更长超时并显示 Working... 状态 - (3bb135a) - HttpAnimations
- 修复发送消息时用户消息不显示且线程闪烁的问题 - (a639ae0) - HttpAnimations
- 修复线程打开和发送消息时滚动位置不在底部的问题 - (5025833) - HttpAnimations
- 使用 MarkdownBody 渲染合并请求评论 - (e9a81fe) - HttpAnimations
- 修复桌面端合并请求面板使用错误 API 客户端的问题 - (d1ef47e) - HttpAnimations
- 使 Git 分支对话框即时打开并异步加载内容 - (907e42a) - HttpAnimations
- 修复 Git 面板分支不同步和性能问题 - (9f96cb4) - HttpAnimations
- 限制项目列表并行 git 检测数量 - (6b5ea44) - HttpAnimations
- 将置顶菜单图标颜色改为主题色 - (32e0209) - HttpAnimations
- 移除项目和线程的独立置顶按钮，仅保留三点菜单入口 - (8a92678) - HttpAnimations
- 修复窗口缩放清除输入框状态的问题 - (2f9db7a) - HttpAnimations
- 移除代码块内水平滚动，改用长行换行以避免滚动冲突 - (09ef3f7) - HttpAnimations
- 使用自定义水平滚动组件避免与列表滚动冲突 - (b95e0c8) - HttpAnimations
- 在代码块中禁用文本选择以修复列表滚动 - (3feeee1) - HttpAnimations
- 修复代码块阻止页面垂直滚动的问题 - (30dc01d) - HttpAnimations
- 复制按钮改为内联状态切换而非 SnackBar - (39ebcac) - HttpAnimations
- 修复通知因 reducer 提前修改 phase 而不触发 - (87cb6ac) - HttpAnimations
- 添加通知流程调试日志 - (aa85a30) - HttpAnimations
- 修复通知只触发一次的竞态条件 - (51c3be9) - HttpAnimations
- 通知系统支持桌面平台并修复后台线程通知 - (e3c45a5) - HttpAnimations
- 修复窄屏下文件管理器无法打开的问题 - (053cdbe) - HttpAnimations
- 移除用户可见的 _frontend 名称 - (69c2567) - HttpAnimations
- 停止后保留部分输出直到持久化完成 - (8be0636) - HttpAnimations
- 停止时保存 session ID 以保留 AI 上下文 - (9c1e185) - HttpAnimations
- 停止聊天时保留进行中的思考块 - (5e2da31) - HttpAnimations
- 回车键发送消息时不再插入换行 - (d837649) - HttpAnimations
- 计时器稍微右移 - (50d3ece) - HttpAnimations
- 计时器与输入框对齐 - (f599a7a) - HttpAnimations
- 计时器左对齐而非居中 - (7f5f7aa) - HttpAnimations
- 命令为空时回退显示标题 - (0d7c10a) - HttpAnimations
- 移除 ask 面板 TextField 的 autofocus，使用 post-frame 请求焦点避免渲染崩溃 - (16009d9) - HttpAnimations
- ask 面板的数字输入校验更严格，补充测试 - (7c98c77) - HttpAnimations
- 在 send 非流式循环中处理 ask_request 并修复 ask 边界情况 - (6c50f44) - HttpAnimations
- 更新 provider 测试中的 SendOptions 初始化 - (cf36c8d) - HttpAnimations
- remove redundant project expand/collapse chevron - (5d8900e) - HttpAnimations
- 三点菜单按钮提示改为 Options - (d37652f) - HttpAnimations
- 修复 flutter analyze 警告 - (083e851) - HttpAnimations
- TTL 为零时不缓存，仅合并进行中的请求 - (79abbd1) - HttpAnimations
- 点击项目时不再清除当前会话 - (32ba634) - HttpAnimations
- 去除默认分支检测中的换行符并补充测试 - (7d7f217) - HttpAnimations
- 重复项目名或路径返回 409 - (c98e6ba) - HttpAnimations
- 修复线程外键和设备唯一索引迁移 - (47893e6) - HttpAnimations
- 生成中停止按钮使用红色背景 - (186a173) - HttpAnimations
- 过滤远程符号引用如 origin/HEAD - (9b2b527) - HttpAnimations
- 分支列表去除本地与远程重复项 - (191f2a2) - HttpAnimations
- 在构建 Flutter web 前清理缓存并重新获取依赖 - (baa76cc) - HttpAnimations
- 修复测试中 feature 分支起点 - (8332dc1) - HttpAnimations
- 移除项目内嵌的线程滚动，统一由侧边栏整体滚动 - (6d86513) - HttpAnimations
- 仅项目头部可触发拖拽排序 - (74945ae) - HttpAnimations
- 仅高亮当前线程，不再高亮整个项目 - (9fc8b32) - HttpAnimations
- 登录页恢复已保存 URL 时正确更新协议下拉框 - (8f35400) - HttpAnimations
- 启动时检查数据库锁定并获取单例锁防止多实例并发 - (c65400e) - HttpAnimations
- 原生客户端发送 Origin 头以通过 CSRF 校验 - (58a43a8) - HttpAnimations
- 修复 bypass 模式仍弹出权限请求的问题 - (fb34b28) - HttpAnimations
- 修复工具调用输出预览截断中文时的 panic - (e3ed257) - HttpAnimations
- 修复持久化运行中的事件丢失与状态同步问题 - (bd6e9c9) - HttpAnimations
- 修复作曲器模式徽章文字对比度 - (1c30dbf) - HttpAnimations
- 使用 ACP session/set_mode 设置 plan/ask/code 模式 - (4032787) - HttpAnimations
- 为 Devin ACP 的 plan/ask 模式添加 prompt 前缀 - (65468cd) - HttpAnimations
- 修复前端分析警告和测试配置 - (8699d76) - HttpAnimations
- 发送消息后自动重新聚焦输入框 - (0c2bd0e) - HttpAnimations
- web 和 Linux 下链接打不开 - (17ab3a7) - HttpAnimations
- 合并连续的 thinking 片段避免碎成多行 - (ff4c4ea) - HttpAnimations
- thinking 块内按流顺序交错显示文本和 tool call - (5442ec4) - HttpAnimations
- 把 tool call 收进 thinking 块内 - (a5b2c7a) - HttpAnimations
- 将分段的 thinking 内容合并为一个思考块 - (39d4fc2) - HttpAnimations
- 修复分支列表中长分支名溢出 - (385fd1f) - HttpAnimations
- 将分支显示移到副标题，优先显示项目名称 - (524f6ec) - HttpAnimations
- 侧边栏分支文本限制宽度，防止 ListTile 溢出 - (01cedba) - HttpAnimations
- 使用分支或 worktree 时不自动关闭对话框 - (a061d2f) - HttpAnimations
- 分支对话框关闭按钮改为 Close - (3038384) - HttpAnimations
- 分支图标区分本地和远程 - (84c5c2b) - HttpAnimations
- 当前分支从活动线程获取并禁用当前分支按钮 - (8dfc9bb) - HttpAnimations
- 远程分支 checkout 添加 track 并刷新分支列表 - (f3f50fc) - HttpAnimations
- 使用分支时自动创建新线程并设置上下文 - (df9b615) - HttpAnimations
- 修复分支列表解析并改成分支选择下拉框 - (d90386e) - HttpAnimations
- 防止 Git 分支弹窗在窄屏上溢出 - (81cc53c) - HttpAnimations
- 修复 Git 连接的 API 契约并补充测试 - (2123bf0) - HttpAnimations
- 改进 Git 连接解析与测试 - (bacdb4e) - HttpAnimations
- 修复安全检查与工作树主检测 - (c78fbbb) - HttpAnimations
#### Performance
- 只显示变更行和上下文而非整个文件 - (0da2456) - HttpAnimations
- 优化文件编辑差异渲染性能 - (3ceae3c) - HttpAnimations
- 在 index.html 预加载 Flutter 与业务脚本 - (111497a) - HttpAnimations
- 设置页并行预加载所有数据 - (488e139) - HttpAnimations
- 并行加载模型、项目、会话与分组 - (d128e4f) - HttpAnimations
- 并行加载会话详情与运行状态 - (47cc258) - HttpAnimations
- 为展开的项目线程列表添加独立滚动 - (277326b) - HttpAnimations
- 优化大线程的加载与前端渲染 - (d20bf7b) - HttpAnimations

- - -

## v0.13.0 - 2026-08-15
#### Features
- 添加侧边栏项目拖拽排序 - (be58f7d) - HttpAnimations
#### Bug Fixes
- 整个项目卡片支持点击拖动 - (6495da5) - HttpAnimations

- - -

## v0.12.0 - 2026-08-15
#### Features
- 选择当前文件夹时自动填充项目名称 - (6f1d0fe) - HttpAnimations
#### Bug Fixes
- 加载时侧边栏项目默认折叠 - (e191dbe) - HttpAnimations

- - -

## v0.11.2 - 2026-08-15
#### Bug Fixes
- 修复 README 配置表格格式 - (5e1ab3d) - HttpAnimations

- - -

## v0.11.1 - 2026-08-14
#### Bug Fixes
- 移除 dialogs_test 中未使用的导入 - (1056e88) - HttpAnimations
- 修复从主目录添加项目时提示 invalid project path 的问题 - (d23c394) - HttpAnimations

- - -

## v0.11.0 - 2026-08-14
#### Features
- 美化读文件工具卡片 - (c2f0c9d) - HttpAnimations

- - -

## v0.10.0 - 2026-08-14
#### Features
- 前端支持重连后台 run 并订阅事件 - (7e9d636) - HttpAnimations
- 在后台运行线程并添加状态端点 - (b15baa5) - HttpAnimations
- wire thread runner into app state - (76789ba) - HttpAnimations
- add background thread runner - (07d3e40) - HttpAnimations
#### Bug Fixes
- resume 时不重复刷新列表，保留运行中 composer - (ab0a9c1) - HttpAnimations
- 恢复未发送输入并在 resume 时刷新消息 - (8a3448b) - HttpAnimations
- 修复线程互斥、权限校验和同步 send 超时 - (dca7324) - HttpAnimations

- - -

## v0.9.1 - 2026-08-14
#### Bug Fixes
- readme.md - (d0a136b) - HttpAnimations
- 修复 release 任务在 main 分支上的竞态失败 - (1902885) - HttpAnimations

- - -

## v0.9.0 - 2026-08-14
#### Features
- 添加多阶段容器镜像 - (821e1c5) - HttpAnimations

- - -

## v0.8.1 - 2026-08-14
#### Bug Fixes
- 当项目工作目录不可写时正确传递附件 - (171489e) - HttpAnimations

- - -

## v0.8.0 - 2026-08-14
#### Features
- 前端文案全部迁移到 AppLocalizations（仅支持英文） - (b6f66cc) - HttpAnimations
- 在个性化设置中添加语言选项 - (7657449) - HttpAnimations

- - -

## v0.7.1 - 2026-08-14
#### Bug Fixes
- 取消 SSE 时不再关闭 native 客户端的共享 http client - (09a3e84) - HttpAnimations

- - -

## v0.7.0 - 2026-08-14
#### Features
- 前端根据运行状态和消息内容计算线程标签 - (759a78f) - HttpAnimations
- 前端展示线程标签 - (49417fe) - HttpAnimations
- 后端根据消息和权限请求计算线程标签 - (00903eb) - HttpAnimations
#### Bug Fixes
- 防止 ThreadTag 在线程列表项中溢出 - (fc23354) - HttpAnimations
#### Reverts
- 移除后端线程标签计算 - (86da340) - HttpAnimations

- - -

## v0.6.0 - 2026-08-13
#### Features
- 从 flutter_markdown 迁移到 flutter_markdown_plus - (7281409) - HttpAnimations
- 在无线程或发送时禁用模型和权限选择器 - (b14d407) - HttpAnimations
- 将创建用户表单提取到弹窗，管理页显示全宽按钮 - (386383b) - HttpAnimations
- 为 owner 账户显示禁用的 Active 开关以保持列对齐 - (966fd9a) - HttpAnimations
- 在管理页面用户列表添加列标题 - (8680dd4) - HttpAnimations
- 重构设置页为侧边栏主题导航并添加 Owner 徽章 - (23642c1) - HttpAnimations
- 添加主题模式设置并持久化到 SharedPreferences - (5ff0840) - HttpAnimations
- 在事务内限制设备数量，验证配对文件大小，并支持从客户端读取服务器地址 - (72f7dde) - HttpAnimations
- 为设备会话添加 device_id，避免在列表中暴露完整 token，并加强配对安全校验 - (1b43478) - HttpAnimations
- 实现 Flutter 原生客户端、配对流程与设备管理 - (de3a8b2) - HttpAnimations
- 添加跨平台配对所需的后端认证、设备管理与 CORS 支持 - (12a9e2a) - HttpAnimations
#### Bug Fixes
- 反转管理页面用户 Active 开关含义 - (8dd8261) - HttpAnimations
- 管理页面用户行的 2FA 状态与 Active 开关列对齐 - (b5688f5) - HttpAnimations
- 为侧边栏 ListTile 包裹 Material 避免 DecoratedBox 隐藏背景 - (e3522f7) - HttpAnimations
- 将配对设置界面的文案统一为英文 - (6aef2a7) - HttpAnimations
- 完善 Linux 下配对文件选择器的回退与测试 - (45a7729) - HttpAnimations
- 在 Linux 无 XDG Portal 时优雅降级配对文件选择，并提供手动路径输入 - (d85ded9) - HttpAnimations

- - -

## v0.5.0 - 2026-08-13
#### Features
- 从侧边栏用户菜单移除 Accounts 入口 - (451c57f) - HttpAnimations
- 在前端设置页添加账号管理 - (39dde6f) - HttpAnimations
- 替换邀请码为 owner 账户管理 - (850bc96) - HttpAnimations

- - -

## v0.4.0 - 2026-08-13
#### Features
- 添加 provider 命令配置与测试按钮 - (8ad429a) - HttpAnimations
- 添加 AI provider 设置支持 - (ffe1982) - HttpAnimations
#### Bug Fixes
- 规范化 Provider 命令输入 - (d70d850) - HttpAnimations
- 修复 Provider 测试超时与前端状态管理 - (3d0c853) - HttpAnimations

- - -

## v0.3.0 - 2026-08-12
#### Features
- 添加 misc 提交类型与 commit-msg hook - (a4bd4cb) - HttpAnimations
#### Bug Fixes
- 修复移动端设置页无法打开侧边栏 - (1a3ff0c) - HttpAnimations

- - -

## v0.2.0 - 2026-08-12
#### Features
- 添加 GitLab 自动发布流水线 - (29309a3) - HttpAnimations
#### Bug Fixes
- 修复 GitLab CI 发布阶段的 glab 登录检查 - (25de6ba) - HttpAnimations

- - -

Changelog generated by [cocogitto](https://github.com/cocogitto/cocogitto).