//! The `devin` CLI provider.
//!
//! Drives the local `devin` binary as a subprocess:
//! - `devin --model <m> -p "<prompt>"` to start a new session (single-turn).
//! - `devin --resume <id> -p "<prompt>"` to continue a session.
//! - `devin list --format json` to discover the session id of a freshly
//!   created session (the most recent one in the working directory).
//! - `devin models list --format json` to enumerate models.
//!
//! Attachments are written to a temporary directory inside the working
//! directory and referenced in the prompt via `@path` mentions, which the
//! devin CLI expands as context.

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use serde::Deserialize;
use tempfile::NamedTempFile;
use tokio::process::Command;

use super::{
    Attachment, ModelInfo, Provider, SendRequest, SendResponse, StartRequest,
    StartResponse,
};

pub struct DevinCliProvider {
    bin: String,
    #[allow(dead_code)]
    default_model: String,
}

impl DevinCliProvider {
    pub fn new(bin: String, default_model: String) -> Self {
        Self { bin, default_model }
    }
}

#[async_trait]
impl Provider for DevinCliProvider {
    fn id(&self) -> &str {
        "devin-cli"
    }

    fn name(&self) -> &str {
        "Devin CLI"
    }

    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        let out = self.run_devin(&["models", "list", "--format", "json"], Path::new(".")).await?;
        #[derive(Deserialize)]
        struct Family {
            family_label: String,
            #[serde(default)]
            #[allow(dead_code)]
            family_uid: String,
            variants: Vec<Variant>,
        }
        #[derive(Deserialize)]
        struct Variant {
            model_uid: String,
            label: String,
            #[serde(default)]
            cost_tier: String,
        }
        #[derive(Deserialize)]
        struct Doc {
            families: Vec<Family>,
        }
        let doc: Doc = serde_json::from_slice(&out)?;
        let mut models = Vec::new();
        for f in doc.families {
            for v in f.variants {
                models.push(ModelInfo {
                    id: v.model_uid,
                    label: v.label,
                    cost_tier: v.cost_tier,
                    family: f.family_label.clone(),
                });
            }
        }
        Ok(models)
    }

    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> {
        let working_dir = req.options.working_dir.clone();
        let prompt = self.with_attachments(&req.prompt, &req.options.attachments, &working_dir).await?;
        let _config = self.ensure_permission_config(req.options.permissions.as_deref()).await?;

        let mut args = vec![
            "--respect-workspace-trust".to_string(),
            "false".to_string(),
            "--model".to_string(),
            req.options.model.clone(),
        ];
        if let Some(ref config) = _config {
            args.push("--config".to_string());
            args.push(config.path().display().to_string());
        }
        args.extend(permission_flags(&req.options.permission_mode));
        args.push("-p".to_string());
        args.push(prompt.clone());

        let reply = self.run_devin(&args, &working_dir).await?;
        let reply = String::from_utf8_lossy(&reply).trim().to_string();

        // Discover the session id: the most recent session in this working dir.
        let session_id = self.find_latest_session(&working_dir).await?;

        // Derive a title from the first prompt (truncate).
        let title = title_from_prompt(&req.prompt);

        Ok(StartResponse {
            session_id,
            reply,
            title,
        })
    }

    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let working_dir = req.options.working_dir.clone();
        let prompt = self.with_attachments(&req.prompt, &req.options.attachments, &working_dir).await?;
        let _config = self.ensure_permission_config(req.options.permissions.as_deref()).await?;

        let mut args = vec![
            "--respect-workspace-trust".to_string(),
            "false".to_string(),
            "--resume".to_string(),
            req.session_id.clone(),
        ];
        if let Some(ref config) = _config {
            args.push("--config".to_string());
            args.push(config.path().display().to_string());
        }
        args.extend(permission_flags(&req.options.permission_mode));
        args.push("-p".to_string());
        args.push(prompt);

        let reply = self.run_devin(&args, &working_dir).await?;
        let reply = String::from_utf8_lossy(&reply).trim().to_string();
        Ok(SendResponse { reply })
    }

    async fn export(&self, session_id: &str, working_dir: &Path) -> anyhow::Result<serde_json::Value> {
        // The devin CLI writes an ATIF export when --export is passed on a turn.
        // To avoid polluting the conversation we do not run a turn here; instead
        // we return an empty object. Conversation history is stored in our DB.
        let _ = session_id;
        let _ = working_dir;
        Ok(serde_json::json!({}))
    }
}

impl DevinCliProvider {
    /// Run `devin` with the given args in `working_dir`, returning stdout.
    async fn run_devin<A: AsRef<str>>(&self, args: &[A], working_dir: &Path) -> anyhow::Result<Vec<u8>> {
        let output = Command::new(&self.bin)
            .args(args.iter().map(|a| a.as_ref()))
            .current_dir(working_dir)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output()
            .await
            .map_err(|e| anyhow::anyhow!("failed to spawn `{}`: {e}", self.bin))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!(
                "devin exited with {}: {}",
                output.status,
                stderr.trim()
            );
        }
        Ok(output.stdout)
    }

    /// Find the most recent devin session id for a working directory.
    async fn find_latest_session(&self, working_dir: &Path) -> anyhow::Result<String> {
        let out = self
            .run_devin(&["list", "--format", "json"], working_dir)
            .await?;
        #[derive(Deserialize)]
        struct Sess {
            id: String,
            working_directory: String,
            last_activity_at: i64,
        }
        let sessions: Vec<Sess> = serde_json::from_slice(&out)?;
        let canon = working_dir.canonicalize().unwrap_or_else(|_| working_dir.to_path_buf());
        let mut best: Option<Sess> = None;
        for s in sessions {
            let sdir = PathBuf::from(&s.working_directory);
            let scanon = sdir.canonicalize().unwrap_or(sdir);
            if scanon == canon {
                match &best {
                    Some(b) if b.last_activity_at >= s.last_activity_at => {}
                    _ => best = Some(s),
                }
            }
        }
        best.map(|s| s.id)
            .ok_or_else(|| anyhow::anyhow!("no devin session found for {:?}", working_dir))
    }

    /// Write a temp devin config with the thread permission allowlist, if any.
    /// Returns the temp file when the config was written; it is deleted when
    /// the returned value is dropped.
    async fn ensure_permission_config(
        &self,
        permissions: Option<&str>,
    ) -> anyhow::Result<Option<NamedTempFile>> {
        let rules: Vec<String> = permissions
            .unwrap_or("")
            .split(|c: char| c == ',' || c == '\n' || c == '\r')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();

        if rules.is_empty() {
            return Ok(None);
        }

        let config = serde_json::json!({
            "permissions": {
                "allow": rules,
            },
        });

        let temp = tokio::task::spawn_blocking(NamedTempFile::new).await??;
        tokio::fs::write(temp.path(), serde_json::to_string_pretty(&config)?).await?;
        Ok(Some(temp))
    }

    /// Write attachments to a temp dir under the working directory and append
    /// `@path` mentions to the prompt.
    async fn with_attachments(
        &self,
        prompt: &str,
        attachments: &[Attachment],
        working_dir: &Path,
    ) -> anyhow::Result<String> {
        if attachments.is_empty() {
            return Ok(prompt.to_string());
        }
        let dir = working_dir.join(".devinorium-attachments");
        tokio::fs::create_dir_all(&dir).await?;
        let mut full = prompt.to_string();
        for att in attachments {
            let safe = att.filename.replace(|c: char| !c.is_alphanumeric() && c != '.' && c != '-' && c != '_', "_");
            let path = dir.join(safe);
            tokio::fs::write(&path, &att.data).await?;
            full.push_str(&format!(" @{}", path.display()));
        }
        Ok(full)
    }
}

fn permission_flags(mode: &str) -> Vec<String> {
    let cli_mode = match mode {
        // The devin CLI documents `dangerous` as the canonical name for
        // auto-approving all tools. `bypass` and `yolo` are user-facing aliases.
        "bypass" | "yolo" => "dangerous",
        "accept-edits" | "smart" | "dangerous" | "autonomous" => mode,
        // `normal` is the default; no flag needed.
        _ => return vec![],
    };
    vec!["--permission-mode".to_string(), cli_mode.to_string()]
}

fn title_from_prompt(prompt: &str) -> String {
    let s = prompt.trim().replace('\n', " ");
    let mut t: String = s.chars().take(60).collect();
    if s.chars().count() > 60 {
        t.push('…');
    }
    t
}
