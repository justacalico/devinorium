# Changelog
All notable changes to this project will be documented in this file. See [conventional commits](https://www.conventionalcommits.org/) for commit guidelines.

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