//! Agent skills: reusable `SKILL.md` prompt bundles invoked with `/name`.
//!
//! Discovery mirrors the Devin CLI layout so a skill the CLI can see shows
//! up in the composer `/` picker too: `<cwd>/.devin/skills`,
//! `<cwd>/.agents/skills`, `<cwd>/.windsurf/skills` at project scope, plus
//! `~/.config/devin/skills`, `~/.agents/skills`, and
//! `~/.codeium/<windsurf channel>/skills` at user scope. Earlier entries win
//! on a name clash, so project skills shadow global ones.
//!
//! Sending `/name args` reaches providers two ways: the Devin CLI gets the
//! text verbatim (its ACP server resolves slash commands natively, keeping
//! the skill's own permissions and subagent behavior); other providers get
//! the skill body expanded inline so the workflow still applies.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde::Serialize;

/// A skill as reported to the client; the body stays server-side.
#[derive(Debug, Clone, Serialize)]
pub struct SkillInfo {
    pub name: String,
    pub description: String,
    /// Frontmatter `argument-hint`, shown after the command name.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub argument_hint: String,
    /// `project` for cwd-scoped skills, `user` for global ones.
    pub source: String,
}

/// A discovered skill with its prompt body.
#[derive(Debug, Clone)]
pub struct Skill {
    pub info: SkillInfo,
    /// SKILL.md content after the frontmatter block.
    pub body: String,
}

/// The directories scanned for skills, in precedence order. `%` expands to
/// the thread's working directory, `~` to the server home.
fn skill_dirs(cwd: &Path, home: &Path) -> Vec<(PathBuf, &'static str)> {
    let mut dirs = vec![
        (cwd.join(".devin/skills"), "project"),
        (cwd.join(".agents/skills"), "project"),
        (cwd.join(".windsurf/skills"), "project"),
        (home.join(".config/devin/skills"), "user"),
        (home.join(".agents/skills"), "user"),
    ];
    for channel in ["windsurf", "windsurf-next", "windsurf-insiders"] {
        dirs.push((home.join(".codeium").join(channel).join("skills"), "user"));
    }
    dirs
}

/// Largest SKILL.md accepted; a bigger file is skipped rather than read
/// whole.
const MAX_SKILL_BYTES: u64 = 256 * 1024;

/// Split a `---`-wrapped frontmatter block off the top of a SKILL.md,
/// returning `(header, body)`. `None` when the file has no block.
fn split_frontmatter(content: &str) -> Option<(&str, &str)> {
    let rest = content.strip_prefix("---")?;
    let rest = rest
        .strip_prefix("\r\n")
        .or_else(|| rest.strip_prefix('\n'))?;
    let mut offset = 0;
    for line in rest.split_inclusive('\n') {
        if line.trim_end() == "---" {
            return Some((&rest[..offset], &rest[offset + line.len()..]));
        }
        offset += line.len();
    }
    None
}

/// Split YAML-lite frontmatter into header fields and the prompt body.
/// Only flat `key: value` pairs are read — enough for `name`,
/// `description`, and `argument-hint`. Returns `None` for either when the
/// file has no frontmatter block at all.
fn parse_skill_md(content: &str) -> (SkillInfo, String) {
    let mut info = SkillInfo {
        name: String::new(),
        description: String::new(),
        argument_hint: String::new(),
        source: String::new(),
    };
    let Some((header, body)) = split_frontmatter(content) else {
        return (info, content.to_string());
    };
    for line in header.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        // Strip one matched outer quote pair only — `trim_matches` would
        // eat repeated quotes and characters like `don'` at the edges.
        let value = {
            let v = value.trim();
            let bytes = v.as_bytes();
            if v.len() >= 2
                && ((bytes[0] == b'"' && bytes[v.len() - 1] == b'"')
                    || (bytes[0] == b'\'' && bytes[v.len() - 1] == b'\''))
            {
                v[1..v.len() - 1].to_string()
            } else {
                v.to_string()
            }
        };
        match key.trim() {
            "name" => info.name = value,
            "description" => info.description = value,
            "argument-hint" | "argument_hint" => info.argument_hint = value,
            _ => {}
        }
    }
    (info, body.trim_start_matches(['\n', '\r']).to_string())
}

/// Names the picker can actually complete: the composer token charset, not
/// `ask` (the composer already owns that prefix for ask mode).
fn invocable_name(name: &str) -> bool {
    name != "ask"
        && !name.is_empty()
        && name
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphanumeric())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// Read one `SKILL.md`; `dir_name` is the fallback when frontmatter omits
/// `name`. Symlinks are skipped — a cloned repo should not be able to hand
/// an outside file to the `/` picker.
async fn read_skill(path: &Path, dir_name: &str, source: &str) -> Option<Skill> {
    let meta = tokio::fs::symlink_metadata(path).await.ok()?;
    if meta.file_type().is_symlink() || !meta.is_file() || meta.len() > MAX_SKILL_BYTES {
        return None;
    }
    let content = tokio::fs::read_to_string(path).await.ok()?;
    let (mut info, body) = parse_skill_md(content.strip_prefix('\u{feff}').unwrap_or(&content));
    if info.name.trim().is_empty() {
        info.name = dir_name.to_string();
    }
    info.name = info.name.trim().to_string();
    if !invocable_name(&info.name) {
        return None;
    }
    info.source = source.to_string();
    Some(Skill { info, body })
}

/// Scan every skills directory under `cwd` and `home`, deduplicating by
/// name (first hit wins, so project skills shadow user ones) and sorting
/// the result alphabetically for a stable picker order.
pub async fn discover_skills(cwd: &Path, home: &Path) -> Vec<Skill> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for (dir, source) in skill_dirs(cwd, home) {
        let mut entries = match tokio::fs::read_dir(&dir).await {
            Ok(e) => e,
            Err(_) => continue,
        };
        let mut names = Vec::new();
        while let Ok(Some(entry)) = entries.next_entry().await {
            // A symlinked skill dir would let the picker read outside the
            // scanned roots; file_type does not follow the link.
            if entry
                .file_type()
                .await
                .map(|t| t.is_symlink())
                .unwrap_or(true)
            {
                continue;
            }
            names.push(entry.file_name());
        }
        names.sort();
        for name in names {
            let Some(dir_name) = name.to_str() else {
                continue;
            };
            let path = dir.join(dir_name).join("SKILL.md");
            let Some(skill) = read_skill(&path, dir_name, source).await else {
                continue;
            };
            if seen.insert(skill.info.name.clone()) {
                out.push(skill);
            }
        }
    }
    out.sort_by(|a, b| a.info.name.cmp(&b.info.name));
    out
}

/// Split a leading `/name rest...` command. `None` when the prompt does not
/// start with a slash token or the name is empty.
pub fn split_slash_command(prompt: &str) -> Option<(&str, &str)> {
    let rest = prompt.strip_prefix('/')?;
    let end = rest.find(|c: char| c.is_whitespace()).unwrap_or(rest.len());
    let name = &rest[..end];
    if name.is_empty() || name.contains('/') || name.contains('\\') {
        return None;
    }
    Some((name, rest[end..].trim()))
}

/// Expand a leading `/name args` into the skill's prompt body for providers
/// without native slash commands. `$ARGUMENTS` in the body is replaced with
/// the args; a body without the placeholder gets the args appended. Unknown
/// names pass through untouched.
pub async fn expand_skill_prompt(prompt: &str, cwd: &Path, home: &Path) -> String {
    let Some((name, args)) = split_slash_command(prompt) else {
        return prompt.to_string();
    };
    let skills = discover_skills(cwd, home).await;
    let Some(skill) = skills.iter().find(|s| s.info.name == name) else {
        return prompt.to_string();
    };
    let body = skill.body.trim();
    if body.is_empty() {
        return prompt.to_string();
    }
    if args.is_empty() {
        return body.to_string();
    }
    if body.contains("$ARGUMENTS") {
        body.replace("$ARGUMENTS", args)
    } else {
        format!("{body}\n\n{args}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_skill(root: &Path, dir: &str, file: &str, content: &str) {
        let path = root.join(dir).join(file);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, content).unwrap();
    }

    const SKILL: &str = "---\nname: review\ndescription: Review code\nargument-hint: \"[file]\"\n---\n\nCheck the diff for bugs.\n";

    #[test]
    fn parse_frontmatter_reads_fields_and_body() {
        let (info, body) = parse_skill_md(SKILL);
        assert_eq!(info.name, "review");
        assert_eq!(info.description, "Review code");
        assert_eq!(info.argument_hint, "[file]");
        assert_eq!(body, "Check the diff for bugs.\n");
    }

    #[test]
    fn parse_handles_missing_frontmatter() {
        let (info, body) = parse_skill_md("just a body");
        assert!(info.name.is_empty());
        assert_eq!(body, "just a body");
        let (info, _) = parse_skill_md("---x\nname: no\n---\nbody");
        assert!(info.name.is_empty(), "marker must sit alone on its line");
    }

    #[tokio::test]
    async fn discover_scopes_and_dedupes() {
        let root = tempfile::tempdir().unwrap();
        let cwd = root.path().join("proj");
        let home = root.path().join("home");
        write_skill(&cwd, ".devin/skills/review", "SKILL.md", SKILL);
        write_skill(
            &cwd,
            ".agents/skills/local",
            "SKILL.md",
            "---\ndescription: local only\n---\nbody\n",
        );
        write_skill(
            &home,
            ".config/devin/skills/review",
            "SKILL.md",
            "---\nname: review\ndescription: shadowed\n---\nx\n",
        );
        write_skill(
            &home,
            ".agents/skills/global-one",
            "SKILL.md",
            "---\nname: global-one\n---\nx\n",
        );
        write_skill(
            &home,
            ".codeium/windsurf/skills/wind",
            "SKILL.md",
            "---\nname: wind\n---\nx\n",
        );

        let skills = discover_skills(&cwd, &home).await;
        let names: Vec<&str> = skills.iter().map(|s| s.info.name.as_str()).collect();
        assert_eq!(names, ["global-one", "local", "review", "wind"]);
        let review = skills.iter().find(|s| s.info.name == "review").unwrap();
        assert_eq!(review.info.source, "project");
        assert_eq!(review.info.description, "Review code");
        // `local` fell back to its directory name.
        let local = skills.iter().find(|s| s.info.name == "local").unwrap();
        assert_eq!(local.info.source, "project");
        let wind = skills.iter().find(|s| s.info.name == "wind").unwrap();
        assert_eq!(wind.info.source, "user");
    }

    #[tokio::test]
    async fn discover_skips_uninvocable_and_reserved_names() {
        let root = tempfile::tempdir().unwrap();
        let cwd = root.path();
        write_skill(
            cwd,
            ".devin/skills/ask",
            "SKILL.md",
            "---\nname: ask\n---\nx\n",
        );
        write_skill(cwd, ".devin/skills/bad name", "SKILL.md", "body\n");
        write_skill(
            cwd,
            ".devin/skills/good",
            "SKILL.md",
            "---\nname: good\n---\nx\n",
        );
        let skills = discover_skills(cwd, cwd).await;
        // `ask` collides with the composer's mode prefix and "bad name" can
        // never be typed after / — neither is offered.
        assert_eq!(
            skills
                .iter()
                .map(|s| s.info.name.as_str())
                .collect::<Vec<_>>(),
            ["good"]
        );
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn discover_skips_symlinked_skill_files() {
        let root = tempfile::tempdir().unwrap();
        let cwd = root.path();
        let outside = root.path().join("secret.md");
        std::fs::write(&outside, "---\nname: sneaky\n---\nx\n").unwrap();
        std::fs::create_dir_all(cwd.join(".devin/skills/link")).unwrap();
        std::os::unix::fs::symlink(&outside, cwd.join(".devin/skills/link/SKILL.md")).unwrap();
        let skills = discover_skills(cwd, cwd).await;
        assert!(skills.is_empty());

        // A symlinked skill directory is skipped the same way.
        let linkdir = root.path().join("outside-skills");
        std::fs::create_dir_all(&linkdir).unwrap();
        std::fs::write(linkdir.join("SKILL.md"), "---\nname: sneaky\n---\nx\n").unwrap();
        std::os::unix::fs::symlink(&linkdir, cwd.join(".devin/skills/dirlink")).unwrap();
        let skills = discover_skills(cwd, cwd).await;
        assert!(skills.is_empty());
    }

    #[tokio::test]
    async fn discover_ignores_non_skill_entries() {
        let root = tempfile::tempdir().unwrap();
        let cwd = root.path();
        std::fs::create_dir_all(cwd.join(".devin/skills/empty")).unwrap();
        write_skill(cwd, ".devin/skills", "stray.md", "nope");
        let skills = discover_skills(cwd, cwd).await;
        assert!(skills.is_empty());
    }

    #[test]
    fn split_command_parses_name_and_args() {
        assert_eq!(
            split_slash_command("/review src/foo.rs --deep"),
            Some(("review", "src/foo.rs --deep"))
        );
        assert_eq!(split_slash_command("/review"), Some(("review", "")));
        assert_eq!(split_slash_command("hello /review"), None);
        assert_eq!(split_slash_command("/"), None);
        assert_eq!(split_slash_command("/usr/bin/x"), None);
    }

    #[tokio::test]
    async fn expand_inlines_body_with_args() {
        let root = tempfile::tempdir().unwrap();
        let cwd = root.path();
        write_skill(cwd, ".devin/skills/review", "SKILL.md", SKILL);
        let out = expand_skill_prompt("/review src/main.rs", cwd, cwd).await;
        assert_eq!(out, "Check the diff for bugs.\n\nsrc/main.rs");
        // Without args the body is sent alone.
        let out = expand_skill_prompt("/review", cwd, cwd).await;
        assert_eq!(out, "Check the diff for bugs.");
    }

    #[tokio::test]
    async fn expand_substitutes_arguments_placeholder() {
        let root = tempfile::tempdir().unwrap();
        let cwd = root.path();
        write_skill(
            cwd,
            ".devin/skills/gen",
            "SKILL.md",
            "---\nname: gen\n---\nGenerate $ARGUMENTS now.\n",
        );
        let out = expand_skill_prompt("/gen a widget", cwd, cwd).await;
        assert_eq!(out, "Generate a widget now.");
    }

    #[tokio::test]
    async fn expand_passes_through_unknown_commands() {
        let root = tempfile::tempdir().unwrap();
        let cwd = root.path();
        assert_eq!(
            expand_skill_prompt("/not-a-skill x", cwd, cwd).await,
            "/not-a-skill x"
        );
        assert_eq!(expand_skill_prompt("hello", cwd, cwd).await, "hello");
    }
}
