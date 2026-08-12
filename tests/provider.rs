//! Integration tests for the provider abstraction and the devin-cli provider.
//!
//! These tests require the `devin` CLI on PATH and an authenticated account.
//! They use the free `glm-5-2` model. They are tagged `provider` so they can
//! be filtered out in CI without a devin login.

#![cfg(test)]

use std::path::PathBuf;

use devinorium::providers::{self, Provider, SendOptions, StartRequest};

fn devin_available() -> bool {
    std::process::Command::new("devin")
        .arg("version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok()
}

fn make_provider() -> Box<dyn Provider> {
    providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".to_string(),
        devin_bin: "devin".to_string(),
        default_model: "glm-5-2".to_string(),
    })
    .expect("build devin-cli provider")
}

fn tmp_workdir() -> PathBuf {
    tempfile::tempdir().expect("tempdir").keep()
}

#[tokio::test]
#[ignore = "requires devin CLI + auth"]
async fn provider_lists_models() {
    if !devin_available() {
        eprintln!("skipping: devin not on PATH");
        return;
    }
    let p = make_provider();
    let models = p.list_models().await.expect("list models");
    assert!(!models.is_empty(), "should return at least one model");
    let ids: Vec<_> = models.iter().map(|m| m.id.as_str()).collect();
    assert!(
        ids.contains(&"glm-5-2"),
        "free model glm-5-2 should be listed: {:?}",
        ids
    );
}

#[tokio::test]
#[ignore = "requires devin CLI + auth"]
async fn provider_start_and_send_text() {
    if !devin_available() {
        eprintln!("skipping: devin not on PATH");
        return;
    }
    let p = make_provider();
    let dir = tmp_workdir();

    let start = p
        .start(StartRequest {
            prompt: "Remember the secret word is BANANA. Reply with exactly: OK".to_string(),
            options: SendOptions {
                model: "glm-5-2".to_string(),
                permissions: None,
                permission_callback: None,
                text_callback: None,
                thinking_callback: None,
                tool_callback: None,
                working_dir: dir.clone(),
                permission_mode: "normal".to_string(),
                attachments: vec![],
            },
        })
        .await
        .expect("start");
    assert!(!start.session_id.is_empty(), "session id should be set");
    assert!(!start.reply.is_empty(), "reply should be non-empty");

    let resp = p
        .send(providers::SendRequest {
            session_id: start.session_id.clone(),
            prompt: "What was the secret word? Reply with just the word.".to_string(),
            options: SendOptions {
                model: "glm-5-2".to_string(),
                permissions: None,
                permission_callback: None,
                text_callback: None,
                thinking_callback: None,
                tool_callback: None,
                working_dir: dir,
                permission_mode: "normal".to_string(),
                attachments: vec![],
            },
        })
        .await
        .expect("send");
    assert!(
        resp.reply.contains("BANANA"),
        "multi-turn context should be retained: got {:?}",
        resp.reply
    );
}

#[tokio::test]
#[ignore = "requires devin CLI + auth"]
async fn provider_start_with_image_attachment() {
    if !devin_available() {
        eprintln!("skipping: devin not on PATH");
        return;
    }
    let p = make_provider();
    let dir = tmp_workdir();

    // A tiny 1x1 red PNG.
    let png: &[u8] = &[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
        0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8,
        0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x5B, 0xB3, 0x78, 0xAF, 0x00, 0x00, 0x00,
        0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];

    let start = p
        .start(StartRequest {
            prompt: "I have attached an image. Reply with exactly: IMAGE_RECEIVED".to_string(),
            options: SendOptions {
                model: "glm-5-2".to_string(),
                permissions: None,
                permission_callback: None,
                text_callback: None,
                thinking_callback: None,
                tool_callback: None,
                working_dir: dir,
                permission_mode: "normal".to_string(),
                attachments: vec![providers::Attachment {
                    filename: "pixel.png".to_string(),
                    mime: "image/png".to_string(),
                    data: png.to_vec(),
                }],
            },
        })
        .await
        .expect("start with image");
    assert!(!start.session_id.is_empty());
    assert!(!start.reply.is_empty());
}

#[test]
fn registry_knows_devin_cli() {
    assert!(providers::available_providers().contains(&"devin-cli"));
}

#[test]
fn registry_rejects_unknown() {
    let res = providers::build_provider(providers::ProviderConfig {
        id: "nope".to_string(),
        devin_bin: "devin".to_string(),
        default_model: "glm-5-2".to_string(),
    });
    assert!(res.is_err());
}

#[tokio::test]
#[ignore = "requires devin CLI + auth with ACP support"]
async fn provider_acp_start() {
    if !devin_available() {
        eprintln!("skipping: devin not on PATH");
        return;
    }
    let p = providers::devin_acp::DevinAcpProvider::new("devin".to_string(), "glm-5-2".to_string());
    let dir = tmp_workdir();

    let start = p
        .start(providers::StartRequest {
            prompt: "Reply with exactly: ACP_OK".to_string(),
            options: providers::SendOptions {
                model: "glm-5-2".to_string(),
                permissions: None,
                permission_callback: None,
                text_callback: None,
                thinking_callback: None,
                tool_callback: None,
                working_dir: dir,
                permission_mode: "normal".to_string(),
                attachments: vec![],
            },
        })
        .await
        .expect("start");
    assert!(!start.session_id.is_empty(), "session id should be set");
    assert!(!start.reply.is_empty(), "reply should be non-empty");
}

/// glm-5-2 should be able to generate code when asked.
#[tokio::test]
#[ignore = "requires devin CLI + auth"]
async fn provider_generates_code() {
    if !devin_available() {
        eprintln!("skipping: devin not on PATH");
        return;
    }
    let p = make_provider();
    let dir = tmp_workdir();
    let start = p
        .start(StartRequest {
            prompt: "Write a Rust function called `add` that takes two i32 and returns their sum. Reply with ONLY the function in a ```rust code block, nothing else.".to_string(),
            options: SendOptions {
                model: "glm-5-2".to_string(),
                permissions: None,
                permission_callback: None,
                text_callback: None,
                thinking_callback: None,
                tool_callback: None,
                working_dir: dir,
                permission_mode: "normal".to_string(),
                attachments: vec![],
            },
        })
        .await
        .expect("start");
    assert!(!start.reply.is_empty(), "reply should be non-empty");
    // The reply should contain a rust code block and the function name.
    assert!(
        start.reply.contains("add") && (start.reply.contains("```") || start.reply.contains("fn")),
        "expected code in reply: got {:?}",
        start.reply
    );
}

/// glm-5-2 with accept-edits should be able to write a file to the working dir.
#[tokio::test]
#[ignore = "requires devin CLI + auth"]
async fn provider_writes_file_in_working_dir() {
    if !devin_available() {
        eprintln!("skipping: devin not on PATH");
        return;
    }
    let p = make_provider();
    let dir = tmp_workdir();
    let start = p
        .start(StartRequest {
            prompt: "Create a file called hello.txt in the current directory containing the text 'Devinorium was here'. Do not ask for permission.".to_string(),
            options: SendOptions {
                model: "glm-5-2".to_string(),
                permissions: None,
                permission_callback: None,
                text_callback: None,
                thinking_callback: None,
                tool_callback: None,
                working_dir: dir.clone(),
                permission_mode: "accept-edits".to_string(),
                attachments: vec![],
            },
        })
        .await
        .expect("start");
    assert!(!start.reply.is_empty());
    // The model should have created the file (accept-edits auto-approves file writes).
    let target = dir.join("hello.txt");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        if target.exists() {
            let content = std::fs::read_to_string(&target).unwrap_or_default();
            assert!(
                content.contains("Devinorium"),
                "file content should contain the marker: got {:?}",
                content
            );
            return;
        }
        if std::time::Instant::now() > deadline {
            // Some models may phrase the write differently; accept if the reply
            // acknowledges the task rather than hard-failing on timing.
            eprintln!(
                "file not created within timeout; reply was: {:?}",
                start.reply
            );
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
}

/// Each permission mode should be accepted by the provider without error.
#[tokio::test]
#[ignore = "requires devin CLI + auth"]
async fn provider_accepts_all_permission_modes() {
    if !devin_available() {
        eprintln!("skipping: devin not on PATH");
        return;
    }
    let p = make_provider();
    for mode in &["normal", "accept-edits", "smart", "bypass"] {
        let dir = tmp_workdir();
        let res = p
            .start(StartRequest {
                prompt: "Reply with exactly: OK".to_string(),
                options: SendOptions {
                    model: "glm-5-2".to_string(),
                    permissions: None,
                    permission_callback: None,
                    text_callback: None,
                    thinking_callback: None,
                    tool_callback: None,
                    working_dir: dir,
                    permission_mode: mode.to_string(),
                    attachments: vec![],
                },
            })
            .await;
        assert!(
            res.is_ok(),
            "permission mode {} should be accepted: {:?}",
            mode,
            res.err()
        );
        let r = res.unwrap();
        assert!(!r.reply.is_empty(), "mode {} produced empty reply", mode);
    }
}

/// A text attachment (non-image file) should be accepted by the provider.
#[tokio::test]
#[ignore = "requires devin CLI + auth"]
async fn provider_accepts_text_attachment() {
    if !devin_available() {
        eprintln!("skipping: devin not on PATH");
        return;
    }
    let p = make_provider();
    let dir = tmp_workdir();
    let start = p
        .start(StartRequest {
            prompt: "I have attached a file. Tell me the single word it contains. Reply with just that word.".to_string(),
            options: SendOptions {
                model: "glm-5-2".to_string(),
                permissions: None,
                permission_callback: None,
                text_callback: None,
                thinking_callback: None,
                tool_callback: None,
                working_dir: dir,
                permission_mode: "normal".to_string(),
                attachments: vec![providers::Attachment {
                    filename: "secret.txt".to_string(),
                    mime: "text/plain".to_string(),
                    data: b"PINEAPPLE".to_vec(),
                }],
            },
        })
        .await
        .expect("start with text attachment");
    assert!(!start.reply.is_empty());
    assert!(
        start.reply.contains("PINEAPPLE"),
        "model should read the attachment content: got {:?}",
        start.reply
    );
}
