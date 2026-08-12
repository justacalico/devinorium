//! Path safety: constrain file operations to configured file roots and
//! prevent path traversal.

use std::path::{Path, PathBuf};

/// Resolve `path` (which may be relative or contain `..`) and verify that the
/// canonicalized result is contained within one of `roots`.
///
/// `base` is an optional already-validated file root directory to resolve
/// relative paths against.
///
/// Returns the canonicalized absolute path if it is within a root, else None.
pub fn resolve_within(path: &Path, base: Option<&Path>, roots: &[PathBuf]) -> Option<PathBuf> {
    // First, join with base if relative and base is set.
    let joined = if path.is_relative() {
        match base {
            Some(b) => b.join(path),
            None => return None,
        }
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

    for root in roots {
        if let Ok(root_canon) = root.canonicalize() {
            if canon == root_canon || canon.starts_with(&root_canon) {
                return Some(canon);
            }
        }
    }
    None
}

/// Check that `child` (already canonicalized) is within `parent` (canonicalized).
pub fn is_within(child: &Path, parent: &Path) -> bool {
    child == parent || child.starts_with(parent)
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let resolved = resolve_within(
            Path::new("subdir/deep/file.txt"),
            Some(&tmp),
            &roots,
        );
        assert!(resolved.is_some(), "nested non-existent path should resolve");
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
        let resolved = resolve_within(
            Path::new("fakedir/../../etc"),
            Some(&tmp),
            &roots,
        );
        assert!(resolved.is_none(), "traversal through non-existent dir should be rejected");
    }
}
