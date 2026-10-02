//! MCP servers reach Codex through its config file: `app-server` children
//! get `CODEX_HOME` pointing at a temp dir whose `config.toml` is the user's
//! real one plus the devinorium-managed `[mcp_servers]` tables; every other
//! entry under the real home (auth, sessions, rollouts) is symlinked in so
//! nothing else changes. The temp dir self-cleans when the turn ends.

use std::path::PathBuf;

use crate::mcp::McpServerConfig;

/// The directory codex resolves `config.toml` under: `$CODEX_HOME`, then
/// `~/.codex`.
fn real_codex_home() -> Option<PathBuf> {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".codex")))
}

/// Fold `servers` into `config.mcp_servers`, preserving everything else the
/// user configured. Devinorium's entries win on a name clash. Returns false
/// when the existing document cannot be merged safely — unparseable or a
/// non-table `mcp_servers` — in which case the list is not applied rather
/// than clobbering the user's config.
fn merge_mcp_servers(config: &mut toml::Value, servers: &[McpServerConfig]) -> bool {
    if !config.is_table() {
        return false;
    }
    let root = config.as_table_mut().unwrap();
    match root.entry("mcp_servers".to_string()) {
        toml::map::Entry::Vacant(v) => {
            v.insert(toml::Value::Table(toml::map::Map::new()));
        }
        toml::map::Entry::Occupied(o) if !o.get().is_table() => return false,
        _ => {}
    }
    let table = root
        .get_mut("mcp_servers")
        .and_then(toml::Value::as_table_mut)
        .unwrap();
    for server in servers {
        match server.to_codex_entry() {
            Some(entry) => {
                table.insert(server.name.trim().to_string(), entry);
            }
            None => tracing::warn!(
                server = %server.name,
                transport = %server.transport,
                "codex cannot express this MCP transport; skipped"
            ),
        }
    }
    true
}

/// A temp codex home handed to a child process: the tempdir keeps the
/// mirror alive and `real` records the dir it mirrors so files the child
/// writes (sessions, refreshed auth) can sync back when the run ends.
pub(crate) struct CodexHomeGuard {
    _temp: tempfile::TempDir,
    real: PathBuf,
}

impl CodexHomeGuard {
    /// Copy child-created entries back into the real codex home. Merged
    /// config.toml stays temp-only.
    pub(crate) async fn sync_back(&self) {
        if let Err(e) = crate::providers::sync_back_mirrored_dir(
            self._temp.path(),
            &self.real,
            &["config.toml"],
        )
        .await
        {
            tracing::warn!(error = %e, "could not sync the codex home mirror back");
        }
    }
}

/// The env pairs the codex child needs and the guard holding the temp home.
/// Returns empty env when the list is empty or the config cannot be merged.
/// Filesystem failures degrade to no mirror rather than aborting the turn.
pub(crate) async fn codex_home_env(
    servers: &[McpServerConfig],
) -> anyhow::Result<(Vec<(String, String)>, Option<CodexHomeGuard>)> {
    if servers.is_empty() {
        return Ok((Vec::new(), None));
    }
    let Some(real_home) = real_codex_home() else {
        tracing::warn!("mcp servers configured but no codex home found; not applied");
        return Ok((Vec::new(), None));
    };
    let dir = match write_codex_home(&real_home, servers).await {
        Ok(dir) => dir,
        Err(e) => {
            tracing::warn!(
                error = %e,
                "could not build the codex home mirror; running without it"
            );
            None
        }
    };
    Ok(match dir {
        Some(temp) => (
            vec![(
                "CODEX_HOME".to_string(),
                temp.path().to_string_lossy().to_string(),
            )],
            Some(CodexHomeGuard {
                _temp: temp,
                real: real_home,
            }),
        ),
        None => (Vec::new(), None),
    })
}

/// Build the temp home: mirrors the real codex home with symlinks and
/// writes a merged `config.toml`.
#[cfg(unix)]
async fn write_codex_home(
    real_home: &std::path::Path,
    servers: &[McpServerConfig],
) -> anyhow::Result<Option<tempfile::TempDir>> {
    let mut config: toml::Value = match tokio::fs::read(real_home.join("config.toml")).await {
        Ok(bytes) => match toml::from_str(&String::from_utf8_lossy(&bytes)) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "codex config.toml is not valid TOML; devinorium MCP servers not applied"
                );
                return Ok(None);
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            toml::Value::Table(toml::map::Map::new())
        }
        Err(e) => return Err(e.into()),
    };
    if !merge_mcp_servers(&mut config, servers) {
        tracing::warn!("codex mcp_servers is not a table; devinorium servers not applied");
        return Ok(None);
    }

    let temp = tempfile::tempdir()?;
    let home = temp.path();
    if real_home.is_dir() {
        let mut entries = tokio::fs::read_dir(real_home).await?;
        while let Some(entry) = entries.next_entry().await? {
            if entry.file_name() == "config.toml" {
                continue;
            }
            std::os::unix::fs::symlink(entry.path(), home.join(entry.file_name()))?;
        }
    }
    tokio::fs::write(home.join("config.toml"), toml::to_string(&config)?).await?;
    Ok(Some(temp))
}

#[cfg(not(unix))]
async fn write_codex_home(
    _real_home: &std::path::Path,
    servers: &[McpServerConfig],
) -> anyhow::Result<Option<tempfile::TempDir>> {
    if !servers.is_empty() {
        tracing::warn!("mcp servers cannot be injected into codex app-server on this platform");
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn stdio(name: &str) -> McpServerConfig {
        McpServerConfig {
            name: name.into(),
            enabled: true,
            transport: "stdio".into(),
            command: "npx".into(),
            args: vec!["-y".into(), "pkg".into()],
            env: BTreeMap::new(),
            url: String::new(),
            headers: BTreeMap::new(),
        }
    }

    #[test]
    fn merge_adds_servers_to_existing_config() {
        let mut config: toml::Value =
            toml::from_str("model = \"gpt-5\"\n[mcp_servers.existing]\nurl = \"https://a\"\n")
                .unwrap();
        assert!(merge_mcp_servers(&mut config, &[stdio("mine")]));
        assert_eq!(config["model"].as_str(), Some("gpt-5"));
        assert_eq!(
            config["mcp_servers"]["mine"]["command"].as_str(),
            Some("npx")
        );
        assert_eq!(
            config["mcp_servers"]["existing"]["url"].as_str(),
            Some("https://a")
        );
    }

    #[test]
    fn merge_overwrites_same_name_and_marks_disabled() {
        let mut config: toml::Value =
            toml::from_str("[mcp_servers.x]\ncommand = \"old\"\n").unwrap();
        let mut s = stdio("x");
        s.enabled = false;
        assert!(merge_mcp_servers(&mut config, &[s]));
        let entry = &config["mcp_servers"]["x"];
        assert_eq!(entry["command"].as_str(), Some("npx"));
        assert_eq!(entry["enabled"].as_bool(), Some(false));
    }

    #[test]
    fn merge_rejects_non_table_mcp_servers() {
        let mut config: toml::Value = toml::from_str("mcp_servers = \"oops\"\n").unwrap();
        assert!(!merge_mcp_servers(&mut config, &[stdio("x")]));
    }

    #[test]
    fn merge_rejects_scalar_root() {
        let mut config = toml::Value::String("nope".into());
        assert!(!merge_mcp_servers(&mut config, &[stdio("x")]));
    }

    /// Dotted names must serialize as quoted keys — `[mcp_servers.a.b]`
    /// would nest instead of naming the server.
    #[test]
    fn dotted_names_round_trip_as_one_entry() {
        let mut config = toml::Value::Table(toml::map::Map::new());
        assert!(merge_mcp_servers(&mut config, &[stdio("a.b")]));
        let text = toml::to_string(&config).unwrap();
        let back: toml::Value = toml::from_str(&text).unwrap();
        assert_eq!(
            back["mcp_servers"]["a.b"]["command"].as_str(),
            Some("npx"),
            "{text}"
        );
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn codex_home_mirrors_and_merges() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("codex-home");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::write(real.join("config.toml"), "model = \"m\"\n").unwrap();
        std::fs::write(real.join("auth.json"), "{}").unwrap();

        let home = write_codex_home(&real, &[stdio("t")])
            .await
            .unwrap()
            .unwrap();
        let merged: toml::Value =
            toml::from_str(&std::fs::read_to_string(home.path().join("config.toml")).unwrap())
                .unwrap();
        assert_eq!(merged["model"].as_str(), Some("m"));
        assert_eq!(merged["mcp_servers"]["t"]["command"].as_str(), Some("npx"));
        assert!(home.path().join("auth.json").is_symlink());
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn codex_home_without_existing_config_starts_fresh() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("empty");
        std::fs::create_dir_all(&real).unwrap();
        let home = write_codex_home(&real, &[stdio("t")])
            .await
            .unwrap()
            .unwrap();
        let merged: toml::Value =
            toml::from_str(&std::fs::read_to_string(home.path().join("config.toml")).unwrap())
                .unwrap();
        assert_eq!(merged["mcp_servers"]["t"]["command"].as_str(), Some("npx"));
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn codex_home_refuses_broken_config() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("broken");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::write(real.join("config.toml"), "not = [toml\n").unwrap();
        assert!(write_codex_home(&real, &[stdio("t")])
            .await
            .unwrap()
            .is_none());
    }
}
