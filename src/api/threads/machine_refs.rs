//! Machine references: `@`-picked machines the user wants the agent to
//! remote-control over VNC.
//!
//! The frontend sends machine ids in the `machine_ids` multipart field (a
//! JSON array of integers). Each id is resolved against the machines table
//! and recorded in the message's attachment metadata so it renders as a
//! chip. The provider prompt gains a control block with the endpoint URLs
//! and the run-scoped token — never the VNC password, which stays
//! server-side in the control endpoints.

use std::collections::HashSet;

use crate::db::machines::MachineRow;
use crate::AppState;

use super::send::SendInput;

/// Maximum number of machine references accepted per message.
const MAX_MACHINE_REFS: usize = 8;

/// Parse the `machine_ids` multipart field: a JSON array of integer ids,
/// deduplicated in arrival order.
pub(crate) fn parse_machine_ids(raw: &str) -> Result<Vec<i64>, String> {
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|_| "invalid machine_ids".to_string())?;
    let items = value
        .as_array()
        .ok_or_else(|| "invalid machine_ids".to_string())?;
    if items.len() > MAX_MACHINE_REFS {
        return Err(format!(
            "too many machine references (max {MAX_MACHINE_REFS})"
        ));
    }
    let mut seen = HashSet::new();
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let id = item
            .as_i64()
            .ok_or_else(|| "invalid machine_ids".to_string())?;
        if id <= 0 {
            return Err("invalid machine_ids".to_string());
        }
        if seen.insert(id) {
            out.push(id);
        }
    }
    Ok(out)
}

/// Resolve `input.machine_ids` into `input.machine_refs`. Machines that no
/// longer exist are dropped silently — the composer may hold a stale id —
/// and each survivor is recorded in `input.att_meta` as a `machine` chip.
pub(crate) async fn resolve_machine_refs(state: &AppState, input: &mut SendInput) {
    // Dedupe and cap again: a multipart body may repeat the field and skip
    // the per-field limit in the parser.
    let mut seen = HashSet::new();
    let ids: Vec<i64> = std::mem::take(&mut input.machine_ids)
        .into_iter()
        .filter(|id| seen.insert(*id))
        .take(MAX_MACHINE_REFS)
        .collect();
    for id in ids {
        let Ok(Some(machine)) = state.db.get_machine(id).await else {
            continue;
        };
        input.att_meta.push(serde_json::json!({
            "filename": machine.name,
            "mime": "application/x-devinorium-machine",
            "size": 0,
            "kind": "machine",
            "machine_id": machine.id,
        }));
        input.machine_refs.push(machine);
    }
}

/// Build the prompt sent to the provider: the user's text plus a block
/// describing how to drive each referenced machine through the local
/// machine-control API. The token authorizes exactly these machines and
/// dies with the run.
pub(crate) fn prompt_with_machine_refs(
    prompt: &str,
    refs: &[MachineRow],
    token: Option<&str>,
    base_url: &str,
) -> String {
    if refs.is_empty() {
        return prompt.to_string();
    }
    let mut out = String::with_capacity(prompt.len() + refs.len() * 256 + 1024);
    let trimmed = prompt.trim_end();
    if !trimmed.is_empty() {
        out.push_str(trimmed);
        out.push_str("\n\n");
    }
    out.push_str("The user referenced these machines for remote control (VNC):");
    for m in refs {
        out.push_str("\n- \"");
        out.push_str(&m.name);
        out.push_str("\" (id ");
        out.push_str(&m.id.to_string());
        out.push_str(", ");
        out.push_str(&m.host);
        out.push(':');
        out.push_str(&m.port.to_string());
        out.push(')');
    }
    match token {
        Some(token) => {
            out.push_str(
                "\n\nControl them through the Devinorium machine-control API on this host. \
                 The token below covers only the referenced machines and expires when this turn ends.\n",
            );
            out.push_str(&format!(
                "Authorization: Bearer {token}\nBase URL: {base_url}\n\n\
                 Screenshot (PNG, framebuffer pixels):\n  \
                 curl -sS -H \"Authorization: Bearer {token}\" \
                 {base_url}/api/machine-control/<id>/screenshot -o /tmp/machine-<id>.png\n\
                 Input:\n  \
                 curl -sS -X POST -H \"Authorization: Bearer {token}\" \
                 -H \"Content-Type: application/json\" \
                 {base_url}/api/machine-control/<id>/input -d '<json>'\n\n\
                 Input kinds:\n  \
                 {{\"kind\":\"move\",\"x\":0,\"y\":0}}\n  \
                 {{\"kind\":\"click\",\"x\":0,\"y\":0,\"button\":\"left|middle|right\"}}\n  \
                 {{\"kind\":\"key\",\"key\":\"a|Return|ctrl+c|ctrl+alt+del\"}}\n  \
                 {{\"kind\":\"type\",\"text\":\"text to type\"}}\n  \
                 {{\"kind\":\"scroll\",\"x\":0,\"y\":0,\"dy\":3}}\n\n\
                 Take a screenshot first to learn the layout, then act on it. \
                 The VNC password is never exposed; the API authenticates for you."
            ));
        }
        None => {
            out.push_str(
                "\n\nNo machine-control token was issued for this turn; \
                 tell the user the machines could not be attached.",
            );
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn machine(id: i64, name: &str) -> MachineRow {
        MachineRow {
            id,
            name: name.into(),
            host: "192.168.1.10".into(),
            port: 5900,
            password: "secret".into(),
            created_at: String::new(),
            updated_at: String::new(),
        }
    }

    #[test]
    fn parse_machine_ids_accepts_int_array() {
        let ids = parse_machine_ids("[1, 2, 2, 3]").unwrap();
        assert_eq!(ids, [1, 2, 3]);
    }

    #[test]
    fn parse_machine_ids_rejects_malformed() {
        assert!(parse_machine_ids("not json").is_err());
        assert!(parse_machine_ids(r#"{"id":1}"#).is_err());
        assert!(parse_machine_ids(r#"["1"]"#).is_err());
        assert!(parse_machine_ids("[0]").is_err());
        assert!(parse_machine_ids("[-3]").is_err());
        let many: Vec<i64> = (1..=(MAX_MACHINE_REFS as i64 + 1)).collect();
        assert!(parse_machine_ids(&serde_json::to_string(&many).unwrap()).is_err());
    }

    #[test]
    fn prompt_includes_endpoints_but_never_password() {
        let refs = vec![machine(3, "gaming pc")];
        let out =
            prompt_with_machine_refs("reboot it", &refs, Some("mc_tok"), "http://127.0.0.1:7878");
        assert!(out.starts_with("reboot it\n\n"));
        assert!(out.contains("\"gaming pc\" (id 3, 192.168.1.10:5900)"));
        assert!(out.contains("Bearer mc_tok"));
        assert!(out.contains("/api/machine-control/"));
        assert!(!out.contains("secret"));
    }

    #[test]
    fn prompt_without_token_still_lists_machines() {
        let refs = vec![machine(1, "m")];
        let out = prompt_with_machine_refs("", &refs, None, "http://x");
        assert!(out.contains("\"m\" (id 1"));
        assert!(out.contains("No machine-control token"));
        assert_eq!(prompt_with_machine_refs("hi", &[], None, "http://x"), "hi");
    }
}
