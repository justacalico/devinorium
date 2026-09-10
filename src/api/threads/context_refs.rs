//! Context path references: files and folders the user dragged from the
//! files panel into the composer.
//!
//! The frontend sends project-relative paths in the `context_paths` multipart
//! field. Because the frontend and backend share the same machine, nothing is
//! uploaded: the paths are resolved to absolute paths, recorded in the
//! message's attachment metadata so they render as chips in history, and
//! appended to the prompt so the agent can read them directly.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::db::ThreadRow;
use crate::security::paths;
use crate::AppState;

use super::send::SendInput;

/// Maximum number of context references accepted per message.
const MAX_CONTEXT_REFS: usize = 64;
/// Maximum length of a single context path.
const MAX_CONTEXT_PATH_LEN: usize = 4096;

/// A context reference resolved against the thread's project root.
#[derive(Debug, Clone)]
pub(crate) struct ContextRef {
    /// The path as the client sent it (usually project-relative).
    pub rel: String,
    /// Resolved absolute path on this machine.
    pub abs: PathBuf,
    pub is_dir: bool,
    pub exists: bool,
}

/// Raw `context_paths` entry sent by the client.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct ContextPathIn {
    pub path: String,
    #[serde(default)]
    pub is_dir: bool,
}

/// Parse the `context_paths` multipart field: a JSON array of
/// `{"path": "...", "is_dir": bool}` objects (plain strings are also accepted).
pub(crate) fn parse_context_paths(raw: &str) -> Result<Vec<ContextPathIn>, String> {
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|_| "invalid context_paths".to_string())?;
    let items = value
        .as_array()
        .ok_or_else(|| "invalid context_paths".to_string())?;
    if items.len() > MAX_CONTEXT_REFS {
        return Err(format!("too many context paths (max {MAX_CONTEXT_REFS})"));
    }
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let parsed = if item.is_string() {
            ContextPathIn {
                path: item.as_str().unwrap_or_default().to_string(),
                is_dir: false,
            }
        } else {
            serde_json::from_value::<ContextPathIn>(item.clone())
                .map_err(|_| "invalid context_paths".to_string())?
        };
        if parsed.path.chars().count() > MAX_CONTEXT_PATH_LEN {
            return Err("context path too long".to_string());
        }
        out.push(parsed);
    }
    Ok(out)
}

/// Resolve a single client-supplied context path against `root`.
///
/// Relative paths must stay inside `root`; absolute paths are allowed but
/// still screened for hidden components. Returns `None` for traversal attempts
/// and protected (`.git`, `.devinorium-attachments`) paths.
fn resolve_context_path(root: &Path, rel: &str) -> Option<PathBuf> {
    let path = Path::new(rel);
    if path.is_absolute() {
        let resolved = paths::resolve(path, None, None)?;
        if paths::is_hidden_path(&resolved) {
            return None;
        }
        Some(resolved)
    } else {
        let roots = [root.to_path_buf()];
        let resolved = paths::resolve_within(path, Some(root), &roots)?;
        if paths::is_hidden_within(root, &resolved) {
            return None;
        }
        Some(resolved)
    }
}

/// The directory context paths resolve against: the thread's project root.
/// Project-less threads fall back to the user's home directory; a thread whose
/// project row is gone resolves nothing (`None`).
async fn context_root(state: &AppState, thread: &ThreadRow) -> Option<PathBuf> {
    if let Some(pid) = thread.project_id {
        let p = state.db.get_project(pid, thread.user_id).await.ok()??;
        return Some(
            tokio::fs::canonicalize(&p.path)
                .await
                .unwrap_or_else(|_| PathBuf::from(&p.path)),
        );
    }
    Some(state.config.home_dir.clone())
}

/// Resolve the raw client paths against `root`, dropping empties, traversal,
/// and protected paths, deduplicating by resolved path.
fn resolve_refs(root: &Path, raws: Vec<ContextPathIn>) -> Vec<(ContextPathIn, PathBuf)> {
    let mut seen = HashSet::new();
    raws.into_iter()
        .filter_map(|raw| {
            let rel = raw.path.trim();
            if rel.is_empty() {
                return None;
            }
            resolve_context_path(root, rel).map(|abs| (raw, abs))
        })
        .filter(|(_, abs)| seen.insert(abs.clone()))
        .collect()
}

/// Resolve `input.context_paths`, populating `input.context_refs` for the
/// prompt and `input.att_meta` so the references render as message chips.
/// Unresolvable or protected paths are dropped silently.
pub(crate) async fn resolve_context_refs(
    state: &AppState,
    thread: &ThreadRow,
    input: &mut SendInput,
) {
    if input.context_paths.is_empty() {
        return;
    }
    let Some(root) = context_root(state, thread).await else {
        input.context_paths.clear();
        return;
    };
    for (raw, abs) in resolve_refs(&root, std::mem::take(&mut input.context_paths)) {
        let rel = raw.path.trim().to_string();
        let meta = tokio::fs::metadata(&abs).await.ok();
        let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(raw.is_dir);
        input.att_meta.push(serde_json::json!({
            "filename": rel,
            "mime": "application/x-devinorium-path",
            "size": 0,
            "kind": "path",
            "is_dir": is_dir,
        }));
        input.context_refs.push(ContextRef {
            rel,
            abs,
            is_dir,
            exists: meta.is_some(),
        });
    }
}

/// Build the prompt sent to the provider: the user's text plus a context
/// block listing the referenced paths (absolute, so the agent can read them
/// regardless of its working directory).
pub(crate) fn prompt_with_refs(prompt: &str, refs: &[ContextRef]) -> String {
    if refs.is_empty() {
        return prompt.to_string();
    }
    let mut out = String::with_capacity(prompt.len() + refs.len() * 64 + 128);
    let trimmed = prompt.trim_end();
    if !trimmed.is_empty() {
        out.push_str(trimmed);
        out.push_str("\n\n");
    }
    out.push_str(
        "The user referenced these paths for context \
         (they are on this machine and can be read directly):",
    );
    for r in refs {
        out.push_str("\n- ");
        out.push_str(&r.rel);
        out.push_str(": ");
        out.push_str(&r.abs.to_string_lossy());
        out.push_str(if r.is_dir { " (directory)" } else { " (file)" });
        if !r.exists {
            out.push_str(" [missing]");
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_context_paths_accepts_objects_and_strings() {
        let refs = parse_context_paths(
            r#"[{"path":"src/main.rs","is_dir":false},"docs",{"path":"lib","is_dir":true}]"#,
        )
        .unwrap();
        assert_eq!(refs.len(), 3);
        assert_eq!(refs[0].path, "src/main.rs");
        assert!(!refs[0].is_dir);
        assert_eq!(refs[1].path, "docs");
        assert!(refs[2].is_dir);
    }

    #[test]
    fn parse_context_paths_rejects_malformed() {
        assert!(parse_context_paths("not json").is_err());
        assert!(parse_context_paths(r#"{"path":"x"}"#).is_err());
        assert!(parse_context_paths(r#"[{"path":1}]"#).is_err());
    }

    #[test]
    fn parse_context_paths_caps_count_and_length() {
        let many = vec![serde_json::json!({"path": "a" }); MAX_CONTEXT_REFS + 1];
        assert!(parse_context_paths(&serde_json::to_string(&many).unwrap()).is_err());
        let long = serde_json::to_string(&serde_json::json!([
            {"path": "x".repeat(MAX_CONTEXT_PATH_LEN + 1)}
        ]))
        .unwrap();
        assert!(parse_context_paths(&long).is_err());
    }

    #[test]
    fn resolve_context_path_accepts_relative_inside_root() {
        let tmp = tempfile::tempdir().unwrap().keep();
        std::fs::create_dir_all(tmp.join("src")).unwrap();
        std::fs::write(tmp.join("src/main.rs"), "fn main() {}").unwrap();
        let resolved = resolve_context_path(&tmp, "src/main.rs").unwrap();
        assert!(resolved.ends_with("src/main.rs"));
        assert!(resolved.starts_with(&tmp));
    }

    #[test]
    fn resolve_context_path_rejects_traversal_and_hidden() {
        let tmp = tempfile::tempdir().unwrap().keep();
        assert!(resolve_context_path(&tmp, "../outside.txt").is_none());
        assert!(resolve_context_path(&tmp, ".git/config").is_none());
        assert!(resolve_context_path(&tmp, "sub/.devinorium-attachments/x").is_none());
    }

    #[test]
    fn resolve_context_path_accepts_absolute() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let file = tmp.join("abs.txt");
        std::fs::write(&file, "x").unwrap();
        let resolved = resolve_context_path(&tmp, file.to_str().unwrap()).unwrap();
        assert_eq!(resolved, file.canonicalize().unwrap());
    }

    #[test]
    fn resolve_refs_dedupes_by_resolved_path() {
        let tmp = tempfile::tempdir().unwrap().keep();
        std::fs::create_dir_all(tmp.join("src")).unwrap();
        std::fs::write(tmp.join("src/main.rs"), "fn main() {}").unwrap();
        let raws = vec![
            ContextPathIn {
                path: "src/main.rs".into(),
                is_dir: false,
            },
            ContextPathIn {
                path: "src/../src/main.rs".into(),
                is_dir: false,
            },
            ContextPathIn {
                path: "src//main.rs".into(),
                is_dir: false,
            },
            ContextPathIn {
                path: "src".into(),
                is_dir: true,
            },
        ];
        let refs = resolve_refs(&tmp, raws);
        assert_eq!(refs.len(), 2);
        assert_eq!(refs[0].0.path, "src/main.rs");
        assert_eq!(refs[1].0.path, "src");
    }

    #[test]
    fn prompt_with_refs_appends_context_block() {
        let refs = vec![
            ContextRef {
                rel: "src/main.rs".into(),
                abs: PathBuf::from("/proj/src/main.rs"),
                is_dir: false,
                exists: true,
            },
            ContextRef {
                rel: "docs".into(),
                abs: PathBuf::from("/proj/docs"),
                is_dir: true,
                exists: true,
            },
        ];
        let out = prompt_with_refs("fix the bug", &refs);
        assert!(out.starts_with("fix the bug\n\n"));
        assert!(out.contains("src/main.rs: /proj/src/main.rs (file)"));
        assert!(out.contains("docs: /proj/docs (directory)"));
    }

    #[test]
    fn prompt_with_refs_marks_missing_and_handles_empty_prompt() {
        let refs = vec![ContextRef {
            rel: "gone.txt".into(),
            abs: PathBuf::from("/proj/gone.txt"),
            is_dir: false,
            exists: false,
        }];
        let out = prompt_with_refs("", &refs);
        assert!(!out.starts_with('\n'));
        assert!(out.contains("gone.txt: /proj/gone.txt (file) [missing]"));
        assert_eq!(prompt_with_refs("hi", &[]), "hi");
    }
}
