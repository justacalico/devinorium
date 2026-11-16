//! Plugins: installable bundles that extend what agents can see and do.
//!
//! A plugin is a directory, compatible with the Claude Code plugin layout:
//!
//! ```text
//! my-plugin/
//! ├── .claude-plugin/plugin.json   (or plugin.json at the root)
//! ├── skills/<name>/SKILL.md
//! ├── commands/<name>.md
//! ├── hooks/hooks.json
//! └── .mcp.json
//! ```
//!
//! Two scopes exist. User plugins live under `~/.config/devinorium/plugins`
//! and contribute everything: skills and commands (the composer `/` picker
//! and prompt expansion), `.mcp.json` servers merged into owner runs, and
//! `hooks.json` shell commands fired on run lifecycle events, also only
//! for owner-initiated runs - both are code execution as the server user.
//! Project plugins live under `<cwd>/.devinorium/plugins` and contribute only
//! skills and commands - a cloned repository may add prompt text (the same
//! trust level as its `.devin/skills` today) but must never gain command
//! execution or tool servers just by being opened.
//!
//! Enabled state lives in `~/.config/devinorium/plugins.json` under a
//! `disabled` name list so toggling never writes inside the plugin dir.

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::mcp::McpServerConfig;

/// Events a plugin hook can subscribe to, named after the Claude Code hook
/// events they mirror.
pub const EVENT_PROMPT_SUBMIT: &str = "UserPromptSubmit";
pub const EVENT_SESSION_START: &str = "SessionStart";
pub const EVENT_STOP: &str = "Stop";

/// Default per-hook timeout when `hooks.json` sets no `timeout`.
const DEFAULT_HOOK_TIMEOUT: Duration = Duration::from_secs(30);
/// Hard cap on a single hook's timeout, whatever the plugin asks for.
const MAX_HOOK_TIMEOUT: Duration = Duration::from_secs(120);
/// Cap on captured hook stdout/stderr; a runaway print is truncated, not
/// buffered without bound.
const MAX_HOOK_OUTPUT: usize = 64 * 1024;

/// `plugin.json`, at `.claude-plugin/` first and the root as a fallback.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct PluginManifest {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub description: String,
    /// Claude Code allows a string or an object; both flatten to a string.
    #[serde(default)]
    pub author: serde_json::Value,
}

/// Where a plugin was discovered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginSource {
    /// `~/.config/devinorium/plugins` - contributes every feature.
    User,
    /// `<cwd>/.devinorium/plugins` - contributes skills and commands only.
    Project,
}

/// How a user-scope plugin landed in the plugins root, for display.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallKind {
    /// Dropped in or copied as a plain directory.
    Dir,
    /// Git clone; updatable via `git pull`.
    Git,
    /// Symlink to a directory elsewhere (local path installs and
    /// marketplace entries).
    Link,
}

/// A discovered plugin.
#[derive(Debug, Clone)]
pub struct Plugin {
    /// The plugin directory, canonicalized so symlink installs resolve.
    pub dir: PathBuf,
    /// The directory entry under the plugins root (pre-canonicalization),
    /// when it lives in a managed root. `None` for entries reached through
    /// a symlink target's own listing.
    pub entry: Option<PathBuf>,
    pub name: String,
    pub version: String,
    pub description: String,
    pub author: String,
    pub source: PluginSource,
    pub enabled: bool,
    pub install: InstallKind,
}

/// The user-scope plugins root: `~/.config/devinorium/plugins`.
pub fn plugins_root(home: &Path) -> PathBuf {
    home.join(".config").join("devinorium").join("plugins")
}

/// Where marketplace clones live: `~/.config/devinorium/marketplaces`.
pub fn marketplaces_root(home: &Path) -> PathBuf {
    home.join(".config").join("devinorium").join("marketplaces")
}

/// The project-scope plugins root for a working directory.
fn project_plugins_root(cwd: &Path) -> PathBuf {
    cwd.join(".devinorium").join("plugins")
}

/// `~/.config/devinorium/plugins.json` - `{ "disabled": ["name", ...] }`.
fn state_file(home: &Path) -> PathBuf {
    home.join(".config").join("devinorium").join("plugins.json")
}

/// Plugin name rules: same charset as MCP server names so plugin command
/// and tool namespaces stay typable.
pub fn valid_plugin_name(name: &str) -> bool {
    crate::mcp::valid_name(name)
}

/// Read a file inside a plugin dir with the usual guards: never follows a
/// symlink at the file itself, regular file only, size-bounded.
async fn read_plugin_file(dir: &Path, rel: &str) -> Option<String> {
    let path = dir.join(rel);
    let meta = tokio::fs::symlink_metadata(&path).await.ok()?;
    if meta.file_type().is_symlink() || !meta.is_file() || meta.len() > 256 * 1024 {
        return None;
    }
    tokio::fs::read_to_string(&path).await.ok()
}

async fn read_manifest(dir: &Path) -> PluginManifest {
    for rel in [".claude-plugin/plugin.json", "plugin.json"] {
        if let Some(text) = read_plugin_file(dir, rel).await {
            if let Ok(m) = serde_json::from_str::<PluginManifest>(&text) {
                return m;
            }
        }
    }
    PluginManifest::default()
}

fn author_string(author: &serde_json::Value) -> String {
    match author {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Object(map) => map
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        _ => String::new(),
    }
}

/// Names currently disabled in the state file.
async fn disabled_names(home: &Path) -> HashSet<String> {
    let Ok(text) = tokio::fs::read_to_string(state_file(home)).await else {
        return HashSet::new();
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
        return HashSet::new();
    };
    v.get("disabled")
        .and_then(|d| d.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|e| e.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

async fn save_disabled_names(home: &Path, disabled: &HashSet<String>) -> std::io::Result<()> {
    let file = state_file(home);
    if let Some(parent) = file.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let mut names: Vec<&String> = disabled.iter().collect();
    names.sort();
    let body = serde_json::to_string_pretty(&serde_json::json!({ "disabled": names }))?;
    let tmp = file.with_extension("json.tmp");
    tokio::fs::write(&tmp, body).await?;
    tokio::fs::rename(&tmp, &file).await
}

/// Scan one plugins root. Each entry must be a directory. A symlinked
/// entry is allowed in the user root - the owner put it there - but not
/// in a project root, where a cloned repo could point it anywhere.
async fn scan_root(root: &Path, source: PluginSource, disabled: &HashSet<String>) -> Vec<Plugin> {
    let mut out = Vec::new();
    let mut entries = match tokio::fs::read_dir(root).await {
        Ok(e) => e,
        Err(_) => return out,
    };
    let mut names = Vec::new();
    while let Ok(Some(entry)) = entries.next_entry().await {
        names.push(entry.path());
    }
    names.sort();
    for entry in names {
        let is_link = tokio::fs::symlink_metadata(&entry)
            .await
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(true);
        if is_link && source == PluginSource::Project {
            continue;
        }
        // Resolve the entry so symlink installs scan their real contents.
        let dir = match tokio::fs::canonicalize(&entry).await {
            Ok(d) => d,
            Err(_) => continue,
        };
        match tokio::fs::metadata(&dir).await {
            Ok(m) if m.is_dir() => {}
            _ => continue,
        }
        let manifest = read_manifest(&dir).await;
        let dir_name = entry
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let name = {
            let n = manifest.name.trim();
            if n.is_empty() {
                dir_name
            } else {
                n.to_string()
            }
        };
        if name.is_empty() {
            continue;
        }
        let install = if is_link {
            InstallKind::Link
        } else if tokio::fs::try_exists(dir.join(".git"))
            .await
            .unwrap_or(false)
        {
            InstallKind::Git
        } else {
            InstallKind::Dir
        };
        out.push(Plugin {
            dir,
            entry: Some(entry),
            name: name.clone(),
            version: manifest.version.trim().to_string(),
            description: manifest.description.trim().to_string(),
            author: author_string(&manifest.author),
            source,
            enabled: !disabled.contains(&name),
            install,
        });
    }
    out
}

/// All plugins visible to a thread: project-scope first so its skills and
/// commands win the first-hit dedup, then user-scope.
pub async fn discover_plugins(cwd: Option<&Path>, home: &Path) -> Vec<Plugin> {
    let disabled = disabled_names(home).await;
    let mut out = Vec::new();
    if let Some(cwd) = cwd {
        // The disabled list names user plugins only; project plugins are
        // not toggleable and must not inherit a user plugin's state.
        out.extend(
            scan_root(
                &project_plugins_root(cwd),
                PluginSource::Project,
                &HashSet::new(),
            )
            .await,
        );
    }
    out.extend(scan_root(&plugins_root(home), PluginSource::User, &disabled).await);
    out
}

/// A `skills/` or `commands/` file a plugin contributes to the `/` picker.
#[derive(Debug, Clone)]
pub struct ContributedFile {
    /// Fallback invocation name: the skill dir name or command file stem.
    pub fallback_name: String,
    pub path: PathBuf,
    /// `commands/*.md` files are commands; `skills/*/SKILL.md` are skills.
    /// Both behave identically at invocation; the flag only labels them.
    pub is_command: bool,
}

/// A `skills`/`commands` dir that is itself a symlink must not be
/// followed; entries inside still get their own symlink checks below.
async fn real_dir(dir: &Path) -> bool {
    tokio::fs::symlink_metadata(dir)
        .await
        .map(|m| m.is_dir() && !m.file_type().is_symlink())
        .unwrap_or(false)
}

/// The files a plugin contributes to the `/` picker:
/// `skills/<name>/SKILL.md` and `commands/<name>.md`.
pub async fn skill_files(plugin: &Plugin) -> Vec<ContributedFile> {
    let mut out = Vec::new();
    let skills_dir = plugin.dir.join("skills");
    if real_dir(&skills_dir).await {
        let mut entries = match tokio::fs::read_dir(&skills_dir).await {
            Ok(e) => e,
            Err(_) => return Vec::new(),
        };
        let mut dirs = Vec::new();
        while let Ok(Some(e)) = entries.next_entry().await {
            // A symlinked skill dir would let the picker read outside the
            // plugin; file_type does not follow the link.
            if e.file_type().await.map(|t| t.is_symlink()).unwrap_or(true) {
                continue;
            }
            dirs.push(e.file_name());
        }
        dirs.sort();
        for name in dirs {
            let Some(name) = name.to_str() else { continue };
            out.push(ContributedFile {
                fallback_name: name.to_string(),
                path: skills_dir.join(name).join("SKILL.md"),
                is_command: false,
            });
        }
    }
    let commands_dir = plugin.dir.join("commands");
    if let Some(mut entries) = match real_dir(&commands_dir).await {
        true => tokio::fs::read_dir(&commands_dir).await.ok(),
        false => None,
    } {
        let mut files = Vec::new();
        while let Ok(Some(e)) = entries.next_entry().await {
            if e.file_type().await.map(|t| t.is_symlink()).unwrap_or(true) {
                continue;
            }
            files.push(e.file_name());
        }
        files.sort();
        for name in files {
            let path = commands_dir.join(&name);
            let Some(stem) = name.to_str().and_then(|n| n.strip_suffix(".md")) else {
                continue;
            };
            out.push(ContributedFile {
                fallback_name: stem.to_string(),
                path,
                is_command: true,
            });
        }
    }
    out
}

/// One MCP server entry inside `.mcp.json`'s `mcpServers` map. Mirrors the
/// Claude Code shape: `type`/`transport` picks `stdio`, `http` or `sse`,
/// a `url` with no type implies `http`.
fn parse_mcp_entry(name: &str, v: &serde_json::Value) -> Option<McpServerConfig> {
    let obj = v.as_object()?;
    let str_field = |key: &str| obj.get(key).and_then(|v| v.as_str()).unwrap_or("");
    let str_map = |key: &str| -> BTreeMap<String, String> {
        obj.get(key)
            .and_then(|v| v.as_object())
            .map(|m| {
                m.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default()
    };
    let transport = match str_field("type") {
        "" => str_field("transport").to_string(),
        t => t.to_string(),
    };
    let transport = if transport.is_empty() {
        if str_field("url").is_empty() {
            "stdio"
        } else {
            "http"
        }
    } else {
        transport.as_str()
    };
    let server = McpServerConfig {
        name: name.to_string(),
        enabled: obj.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true),
        transport: transport.to_string(),
        command: str_field("command").to_string(),
        args: obj
            .get("args")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default(),
        env: str_map("env"),
        url: str_field("url").to_string(),
        headers: str_map("headers"),
    };
    crate::mcp::validate_server(&server).ok()?;
    Some(server)
}

/// MCP servers one plugin declares in `.mcp.json`.
async fn plugin_mcp_servers(plugin: &Plugin) -> Vec<McpServerConfig> {
    let Some(text) = read_plugin_file(&plugin.dir, ".mcp.json").await else {
        return Vec::new();
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
        tracing::warn!(plugin = %plugin.name, "ignoring unparseable .mcp.json");
        return Vec::new();
    };
    let Some(servers) = v.get("mcpServers").and_then(|s| s.as_object()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for (name, entry) in servers {
        match parse_mcp_entry(name, entry) {
            Some(s) => out.push(s),
            None => tracing::warn!(
                plugin = %plugin.name,
                server = %name,
                "skipping invalid plugin MCP server entry"
            ),
        }
    }
    out
}

/// Plugin MCP servers merged into `servers`: enabled user-scope plugins
/// only, and an existing name always wins so the owner's list stays
/// authoritative.
pub async fn merge_plugin_mcp(home: &Path, servers: &mut Vec<McpServerConfig>) {
    for plugin in discover_plugins(None, home).await {
        if plugin.source != PluginSource::User || !plugin.enabled {
            continue;
        }
        for server in plugin_mcp_servers(&plugin).await {
            if server.enabled && !servers.iter().any(|s| s.name == server.name) {
                servers.push(server);
            }
        }
    }
}

/// One shell command a plugin runs on an event.
#[derive(Debug, Clone)]
pub struct HookCommand {
    pub plugin: String,
    pub plugin_root: PathBuf,
    pub command: String,
    pub timeout: Duration,
}

/// Commands registered for `event` across enabled user-scope plugins, in
/// install order.
pub async fn hooks_for(home: &Path, event: &str) -> Vec<HookCommand> {
    let mut out = Vec::new();
    for plugin in discover_plugins(None, home).await {
        if plugin.source != PluginSource::User || !plugin.enabled {
            continue;
        }
        let Some(text) = read_plugin_file(&plugin.dir, "hooks/hooks.json").await else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
            tracing::warn!(plugin = %plugin.name, "ignoring unparseable hooks.json");
            continue;
        };
        // Claude Code wraps the event map in a top-level "hooks" object;
        // accept the bare map too so a hand-written file still loads.
        let events = v.get("hooks").unwrap_or(&v);
        let Some(list) = events.get(event).and_then(|e| e.as_array()) else {
            continue;
        };
        for group in list {
            let Some(cmds) = group.get("hooks").and_then(|h| h.as_array()) else {
                continue;
            };
            for cmd in cmds {
                let kind = cmd
                    .get("type")
                    .and_then(|t| t.as_str())
                    .unwrap_or("command");
                if kind != "command" {
                    continue;
                }
                let Some(command) = cmd.get("command").and_then(|c| c.as_str()) else {
                    continue;
                };
                let timeout = cmd
                    .get("timeout")
                    .and_then(|t| t.as_u64())
                    .map(Duration::from_secs)
                    .unwrap_or(DEFAULT_HOOK_TIMEOUT)
                    .min(MAX_HOOK_TIMEOUT);
                out.push(HookCommand {
                    plugin: plugin.name.clone(),
                    plugin_root: plugin.dir.clone(),
                    command: command.to_string(),
                    timeout,
                });
            }
        }
    }
    out
}

/// What one hook invocation decided.
struct HookReply {
    /// Reason the event is blocked, when the hook blocked it.
    block: Option<String>,
    /// Text appended to the prompt as additional context.
    context: String,
}

/// Kills a hook's process group on drop unless disarmed, covering paths the
/// timeout never sees: an aborted send, a dropped future, an early return.
#[cfg(unix)]
struct HookProcessGroup(Option<rustix::process::Pid>);

#[cfg(unix)]
impl HookProcessGroup {
    fn new(child: &tokio::process::Child) -> Self {
        Self(
            child
                .id()
                .and_then(|i| i32::try_from(i).ok())
                .and_then(rustix::process::Pid::from_raw),
        )
    }

    fn disarm(&mut self) {
        self.0 = None;
    }
}

#[cfg(unix)]
impl Drop for HookProcessGroup {
    fn drop(&mut self) {
        if let Some(pid) = self.0 {
            let _ = rustix::process::kill_process_group(pid, rustix::process::Signal::KILL);
        }
    }
}

async fn run_one_hook(hook: &HookCommand, event: &str, cwd: &Path, payload: &[u8]) -> HookReply {
    let shell = if cfg!(windows) { "cmd" } else { "sh" };
    let flag = if cfg!(windows) { "/C" } else { "-c" };
    let mut cmd = tokio::process::Command::new(shell);
    cmd.arg(flag)
        .arg(&hook.command)
        .current_dir(cwd)
        // Roots reach the command through the environment only; splicing
        // them into the command text would re-parse cwd as shell syntax.
        .env("DEVINORIUM_PLUGIN_ROOT", &hook.plugin_root)
        .env("CLAUDE_PLUGIN_ROOT", &hook.plugin_root)
        .env("DEVINORIUM_PROJECT_DIR", cwd)
        .env("CLAUDE_PROJECT_DIR", cwd)
        .env("DEVINORIUM_PLUGIN_NAME", &hook.plugin)
        .env("DEVINORIUM_HOOK_EVENT", event)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    // A fresh process group so a timed-out hook takes its whole pipeline
    // down, not just the `sh` wrapper.
    #[cfg(unix)]
    cmd.process_group(0);
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(plugin = %hook.plugin, error = %e, "failed to spawn plugin hook");
            return HookReply {
                block: None,
                context: String::new(),
            };
        }
    };
    // Dropping the guard (cancel, panic, early return) kills the whole
    // process group so an abandoned hook cannot orphan its pipeline.
    #[cfg(unix)]
    let mut group_kill = HookProcessGroup::new(&child);
    let capped = tokio::time::timeout(hook.timeout, async {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let mut out_pipe = child.stdout.take().unwrap().take(MAX_HOOK_OUTPUT as u64);
        let mut err_pipe = child.stderr.take().unwrap().take(MAX_HOOK_OUTPUT as u64);
        // The payload write runs concurrently with the output drain and
        // under the timeout: a payload past the pipe buffer would deadlock
        // a hook that writes before reading stdin, and one that never
        // reads would hang the run forever without the cap.
        let stdin = child.stdin.take();
        let (out_res, err_res, status, ()) = tokio::join!(
            async {
                let mut b = Vec::new();
                out_pipe.read_to_end(&mut b).await.map(|_| b)
            },
            async {
                let mut b = Vec::new();
                err_pipe.read_to_end(&mut b).await.map(|_| b)
            },
            child.wait(),
            async {
                if let Some(mut stdin) = stdin {
                    let _ = stdin.write_all(payload).await;
                    // Dropping stdin signals EOF so the hook can finish
                    // reading.
                }
            },
        );
        (out_res, err_res, status)
    })
    .await;
    let (out_res, err_res, status) = match capped {
        Ok(v) => {
            // The child already exited; a stale group kill could hit a
            // recycled process group.
            #[cfg(unix)]
            group_kill.disarm();
            v
        }
        Err(_) => {
            // The guard's Drop sends the process-group kill; `kill` takes
            // care of the wrapper itself.
            let _ = child.kill().await;
            tracing::warn!(plugin = %hook.plugin, event, "plugin hook timed out");
            return HookReply {
                block: None,
                context: String::new(),
            };
        }
    };
    let stdout = String::from_utf8_lossy(&out_res.unwrap_or_default()).to_string();
    let stderr = String::from_utf8_lossy(&err_res.unwrap_or_default()).to_string();
    let code = status.ok().and_then(|s| s.code()).unwrap_or(-1);
    match code {
        // Exit 2 blocks the event; stderr carries the reason.
        2 => HookReply {
            block: Some(if stderr.trim().is_empty() {
                format!("blocked by {} hook", hook.plugin)
            } else {
                stderr.trim().to_string()
            }),
            context: String::new(),
        },
        0 => {
            let out = stdout.trim();
            if out.is_empty() {
                return HookReply {
                    block: None,
                    context: String::new(),
                };
            }
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(out) {
                if v.get("decision").and_then(|d| d.as_str()) == Some("block") {
                    let reason = v
                        .get("reason")
                        .and_then(|r| r.as_str())
                        .unwrap_or("blocked by plugin hook")
                        .to_string();
                    return HookReply {
                        block: Some(reason),
                        context: String::new(),
                    };
                }
                let ctx = v
                    .get("hookSpecificOutput")
                    .and_then(|h| h.get("additionalContext"))
                    .or_else(|| v.get("additionalContext"))
                    .and_then(|c| c.as_str())
                    .unwrap_or_default()
                    .to_string();
                return HookReply {
                    block: None,
                    context: ctx,
                };
            }
            // Plain stdout on a submit/start event is context, like Claude
            // Code treats it.
            HookReply {
                block: None,
                context: out.to_string(),
            }
        }
        _ => {
            tracing::warn!(
                plugin = %hook.plugin,
                event,
                code,
                stderr = %stderr.trim(),
                "plugin hook failed"
            );
            HookReply {
                block: None,
                context: String::new(),
            }
        }
    }
}

/// The combined outcome of running every hook for an event.
pub struct HookOutcome {
    /// `Some(reason)` when a hook blocked the event.
    pub block: Option<String>,
    /// Concatenated additional context to append to the prompt.
    pub context: String,
}

/// Run every enabled user-scope hook for `event` in order. Hooks are
/// best-effort: timeouts and crashes are logged and skipped, only an
/// explicit block stops the event.
pub async fn run_hooks(
    home: &Path,
    event: &str,
    cwd: &Path,
    mut payload: serde_json::Value,
) -> HookOutcome {
    payload["hook_event_name"] = serde_json::Value::String(event.to_string());
    payload["cwd"] = serde_json::Value::String(cwd.to_string_lossy().to_string());
    let bytes = serde_json::to_vec(&payload).unwrap_or_else(|_| b"{}".to_vec());
    let mut out = HookOutcome {
        block: None,
        context: String::new(),
    };
    for hook in hooks_for(home, event).await {
        let reply = run_one_hook(&hook, event, cwd, &bytes).await;
        if let Some(reason) = reply.block {
            out.block = Some(reason);
            return out;
        }
        if !reply.context.is_empty() {
            if !out.context.is_empty() {
                out.context.push_str("\n\n");
            }
            out.context.push_str(&reply.context);
        }
    }
    out
}

/// Append hook context to a prompt body; no-op when the context is empty.
pub fn append_context(prompt: &mut String, context: &str) {
    if context.is_empty() {
        return;
    }
    if !prompt.trim().is_empty() {
        prompt.push_str("\n\n");
    }
    prompt.push_str(context);
}

/// Whether a directory looks like a plugin: a manifest or at least one
/// recognized content directory/file.
fn looks_like_plugin(dir: &Path) -> bool {
    dir.join(".claude-plugin/plugin.json").is_file()
        || dir.join("plugin.json").is_file()
        || dir.join("skills").is_dir()
        || dir.join("commands").is_dir()
        || dir.join("agents").is_dir()
        || dir.join("hooks/hooks.json").is_file()
        || dir.join(".mcp.json").is_file()
}

/// `.claude-plugin/marketplace.json` - a repo of plugins.
#[derive(Debug, Deserialize)]
struct MarketplaceFile {
    #[serde(default)]
    name: String,
    #[serde(default)]
    plugins: Vec<MarketplaceEntry>,
}

#[derive(Debug, Deserialize)]
struct MarketplaceEntry {
    #[serde(default)]
    name: String,
    source: String,
}

fn looks_like_marketplace(dir: &Path) -> bool {
    dir.join(".claude-plugin/marketplace.json").is_file()
}

async fn read_marketplace(dir: &Path) -> Result<MarketplaceFile, String> {
    let text = tokio::fs::read_to_string(dir.join(".claude-plugin/marketplace.json"))
        .await
        .map_err(|e| format!("cannot read marketplace.json: {e}"))?;
    serde_json::from_str::<MarketplaceFile>(&text)
        .map_err(|e| format!("invalid marketplace.json: {e}"))
}

/// Read a plugin name for `dir` without a full scan: manifest name first,
/// directory name as fallback.
async fn plugin_name_for(dir: &Path) -> String {
    let m = read_manifest(dir).await;
    let name = m.name.trim().to_string();
    if !name.is_empty() {
        return name;
    }
    dir.file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default()
}

/// Recursively copy a directory (blocking; run inside `spawn_blocking`).
/// Only the Windows symlink fallback uses it.
#[cfg(windows)]
fn copy_dir(src: &Path, dst: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let target = dst.join(entry.file_name());
        let ft = entry.file_type()?;
        if ft.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else if ft.is_file() {
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

/// Place `src` at `plugins/<name>`: symlink when the source is managed
/// externally (a local path or marketplace clone elsewhere), move when the
/// source is the temp clone itself.
async fn place_plugin(src: &Path, dest: &Path, link: bool) -> Result<(), String> {
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("cannot create plugins dir: {e}"))?;
    }
    if link {
        #[cfg(unix)]
        {
            return tokio::fs::symlink(src, dest)
                .await
                .map_err(|e| format!("cannot link plugin: {e}"));
        }
        #[cfg(windows)]
        {
            match tokio::fs::symlink_dir(src, dest).await {
                Ok(()) => return Ok(()),
                Err(_) => {
                    // Windows symlink creation needs privileges; fall back
                    // to a copy so local installs still work there.
                    let src = src.to_path_buf();
                    let dest = dest.to_path_buf();
                    return tokio::task::spawn_blocking(move || copy_dir(&src, &dest))
                        .await
                        .map_err(|e| format!("copy failed: {e}"))?
                        .map_err(|e| format!("cannot copy plugin: {e}"));
                }
            }
        }
    }
    tokio::fs::rename(src, dest)
        .await
        .map_err(|e| format!("cannot move plugin into place: {e}"))
}

/// Detect whether `source` is a git URL rather than a filesystem path.
fn is_git_source(source: &str) -> bool {
    source.starts_with("http://")
        || source.starts_with("https://")
        || source.starts_with("git@")
        || source.starts_with("ssh://")
        || source.starts_with("git://")
}

/// Install plugin(s) from `source` - a git URL or a local directory -
/// into the user plugins root. A repo/dir containing
/// `.claude-plugin/marketplace.json` installs each listed plugin.
/// Returns the installed plugin names.
pub async fn install(home: &Path, source: &str) -> Result<Vec<String>, String> {
    let source = source.trim();
    if source.is_empty() {
        return Err("a git URL or directory path is required".into());
    }
    let root = plugins_root(home);
    let mut tmp: Option<tempfile::TempDir> = None;
    let dir = if is_git_source(source) {
        // Reject a dash-leading host: old git passes it to ssh as an
        // option (e.g. `-oProxyCommand=...`).
        let host = source.rsplit('@').next().unwrap_or(source);
        let host = host.rsplit("://").next().unwrap_or(host);
        if host.starts_with('-') {
            return Err("invalid git URL".into());
        }
        let git = crate::git::GitService::new()
            .binary()
            .ok_or("git is not installed on this server")?
            .to_path_buf();
        // Stage inside the config dir so the rename into the plugins root
        // never crosses filesystems.
        let config_root = home.join(".config").join("devinorium");
        tokio::fs::create_dir_all(&config_root)
            .await
            .map_err(|e| format!("cannot create config dir: {e}"))?;
        let t = tempfile::Builder::new()
            .prefix(".plugin-staging-")
            .tempdir_in(&config_root)
            .map_err(|e| format!("cannot create temp dir: {e}"))?;
        let dest = t.path().join("repo");
        let out = tokio::process::Command::new(git)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GCM_INTERACTIVE", "never")
            .arg("clone")
            .arg("--depth")
            .arg("1")
            .arg("--")
            .arg(source)
            .arg(&dest)
            .output()
            .await
            .map_err(|e| format!("cannot run git: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "git clone failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        tmp = Some(t);
        dest
    } else {
        let normalized = crate::security::paths::normalize_path(source, home);
        let p = PathBuf::from(&normalized);
        if !p.is_absolute() {
            return Err("path must be absolute".into());
        }
        for c in p.components() {
            if matches!(c, std::path::Component::ParentDir) {
                return Err("path traversal is not allowed".into());
            }
        }
        let canon = tokio::fs::canonicalize(&p)
            .await
            .map_err(|e| format!("cannot read path: {e}"))?;
        match tokio::fs::metadata(&canon).await {
            Ok(m) if m.is_dir() => canon,
            _ => return Err("path is not a directory".into()),
        }
    };
    let from_clone = tmp.is_some();

    let mut installed = Vec::new();
    if looks_like_marketplace(&dir) {
        let market = read_marketplace(&dir).await?;
        if market.plugins.is_empty() {
            return Err("marketplace lists no plugins".into());
        }
        // A cloned marketplace moves wholesale into the marketplaces root
        // so updates pull the whole repo; a local path stays put.
        let base = if from_clone {
            let mkt_name = {
                let n = market.name.trim();
                if n.is_empty() {
                    dir.parent()
                        .and_then(|p| p.file_name())
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_else(|| "marketplace".into())
                } else {
                    n.to_string()
                }
            };
            if !valid_plugin_name(&mkt_name) {
                return Err(format!("invalid marketplace name {mkt_name:?}"));
            }
            let target = marketplaces_root(home).join(&mkt_name);
            if tokio::fs::try_exists(&target).await.unwrap_or(false) {
                return Err(format!("marketplace {mkt_name:?} is already installed"));
            }
            place_plugin(&dir, &target, false).await?;
            target
        } else {
            dir.clone()
        };
        for entry in &market.plugins {
            let rel = entry.source.trim();
            if !rel.starts_with("./") && !rel.starts_with(".\\") {
                return Err(format!(
                    "marketplace plugin source {rel:?} is not a local directory"
                ));
            }
            let plug_dir = match crate::security::paths::resolve_within(
                Path::new(rel),
                Some(&base),
                std::slice::from_ref(&base),
            ) {
                Some(p) if p.is_dir() => p,
                _ => return Err(format!("marketplace plugin source {rel:?} does not exist")),
            };
            if !looks_like_plugin(&plug_dir) {
                return Err(format!("{rel:?} does not look like a plugin"));
            }
            let name = {
                let n = entry.name.trim();
                let resolved = if n.is_empty() {
                    plugin_name_for(&plug_dir).await
                } else {
                    n.to_string()
                };
                if !valid_plugin_name(&resolved) {
                    return Err(format!("invalid plugin name {resolved:?}"));
                }
                resolved
            };
            let dest = root.join(&name);
            if tokio::fs::try_exists(&dest).await.unwrap_or(false)
                || tokio::fs::symlink_metadata(&dest).await.is_ok()
            {
                return Err(format!("plugin {name:?} is already installed"));
            }
            place_plugin(&plug_dir, &dest, true).await?;
            installed.push(name);
        }
    } else {
        if !looks_like_plugin(&dir) {
            return Err(
                "not a plugin: expected plugin.json, skills/, commands/, hooks/ or .mcp.json"
                    .into(),
            );
        }
        let name = {
            let n = plugin_name_for(&dir).await;
            if !valid_plugin_name(&n) {
                return Err(format!("invalid plugin name {n:?}"));
            }
            n
        };
        let dest = root.join(&name);
        if tokio::fs::try_exists(&dest).await.unwrap_or(false)
            || tokio::fs::symlink_metadata(&dest).await.is_ok()
        {
            return Err(format!("plugin {name:?} is already installed"));
        }
        // A git clone moves into the root so its .git stays updatable; a
        // local path is linked so edits apply immediately.
        place_plugin(&dir, &dest, !from_clone).await?;
        installed.push(name);
    }
    // Keep the temp clone alive until renames above have moved its contents.
    drop(tmp);
    Ok(installed)
}

/// Remove a user-scope plugin by name: the entry (dir or symlink) under
/// the plugins root, plus a marketplace clone it was the last link into.
pub async fn uninstall(home: &Path, name: &str) -> Result<(), String> {
    let root = plugins_root(home);
    let plugin = discover_plugins(None, home)
        .await
        .into_iter()
        .find(|p| p.source == PluginSource::User && p.name == name)
        .ok_or_else(|| format!("no installed plugin named {name:?}"))?;
    let Some(entry) = plugin.entry else {
        return Err("plugin has no managed entry".into());
    };
    if !crate::security::paths::is_within(&entry, &root) {
        return Err("plugin entry is outside the plugins root".into());
    }
    let meta = tokio::fs::symlink_metadata(&entry)
        .await
        .map_err(|e| format!("cannot stat plugin: {e}"))?;
    if meta.file_type().is_symlink() {
        tokio::fs::remove_file(&entry)
            .await
            .map_err(|e| format!("cannot remove plugin link: {e}"))?;
        // If this was the last link into a managed marketplace clone,
        // drop the whole clone (its first component under marketplaces/).
        let mkt_root = tokio::fs::canonicalize(&marketplaces_root(home))
            .await
            .unwrap_or_else(|_| marketplaces_root(home));
        if crate::security::paths::is_within(&plugin.dir, &mkt_root) {
            let clone_root = plugin
                .dir
                .strip_prefix(&mkt_root)
                .ok()
                .and_then(|rel| rel.components().next())
                .map(|c| mkt_root.join(c));
            if let Some(clone_root) = clone_root {
                let still_used = scan_root(&root, PluginSource::User, &HashSet::new())
                    .await
                    .iter()
                    .any(|p| crate::security::paths::is_within(&p.dir, &clone_root));
                if !still_used {
                    let _ = tokio::fs::remove_dir_all(&clone_root).await;
                }
            }
        }
    } else {
        tokio::fs::remove_dir_all(&entry)
            .await
            .map_err(|e| format!("cannot remove plugin: {e}"))?;
    }
    Ok(())
}

/// Serializes read-modify-write cycles on the plugin state file so two
/// concurrent toggles cannot lose one another's update.
static PLUGIN_STATE_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Toggle a user-scope plugin via the state file's `disabled` list.
pub async fn set_enabled(home: &Path, name: &str, enabled: bool) -> Result<(), String> {
    let exists = discover_plugins(None, home)
        .await
        .iter()
        .any(|p| p.source == PluginSource::User && p.name == name);
    if !exists {
        return Err(format!("no installed plugin named {name:?}"));
    }
    let _guard = PLUGIN_STATE_LOCK.lock().await;
    let mut disabled = disabled_names(home).await;
    if enabled {
        disabled.remove(name);
    } else {
        disabled.insert(name.to_string());
    }
    save_disabled_names(home, &disabled)
        .await
        .map_err(|e| format!("cannot save plugin state: {e}"))
}

/// `git pull --ff-only` the repo behind a git-installed plugin. The
/// canonical dir must stay under `~/.config/devinorium` so a linked local
/// checkout is never mutated from the API.
pub async fn update(home: &Path, name: &str) -> Result<String, String> {
    let plugin = discover_plugins(None, home)
        .await
        .into_iter()
        .find(|p| p.source == PluginSource::User && p.name == name)
        .ok_or_else(|| format!("no installed plugin named {name:?}"))?;
    // plugin.dir is canonicalized; the root must be too or is_within
    // rejects valid installs on hosts where $HOME contains a symlink.
    let raw_root = home.join(".config").join("devinorium");
    let config_root = tokio::fs::canonicalize(&raw_root).await.unwrap_or(raw_root);
    if !crate::security::paths::is_within(&plugin.dir, &config_root) {
        return Err("only server-installed git plugins can be updated".into());
    }
    // Find the repo root: the plugin dir or an ancestor inside the config
    // root (marketplace plugins live in a subdirectory of the clone).
    let mut repo = plugin.dir.clone();
    loop {
        if tokio::fs::try_exists(repo.join(".git"))
            .await
            .unwrap_or(false)
        {
            break;
        }
        if !crate::security::paths::is_within(&repo, &config_root) || !repo.pop() {
            return Err("plugin is not a git install".into());
        }
    }
    let git = crate::git::GitService::new()
        .binary()
        .ok_or("git is not installed on this server")?
        .to_path_buf();
    let out = tokio::process::Command::new(git)
        .env("GIT_TERMINAL_PROMPT", "0")
        .current_dir(&repo)
        .arg("pull")
        .arg("--ff-only")
        .output()
        .await
        .map_err(|e| format!("cannot run git: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "git pull failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// What a plugin contributes, for the API and settings page.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginInfo {
    pub name: String,
    pub version: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub description: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub author: String,
    pub enabled: bool,
    /// `user` or `project`.
    pub source: String,
    /// `dir`, `git` or `link`; project plugins are always `project`.
    pub install: String,
    pub path: String,
    /// True when the API can toggle/update/remove it (user scope).
    pub manageable: bool,
    pub skills: Vec<String>,
    pub commands: Vec<String>,
    pub mcp_servers: Vec<String>,
    pub hooks: Vec<String>,
}

/// Build the API-facing info for one discovered plugin: manifest fields
/// plus the names of everything it contributes.
pub async fn plugin_info(plugin: &Plugin) -> PluginInfo {
    let mut skills = Vec::new();
    let mut commands = Vec::new();
    for file in skill_files(plugin).await {
        if file.is_command {
            commands.push(file.fallback_name);
        } else {
            skills.push(file.fallback_name);
        }
    }
    let mcp_servers = if plugin.source == PluginSource::User {
        plugin_mcp_servers(plugin)
            .await
            .iter()
            .map(|s| s.name.clone())
            .collect()
    } else {
        Vec::new()
    };
    let hooks: Vec<String> = if plugin.source == PluginSource::User {
        match read_plugin_file(&plugin.dir, "hooks/hooks.json").await {
            Some(text) => match serde_json::from_str::<serde_json::Value>(&text) {
                Ok(v) => {
                    let events = v.get("hooks").unwrap_or(&v);
                    events
                        .as_object()
                        .map(|m| m.keys().cloned().collect())
                        .unwrap_or_default()
                }
                Err(_) => Vec::new(),
            },
            None => Vec::new(),
        }
    } else {
        Vec::new()
    };
    let manageable = plugin.source == PluginSource::User;
    PluginInfo {
        name: plugin.name.clone(),
        version: plugin.version.clone(),
        description: plugin.description.clone(),
        author: plugin.author.clone(),
        enabled: plugin.enabled,
        source: match plugin.source {
            PluginSource::User => "user",
            PluginSource::Project => "project",
        }
        .to_string(),
        install: match plugin.install {
            InstallKind::Dir => "dir",
            InstallKind::Git => "git",
            InstallKind::Link => "link",
        }
        .to_string(),
        path: plugin.dir.to_string_lossy().to_string(),
        manageable,
        skills,
        commands,
        mcp_servers,
        hooks,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(root: &Path, rel: &str, content: &str) {
        let path = root.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, content).unwrap();
    }

    const MANIFEST: &str = r#"{"name":"demo","version":"1.2.3","description":"a demo plugin","author":{"name":"Ada"}}"#;

    fn user_plugin(home: &Path) {
        let root = plugins_root(home).join("demo");
        write(&root, ".claude-plugin/plugin.json", MANIFEST);
        write(
            &root,
            "skills/review/SKILL.md",
            "---\nname: review\ndescription: Review it\n---\nreview body\n",
        );
        write(
            &root,
            "commands/gen.md",
            "---\ndescription: Gen\n---\ngen $ARGUMENTS\n",
        );
    }

    #[tokio::test]
    async fn discover_reads_manifest_and_scopes() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let cwd = tmp.path().join("proj");
        user_plugin(&home);
        write(
            &cwd,
            ".devinorium/plugins/local/plugin.json",
            r#"{"name":"local"}"#,
        );
        let plugins = discover_plugins(Some(&cwd), &home).await;
        assert_eq!(plugins.len(), 2);
        let local = plugins.iter().find(|p| p.name == "local").unwrap();
        assert_eq!(local.source, PluginSource::Project);
        let demo = plugins.iter().find(|p| p.name == "demo").unwrap();
        assert_eq!(demo.source, PluginSource::User);
        assert_eq!(demo.version, "1.2.3");
        assert_eq!(demo.description, "a demo plugin");
        assert_eq!(demo.author, "Ada");
        assert!(demo.enabled);
    }

    #[tokio::test]
    async fn concurrent_toggles_do_not_lose_updates() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        user_plugin(&home);
        write(
            &plugins_root(&home).join("other"),
            ".claude-plugin/plugin.json",
            r#"{"name":"other"}"#,
        );
        let (a, b) = tokio::join!(
            set_enabled(&home, "demo", false),
            set_enabled(&home, "other", false),
        );
        a.unwrap();
        b.unwrap();
        let disabled = disabled_names(&home).await;
        assert!(disabled.contains("demo") && disabled.contains("other"));
    }

    #[tokio::test]
    async fn disabled_list_marks_plugin_disabled() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        user_plugin(&home);
        std::fs::create_dir_all(home.join(".config/devinorium")).unwrap();
        std::fs::write(state_file(&home), r#"{"disabled":["demo"]}"#).unwrap();
        let plugins = discover_plugins(None, &home).await;
        assert_eq!(plugins.len(), 1);
        assert!(!plugins[0].enabled);
    }

    #[tokio::test]
    async fn skill_files_lists_skills_and_commands() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        user_plugin(&home);
        let plugins = discover_plugins(None, &home).await;
        let files = skill_files(&plugins[0]).await;
        assert_eq!(files.len(), 2);
        let skill = files.iter().find(|f| !f.is_command).unwrap();
        assert_eq!(skill.fallback_name, "review");
        assert!(skill.path.ends_with("SKILL.md"));
        let cmd = files.iter().find(|f| f.is_command).unwrap();
        assert_eq!(cmd.fallback_name, "gen");
    }

    #[tokio::test]
    async fn merge_plugin_mcp_adds_enabled_user_servers_only() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let cwd = tmp.path().join("proj");
        let root = plugins_root(&home).join("demo");
        write(&root, "plugin.json", r#"{"name":"demo"}"#);
        write(
            &root,
            ".mcp.json",
            r#"{"mcpServers":{"plug":{"command":"npx","args":["-y","plug"]},"remote":{"type":"sse","url":"https://x.example/sse"},"bad":{"command":""}}}"#,
        );
        // A project-scope plugin's servers must never merge.
        let proot = project_plugins_root(&cwd).join("projplug");
        write(&proot, "plugin.json", r#"{"name":"projplug"}"#);
        write(
            &proot,
            ".mcp.json",
            r#"{"mcpServers":{"sneaky":{"command":"rm"}}}"#,
        );
        let mut servers = vec![McpServerConfig {
            name: "plug".into(),
            enabled: true,
            transport: "stdio".into(),
            command: "mine".into(),
            args: vec![],
            env: BTreeMap::new(),
            url: String::new(),
            headers: BTreeMap::new(),
        }];
        merge_plugin_mcp(&home, &mut servers).await;
        // The user's own "plug" wins; only the plugin's "remote" is added.
        assert_eq!(servers.len(), 2);
        assert_eq!(servers[0].command, "mine");
        assert_eq!(servers[1].name, "remote");
        assert_eq!(servers[1].transport, "sse");
    }

    #[tokio::test]
    async fn hooks_for_parses_commands_and_timeouts() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let root = plugins_root(&home).join("demo");
        write(
            &root,
            "hooks/hooks.json",
            r#"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo hi","timeout":5},{"type":"command","command":"echo bye"}]},{"hooks":[{"type":"prompt","command":"skip"}]}],"Stop":[{"hooks":[{"command":"notify","timeout":500}]}]}}"#,
        );
        let hooks = hooks_for(&home, EVENT_PROMPT_SUBMIT).await;
        assert_eq!(hooks.len(), 2);
        assert_eq!(hooks[0].command, "echo hi");
        assert_eq!(hooks[0].timeout, Duration::from_secs(5));
        assert_eq!(hooks[1].timeout, DEFAULT_HOOK_TIMEOUT);
        let stops = hooks_for(&home, EVENT_STOP).await;
        assert_eq!(stops.len(), 1);
        // 500s exceeds the hard cap.
        assert_eq!(stops[0].timeout, MAX_HOOK_TIMEOUT);
        assert!(hooks_for(&home, EVENT_SESSION_START).await.is_empty());
    }

    #[tokio::test]
    async fn hooks_for_ignores_project_scope_and_disabled() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let cwd = tmp.path().join("proj");
        let proot = project_plugins_root(&cwd).join("projplug");
        write(&proot, "plugin.json", r#"{"name":"projplug"}"#);
        write(
            &proot,
            "hooks/hooks.json",
            r#"{"UserPromptSubmit":[{"hooks":[{"command":"never"}]}]}"#,
        );
        // hooks_for scans only the user root, whatever the cwd has.
        assert!(hooks_for(&home, EVENT_PROMPT_SUBMIT).await.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_hooks_blocks_and_appends_context() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let cwd = tmp.path().join("proj");
        std::fs::create_dir_all(&cwd).unwrap();
        let root = plugins_root(&home).join("ctx");
        write(
            &root,
            "hooks/hooks.json",
            r#"{"UserPromptSubmit":[{"hooks":[{"command":"printf 'more context'"}]}]}"#,
        );
        let root2 = plugins_root(&home).join("blocker");
        write(
            &root2,
            "hooks/hooks.json",
            r#"{"UserPromptSubmit":[{"hooks":[{"command":"echo 'reason here' >&2; exit 2"}]}]}"#,
        );
        // Alphabetical order: "blocker" runs first and stops the chain.
        let out = run_hooks(&home, EVENT_PROMPT_SUBMIT, &cwd, serde_json::json!({})).await;
        assert_eq!(out.block.as_deref(), Some("reason here"));

        let root3 = plugins_root(&home).join("zctx");
        std::fs::create_dir_all(&root3).unwrap();
        // Remove the blocker so the context hook gets to run.
        std::fs::remove_dir_all(&root2).unwrap();
        let out = run_hooks(&home, EVENT_PROMPT_SUBMIT, &cwd, serde_json::json!({})).await;
        assert!(out.block.is_none());
        assert_eq!(out.context, "more context");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_hooks_reads_json_replies_and_env() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let cwd = tmp.path().join("proj");
        std::fs::create_dir_all(&cwd).unwrap();
        let root = plugins_root(&home).join("demo");
        write(
            &root,
            "hooks/hooks.json",
            r#"{"UserPromptSubmit":[{"hooks":[{"command":"cat > \"$DEVINORIUM_PLUGIN_ROOT/in.json\"; printf '{\"hookSpecificOutput\":{\"additionalContext\":\"ctx\"}}'"}]}]}"#,
        );
        let out = run_hooks(
            &home,
            EVENT_PROMPT_SUBMIT,
            &cwd,
            serde_json::json!({"prompt": "hi", "session_id": "s1"}),
        )
        .await;
        assert_eq!(out.context, "ctx");
        let seen: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(root.join("in.json")).unwrap()).unwrap();
        assert_eq!(seen["hook_event_name"], "UserPromptSubmit");
        assert_eq!(seen["prompt"], "hi");
        assert_eq!(seen["session_id"], "s1");
        assert_eq!(seen["cwd"], cwd.to_string_lossy().to_string());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_hooks_expands_plugin_root_var() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let cwd = tmp.path().join("proj");
        std::fs::create_dir_all(&cwd).unwrap();
        let root = plugins_root(&home).join("demo");
        write(
            &root,
            "hooks/hooks.json",
            r#"{"UserPromptSubmit":[{"hooks":[{"command":"printf x > \"${CLAUDE_PLUGIN_ROOT}/wrote.txt\""}]}]}"#,
        );
        let out = run_hooks(&home, EVENT_PROMPT_SUBMIT, &cwd, serde_json::json!({})).await;
        assert!(out.block.is_none());
        assert_eq!(
            std::fs::read_to_string(root.join("wrote.txt")).unwrap(),
            "x"
        );
    }

    #[test]
    fn append_context_merges_into_prompt() {
        let mut p = "do it".to_string();
        append_context(&mut p, "");
        assert_eq!(p, "do it");
        append_context(&mut p, "ctx");
        assert_eq!(p, "do it\n\nctx");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn install_links_local_plugin_and_uninstalls() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let src = tmp.path().join("my-plugin");
        write(&src, ".claude-plugin/plugin.json", MANIFEST);
        write(&src, "commands/x.md", "---\ndescription: x\n---\nx body\n");

        let names = install(&home, &src.to_string_lossy()).await.unwrap();
        assert_eq!(names, ["demo"]);
        let entry = plugins_root(&home).join("demo");
        assert!(std::fs::symlink_metadata(&entry)
            .unwrap()
            .file_type()
            .is_symlink());
        let plugins = discover_plugins(None, &home).await;
        assert_eq!(plugins[0].install, InstallKind::Link);

        // A second install of the same name conflicts.
        assert!(install(&home, &src.to_string_lossy()).await.is_err());

        uninstall(&home, "demo").await.unwrap();
        assert!(discover_plugins(None, &home).await.is_empty());
        // The linked source is untouched.
        assert!(src.join("commands/x.md").exists());
    }

    #[tokio::test]
    async fn install_rejects_non_plugins_and_bad_paths() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let plain = tmp.path().join("plain");
        std::fs::create_dir_all(&plain).unwrap();
        assert!(install(&home, &plain.to_string_lossy()).await.is_err());
        assert!(install(&home, "relative/path").await.is_err());
        assert!(install(&home, "/nonexistent/nope").await.is_err());
        assert!(install(&home, "").await.is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn install_marketplace_links_each_plugin() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let mkt = tmp.path().join("mkt");
        write(
            &mkt,
            ".claude-plugin/marketplace.json",
            r#"{"name":"mymkt","plugins":[{"name":"one","source":"./plugins/one"},{"source":"./plugins/two"}]}"#,
        );
        write(
            &mkt,
            "plugins/one/commands/a.md",
            "---\ndescription: a\n---\na\n",
        );
        write(&mkt, "plugins/two/plugin.json", r#"{"name":"two"}"#);
        write(&mkt, "plugins/two/commands/b.md", "b\n");

        let names = install(&home, &mkt.to_string_lossy()).await.unwrap();
        assert_eq!(names, ["one", "two"]);
        let plugins = discover_plugins(None, &home).await;
        assert_eq!(plugins.len(), 2);
        assert!(plugins.iter().all(|p| p.install == InstallKind::Link));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn set_enabled_roundtrips() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        user_plugin(&home);
        set_enabled(&home, "demo", false).await.unwrap();
        assert!(!discover_plugins(None, &home).await[0].enabled);
        set_enabled(&home, "demo", true).await.unwrap();
        assert!(discover_plugins(None, &home).await[0].enabled);
        assert!(set_enabled(&home, "ghost", false).await.is_err());
    }

    #[tokio::test]
    async fn update_rejects_non_git_plugins() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        user_plugin(&home);
        assert!(update(&home, "demo").await.is_err());
        assert!(update(&home, "ghost").await.is_err());
    }

    #[tokio::test]
    async fn plugin_info_summarizes_contents() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        user_plugin(&home);
        let plugins = discover_plugins(None, &home).await;
        let info = plugin_info(&plugins[0]).await;
        assert_eq!(info.name, "demo");
        assert_eq!(info.source, "user");
        assert_eq!(info.skills, ["review"]);
        assert_eq!(info.commands, ["gen"]);
        assert!(info.manageable);
    }
}
