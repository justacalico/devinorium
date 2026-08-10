//! Path safety: constrain file operations to configured workspace roots and
//! prevent path traversal.

use std::path::{Path, PathBuf};

/// Resolve `path` (which may be relative or contain `..`) and verify that the
/// canonicalized result is contained within one of `roots`.
///
/// `base` is an optional already-validated workspace directory to resolve
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

    // Canonicalize. If the path doesn't exist yet (e.g. creating a file),
    // canonicalize the parent and append the file name.
    let canon = match joined.canonicalize() {
        Ok(c) => c,
        Err(_) => {
            let parent = joined.parent()?;
            let parent_canon = parent.canonicalize().ok()?;
            match joined.file_name() {
                Some(name) => parent_canon.join(name),
                None => return None,
            }
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
    use std::path::PathBuf;

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
}
