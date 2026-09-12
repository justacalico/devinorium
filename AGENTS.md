- Read README.md, AGENTS.md, and CLAUDE.md before proposing or making any changes.
- Use subagents to review code harshly for bugs, issues, and correctness before any merge.
- Do not create god files; keep modules focused and small.
- Do not blindly merge. Verify behavior by running the full backend and frontend test suites locally. Do not finish until `cargo test` and `flutter test` both pass. Do not push commits or check GitLab pipeline status as a substitute for local verification.
- Add new tests for everything new. Every piece of new code must be testable, both in Dart (Flutter) and Rust (backend).
- Do a final harsh subagent review of all changes before finishing.
- Do not squash merge requests. Use a regular merge commit so each conventional commit is preserved for the changelog and history.
- Only when the user asks to run a dev server, start the backend with the `--dev` flag (random port, no login, in-memory database). Never start a dev server any other way or on your own initiative.

## Local verification

Run the full test suites locally and confirm they are green before considering any task complete. Do not finish, open a merge request, or push commits just to trigger CI while tests are failing.

Backend:

```bash
cargo test
```

Frontend (from the `flutter/` directory):

```bash
cd flutter
flutter test
```

Do not rely on GitLab pipeline status or `git push` output instead of running these commands locally. Both suites must pass before finishing.

## Commit message format

All commits must follow Conventional Commits so cocogitto can bump versions and generate changelogs.

Rules:
- Use one of these types: `feat`, `fix`, `chore`, `ci`, `docs`, `refactor`, `style`, `test`, `perf`, `revert`, `build`, `misc`.
- The type and colon are in English; the description can be in Chinese.
- Keep the first line short and in this exact format: `<type>: <description>`.
- Use the imperative mood.
- Do not add a period at the end of the subject line.
- Only use `feat` for new features and `fix` for bug fixes.
- For non-code changes, use `chore`, `ci`, `docs`, or `misc` as appropriate.
- If a commit does not fit any specific type, use `misc: <description>`. It will be grouped under "Other" in the changelog and will not trigger a version bump.

Examples:

feat: 添加 GitLab 自动发布流水线
fix: 修复 WebSocket 重连问题
chore: 更新 cocogitto 配置
ci: 添加 release job 的资源组
docs: 完善 AGENTS.md 说明
test: 添加用户认证单元测试
misc: 临时提交说明

## Git hooks

Install the commit message hook so non-conventional subjects are automatically prefixed with `misc:` and do not break `cog check`:

```bash
git config core.hooksPath .githooks
```

The hook is a safety net. Still try to write proper conventional commits when possible.
