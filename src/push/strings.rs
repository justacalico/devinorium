//! Notification text for push payloads.
//!
//! The client records its locale on the subscription at subscribe time; the
//! service worker renders `title`/`body` verbatim, so localization happens
//! here. Only locales the app ships are needed — anything else falls back to
//! English.

use super::PushKind;

/// (title, body) for a push of `kind` about `thread_title` in `lang`.
pub fn render(kind: PushKind, lang: &str, thread_title: &str) -> (String, String) {
    let zh = lang.to_ascii_lowercase().starts_with("zh");
    match (kind, zh) {
        (PushKind::Completed, false) => (
            "Thread finished".into(),
            format!("{thread_title} has finished running."),
        ),
        (PushKind::Completed, true) => ("会话完成".into(), format!("{thread_title} 已运行完成")),
        (PushKind::Failed, false) => (
            "Thread failed".into(),
            format!("{thread_title} encountered an error."),
        ),
        (PushKind::Failed, true) => ("会话失败".into(), format!("{thread_title} 遇到错误")),
        (PushKind::Permission, false) => (
            "Approval needed".into(),
            format!("{thread_title} is waiting for a permission decision."),
        ),
        (PushKind::Permission, true) => (
            "需要审批".into(),
            format!("{thread_title} 正在等待权限确认"),
        ),
        (PushKind::Ask, false) => (
            "Question from agent".into(),
            format!("{thread_title} is waiting for answers."),
        ),
        (PushKind::Ask, true) => ("代理在提问".into(), format!("{thread_title} 正在等待回答")),
        (PushKind::Test, false) => (
            "Devinorium test".into(),
            "Push notifications are working.".into(),
        ),
        (PushKind::Test, true) => ("测试通知".into(), "推送通知工作正常。".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_every_kind_in_both_locales() {
        for kind in [
            PushKind::Completed,
            PushKind::Failed,
            PushKind::Permission,
            PushKind::Ask,
            PushKind::Test,
        ] {
            for lang in ["en", "zh", "zh-CN", "fr"] {
                let (t, b) = render(kind, lang, "T");
                assert!(!t.is_empty() && !b.is_empty());
            }
        }
        let (zh_title, _) = render(PushKind::Completed, "zh-CN", "x");
        assert!(zh_title.contains('会'));
        let (en_title, _) = render(PushKind::Completed, "fr", "x");
        assert_eq!(en_title, "Thread finished");
    }
}
