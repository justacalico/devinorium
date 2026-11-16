//! Filesystem scope for non-owner users.
//!
//! Owners keep unrestricted filesystem access through the API; everyone else
//! is confined to an authorized root set: their own projects plus the shared
//! managed directories (project root, worktree root, clone root). Sensitive
//! credential locations and the server's own database are always excluded.

use std::path::{Path, PathBuf};

use crate::db::UserRow;
use crate::security::paths;
use crate::AppState;

/// The shared managed directories: where new project folders, worktrees, and
/// clones land. Owners configure them; the values resolve through the owner's
/// row for non-owners.
async fn managed_roots(state: &AppState, user_id: i64) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(root) = crate::api::settings::project_root(state, user_id).await {
        roots.push(root);
    }
    if let Ok(root) = crate::api::settings::worktree_root(state, user_id).await {
        roots.push(root);
    }
    if let Ok(Some(configured)) = state.db.get_clone_root(user_id).await {
        let normalized = paths::normalize_path(&configured, &state.config.home_dir);
        if let Some(root) = paths::resolve(Path::new(&normalized), None, None) {
            roots.push(root);
        }
    }
    roots
}

/// Every root a non-owner may reach: managed directories plus each of the
/// user's own registered projects.
pub(crate) async fn non_owner_roots(state: &AppState, user: &UserRow) -> Vec<PathBuf> {
    let mut roots = managed_roots(state, user.id).await;
    if let Ok(projects) = state.db.list_projects(user.id, None, 0).await {
        roots.extend(projects.into_iter().map(|p| PathBuf::from(p.path)));
    }
    roots
}

/// Managed roots only — used to gate non-owner project registration so a
/// project cannot point at arbitrary host paths.
pub(crate) async fn non_owner_managed_roots(state: &AppState, user_id: i64) -> Vec<PathBuf> {
    managed_roots(state, user_id).await
}

/// Extract the database file path from a sqlite connection URL, or `None`
/// for in-memory and non-sqlite URLs.
fn db_path_from_url(url: &str) -> Option<PathBuf> {
    let rest = url.strip_prefix("sqlite:")?;
    let without_query = rest.split('?').next().unwrap_or("");
    let path = without_query.strip_prefix("//").unwrap_or(without_query);
    if path.is_empty() || path == ":memory:" {
        return None;
    }
    Some(PathBuf::from(path))
}

/// Paths that hold the server's own database (main file plus WAL/SHM/journal
/// sidecars). Empty for in-memory databases and non-sqlite URLs.
pub(crate) fn db_file_paths(state: &AppState) -> Vec<PathBuf> {
    let Some(p) = db_path_from_url(&state.config.db_url) else {
        return Vec::new();
    };
    let p = if p.is_relative() {
        std::env::current_dir().map(|d| d.join(&p)).unwrap_or(p)
    } else {
        p
    };
    let canon = p.canonicalize().unwrap_or(p);
    let mut out = vec![canon.clone()];
    for suffix in ["-wal", "-shm", "-journal"] {
        out.push(PathBuf::from(format!("{}{suffix}", canon.display())));
    }
    out
}

/// Whether `resolved` (a canonical path) is off-limits to a non-owner:
/// outside every authorized root, inside a credential location, or the
/// server's own database file.
pub(crate) fn outside_scope(resolved: &Path, roots: &[PathBuf], db_files: &[PathBuf]) -> bool {
    if db_files.iter().any(|db| same_file(resolved, db)) {
        return true;
    }
    if paths::has_sensitive_component(resolved) {
        return true;
    }
    !roots.iter().any(|root| paths::is_within(resolved, root))
}

/// Path equality plus inode identity: a hardlink to the database inside an
/// authorized root has a different path but opens the same file.
fn same_file(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let (Ok(ma), Ok(mb)) = (a.metadata(), b.metadata()) else {
            return false;
        };
        ma.dev() == mb.dev() && ma.ino() == mb.ino()
    }
    #[cfg(windows)]
    {
        fn file_identity(path: &Path) -> Option<(u32, u64)> {
            use std::os::windows::io::AsRawHandle;
            use windows_sys::Win32::Storage::FileSystem::{
                GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
            };
            let file = std::fs::File::open(path).ok()?;
            let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
            if unsafe { GetFileInformationByHandle(file.as_raw_handle() as _, &mut info) } == 0 {
                return None;
            }
            Some((
                info.dwVolumeSerialNumber,
                ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64,
            ))
        }
        matches!((file_identity(a), file_identity(b)), (Some(ia), Some(ib)) if ia == ib)
    }
    #[cfg(not(any(unix, windows)))]
    {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn db_url_parsing_handles_all_forms() {
        assert_eq!(
            db_path_from_url("sqlite:/tmp/x.db"),
            Some(PathBuf::from("/tmp/x.db"))
        );
        assert_eq!(
            db_path_from_url("sqlite:///tmp/x.db"),
            Some(PathBuf::from("/tmp/x.db"))
        );
        assert_eq!(
            db_path_from_url("sqlite:data/dev.db?mode=rwc"),
            Some(PathBuf::from("data/dev.db"))
        );
        assert_eq!(
            db_path_from_url("sqlite://data/dev.db"),
            Some(PathBuf::from("data/dev.db"))
        );
        assert_eq!(db_path_from_url("sqlite::memory:"), None);
        assert_eq!(db_path_from_url("sqlite://:memory:"), None);
        assert_eq!(db_path_from_url("postgres://x"), None);
    }

    #[test]
    fn outside_scope_rules() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let db = tmp.join("api.db");
        std::fs::write(&db, b"").unwrap();
        let db = db.canonicalize().unwrap();
        let roots = vec![tmp.join("proj").canonicalize().unwrap_or_else(|_| {
            std::fs::create_dir_all(tmp.join("proj")).unwrap();
            tmp.join("proj").canonicalize().unwrap()
        })];
        let db_files = vec![db.clone()];

        assert!(outside_scope(&db, &roots, &db_files));
        assert!(outside_scope(&db.with_file_name("api.db-wal"), &roots, &[]));
        assert!(outside_scope(Path::new("/etc/hostname"), &roots, &[]));
        assert!(outside_scope(
            &roots[0].join(".ssh/id_rsa"),
            &roots,
            &db_files
        ));
        assert!(!outside_scope(
            &roots[0].join("src/main.rs"),
            &roots,
            &db_files
        ));
    }

    #[cfg(unix)]
    #[test]
    fn outside_scope_catches_hardlink_to_db() {
        let tmp = tempfile::tempdir().unwrap().keep();
        let db = tmp.join("api.db");
        std::fs::write(&db, b"x").unwrap();
        let db = db.canonicalize().unwrap();
        let proj = tmp.join("proj");
        std::fs::create_dir_all(&proj).unwrap();
        let link = proj.join("notes.txt");
        std::fs::hard_link(&db, &link).unwrap();
        let link = link.canonicalize().unwrap();
        let roots = vec![proj.canonicalize().unwrap()];

        assert!(outside_scope(&link, &roots, &[db]));
    }
}
