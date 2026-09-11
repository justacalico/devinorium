//! First-run bootstrap: create the initial owner account from env config.
//!
//! The owner is just a `user`-role account — there is no admin role. The first
//! user created when the user table is empty is marked as owner so they can
//! manage accounts without an invite system.

use tracing::info;

use crate::db::NewUser;

use super::password;

/// Username of the passwordless account used when the server runs in bundled
/// local mode (`DEVINORIUM_LOCAL_TOKEN`).
pub const LOCAL_USERNAME: &str = "local";

/// Password hash stored for the local-mode account. It is deliberately not a
/// valid argon2 encoding, so `password::verify` always fails on it and
/// interactive login is impossible. Also used to recognize accounts this
/// code created.
const LOCAL_PASSWORD_SENTINEL: &str = "!local-mode";

/// If no users exist and a bootstrap password is configured, create the
/// bootstrap user and mark them as owner. Idempotent.
pub async fn run(db: &crate::db::Db, username: &str, password_str: &str) -> anyhow::Result<()> {
    let count = db.count_users().await?;
    if count > 0 {
        return Ok(());
    }
    if username.is_empty() || password_str.is_empty() {
        tracing::warn!("bootstrap skipped: empty username or password");
        return Ok(());
    }
    if password_str == "change-me-to-a-strong-password" {
        tracing::warn!("bootstrap skipped: default password not changed");
        return Ok(());
    }
    let hash = password::hash(password_str)?;
    let user = db
        .create_user(NewUser {
            username: username.to_string(),
            password_hash: hash,
            is_owner: false,
        })
        .await?;
    db.set_user_owner(user.id, true).await?;
    info!(username, "bootstrap owner account created");
    Ok(())
}

/// Ensure the local-mode account exists. Its password hash is a sentinel that
/// can never verify, so interactive login is impossible; requests carrying
/// the configured local token are mapped onto this user by the middleware.
pub async fn run_local(db: &crate::db::Db) -> anyhow::Result<()> {
    if let Some(existing) = db.get_user_by_username(LOCAL_USERNAME).await? {
        if existing.password_hash == LOCAL_PASSWORD_SENTINEL {
            // A row we created that lost its owner flag would silently break
            // owner-only routes like the terminal, so re-assert it. A `local`
            // row with a real password hash is not ours — promote nothing.
            if !existing.is_owner {
                db.set_user_owner(existing.id, true).await?;
            }
        } else {
            tracing::warn!(
                "a regular user named 'local' already exists; the bundled token \
                 will authenticate as it, but owner-only features may fail"
            );
        }
        return Ok(());
    }
    let user = db
        .create_user(NewUser {
            username: LOCAL_USERNAME.to_string(),
            password_hash: LOCAL_PASSWORD_SENTINEL.to_string(),
            is_owner: false,
        })
        .await?;
    db.set_user_owner(user.id, true).await?;
    info!(username = LOCAL_USERNAME, "local-mode account created");
    Ok(())
}
