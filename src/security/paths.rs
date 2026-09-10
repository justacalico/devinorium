//! Path safety: prevent path traversal while allowing any absolute path.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// Names that the file manager must hide and protect from user actions.
pub const HIDDEN_NAMES: &[&str] = &[".devinorium-attachments", ".git"];

fn is_hidden_os(name: &OsStr) -> bool {
    HIDDEN_NAMES.iter().any(|&h| name == OsStr::new(h))
}

/// Check whether a single file or directory name is hidden.
pub fn is_hidden_name(name: &str) -> bool {
    HIDDEN_NAMES.contains(&name)
}

/// Check whether any component of `path` is a hidden name.
pub fn is_hidden_path(path: &Path) -> bool {
    path.components().any(|c| is_hidden_os(c.as_os_str()))
}

/// Check whether the part of `target` that extends beyond `root` contains a
/// hidden name. Falls back to checking the full `target` when it is not under
/// `root` (e.g. an absolute path resolved without sandboxing).
pub fn is_hidden_within(root: &Path, target: &Path) -> bool {
    match target.strip_prefix(root) {
        Ok(suffix) => is_hidden_path(suffix),
        Err(_) => is_hidden_path(target),
    }
}

/// Normalize a user-supplied path string.
///
/// Strips surrounding quotes and expands a leading `~` to the given home
/// directory. The result may still be relative; callers should validate and
/// resolve as needed.
pub fn normalize_path(path: &str, home: &Path) -> String {
    let mut s = path.trim().to_string();

    // Strip matching surrounding quotes, e.g. "/path/with spaces" or '/path'.
    if let Some(inner) = s.strip_prefix('"').and_then(|s| s.strip_suffix('"')) {
        s = inner.to_string();
    } else if let Some(inner) = s.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')) {
        s = inner.to_string();
    }

    // Expand a leading `~` to the home directory.
    if s == "~" || s == "~/" || s == "~\\" {
        s = home.to_string_lossy().to_string();
    } else if s.starts_with("~/") || s.starts_with("~\\") {
        let sep = if s.starts_with("~/") { '/' } else { '\\' };
        let rest = s[2..].trim_start_matches(sep);
        s = if rest.is_empty() {
            home.to_string_lossy().to_string()
        } else {
            home.join(rest).to_string_lossy().to_string()
        };
    }

    s
}

/// Resolve `path` to a canonicalized absolute path.
///
/// `base` is an optional directory used to resolve relative paths. If `path`
/// is absolute, `base` is ignored.
///
/// When `roots` is `None` the path is not sandboxed; it is only verified that
/// it does not escape via `..` through a non-existent directory.
///
/// When `roots` is `Some` the canonicalized path must be contained within one
/// of the given roots.
pub fn resolve(path: &Path, base: Option<&Path>, roots: Option<&[PathBuf]>) -> Option<PathBuf> {
    // First, join with base if relative and base is set.
    let joined = if path.is_relative() {
        base?.join(path)
    } else {
        path.to_path_buf()
    };

    // Canonicalize. If the path doesn't exist yet (e.g. creating a file or
    // uploading into a not-yet-created subdirectory), walk up to the first
    // existing ancestor, canonicalize it, then re-append the remaining components.
    let canon = match joined.canonicalize() {
        Ok(c) => c,
        Err(_) => {
            // Collect non-existent trailing components. Reject `..` to prevent
            // traversal: a `..` in the non-existent tail means the path is
            // trying to escape through a non-existent directory.
            let mut existing = joined.clone();
            let mut tail: Vec<std::ffi::OsString> = Vec::new();
            while !existing.exists() {
                let name = existing.file_name()?;
                // Reject parent-dir components in the tail — these indicate
                // traversal through non-existent directories.
                if name == ".." || name == "." {
                    return None;
                }
                tail.push(name.to_os_string());
                existing = existing.parent()?.to_path_buf();
            }
            let mut canon = existing.canonicalize().ok()?;
            for name in tail.iter().rev() {
                canon = canon.join(name);
            }
            canon
        }
    };

    if let Some(roots) = roots {
        for root in roots {
            if let Ok(root_canon) = root.canonicalize() {
                if canon == root_canon || canon.starts_with(&root_canon) {
                    return Some(canon);
                }
            }
        }
        None
    } else {
        Some(canon)
    }
}

/// Resolve `path` and require it to be contained within one of `roots`.
pub fn resolve_within(path: &Path, base: Option<&Path>, roots: &[PathBuf]) -> Option<PathBuf> {
    resolve(path, base, Some(roots))
}

/// Check that `child` (already canonicalized) is within `parent` (canonicalized).
pub fn is_within(child: &Path, parent: &Path) -> bool {
    child == parent || child.starts_with(parent)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hidden_name_matches_exactly() {
        assert!(is_hidden_name(".git"));
        assert!(is_hidden_name(".devinorium-attachments"));
        assert!(!is_hidden_name(".gitignore"));
        assert!(!is_hidden_name(".Git"));
        assert!(!is_hidden_name("git"));
    }

    #[test]
    fn hidden_path_checks_any_component() {
        assert!(is_hidden_path(Path::new("/project/.git")));
        assert!(is_hidden_path(Path::new("/project/.git/config")));
        assert!(is_hidden_path(Path::new(
            "/project/.devinorium-attachments"
        )));
        assert!(!is_hidden_path(Path::new("/project/.gitignore")));
        assert!(!is_hidden_path(Path::new("/project/src/main.rs")));
    }

    #[test]
    fn hidden_within_allows_root_and_rejects_suffix() {
        let root = Path::new("/project");
        assert!(!is_hidden_within(root, Path::new("/project")));
        assert!(!is_hidden_within(root, Path::new("/project/src")));
        assert!(!is_hidden_within(
            Path::new("/project.git"),
            Path::new("/project.git/src"),
        ));
        assert!(is_hidden_within(root, Path::new("/project/.git")));
        assert!(is_hidden_within(root, Path::new("/project/.git/config")));
        assert!(is_hidden_within(
            root,
            Path::new("/project/sub/.devinorium-attachments"),
        ));
    }

    #[test]
    fn rejects_traversal_outside_root() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let root = tmp.clone();
        let roots = vec![root.clone()];
        // Try to escape via ..
        let evil = root.join("..").join("etc").join("passwd");
        assert!(resolve_within(&evil, None, &roots).is_none());
    }

    #[test]
    fn accepts_path_within_root() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let sub = tmp.join("sub");
        std::fs::create_dir_all(&sub).unwrap();
        let roots = vec![tmp.clone()];
        let resolved = resolve_within(&sub, None, &roots);
        assert!(resolved.is_some());
    }

    #[test]
    fn accepts_relative_within_base() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let file = tmp.join("hello.txt");
        std::fs::write(&file, "hi").unwrap();
        let roots = vec![tmp.clone()];
        let resolved = resolve_within(Path::new("hello.txt"), Some(&tmp), &roots);
        assert!(resolved.is_some());
    }

    #[test]
    fn accepts_nested_nonexistent_path() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let roots = vec![tmp.clone()];
        // subdir/deep/file.txt — none of these exist yet.
        let resolved = resolve_within(Path::new("subdir/deep/file.txt"), Some(&tmp), &roots);
        assert!(
            resolved.is_some(),
            "nested non-existent path should resolve"
        );
        let resolved = resolved.unwrap();
        assert!(resolved.starts_with(&tmp));
        assert!(resolved.ends_with("subdir/deep/file.txt"));
    }

    #[test]
    fn rejects_traversal_through_nonexistent_dir() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let roots = vec![tmp.clone()];
        // fakedir/../../etc — fakedir doesn't exist, so the `..` would
        // escape through a non-existent directory.
        let resolved = resolve_within(Path::new("fakedir/../../etc"), Some(&tmp), &roots);
        assert!(
            resolved.is_none(),
            "traversal through non-existent dir should be rejected"
        );
    }

    #[test]
    fn resolve_accepts_absolute_paths() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let sub = tmp.join("sub");
        std::fs::create_dir_all(&sub).unwrap();
        let resolved = resolve(&sub, None, None);
        assert!(resolved.is_some());
        assert!(resolved.unwrap().starts_with(&tmp));
    }

    #[test]
    fn resolve_accepts_paths_with_spaces() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let sub = tmp.join("my dir").join("my app");
        std::fs::create_dir_all(&sub).unwrap();
        let resolved = resolve(&sub, None, None);
        assert!(resolved.is_some());
        let resolved = resolved.unwrap();
        assert!(resolved.to_string_lossy().contains("my dir"));
        assert!(resolved.to_string_lossy().contains("my app"));
    }
}
