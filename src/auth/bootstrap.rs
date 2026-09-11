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

/// Ensure the local-mode account exists. Its password is random so
/// interactive login is impossible; requests carrying the configured local
/// token are mapped onto this user by the auth middleware.
pub async fn run_local(db: &crate::db::Db) -> anyhow::Result<()> {
    if let Some(existing) = db.get_user_by_username(LOCAL_USERNAME).await? {
        // A pre-existing `local` row that lost its owner flag would silently
        // break owner-only routes like the terminal, so re-assert it.
        if !existing.is_owner {
            db.set_user_owner(existing.id, true).await?;
        }
        return Ok(());
    }
    let hash = password::hash(&random_secret())?;
    let user = db
        .create_user(NewUser {
            username: LOCAL_USERNAME.to_string(),
            password_hash: hash,
            is_owner: false,
        })
        .await?;
    db.set_user_owner(user.id, true).await?;
    info!(username = LOCAL_USERNAME, "local-mode account created");
    Ok(())
}

fn random_secret() -> String {
    use rand::RngCore;
    let mut buf = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut buf);
    hex::encode(buf)
}
