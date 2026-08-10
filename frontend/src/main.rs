mod api;
mod types;

use dioxus::prelude::*;
use types::*;

// SVG icon paths (Material Design icons)
const ICONS: &[(&str, &str)] = &[
    ("bot", "M12 2A2 2 0 0 0 10 4C10 4.5 10.18 5 10.5 5.35V7H7A5 5 0 0 0 2 12V18A5 5 0 0 0 7 23H17A5 5 0 0 0 22 18V12A5 5 0 0 0 17 7H13.5V5.35C13.82 5 14 4.5 14 4A2 2 0 0 0 12 2M7 9H17A3 3 0 0 1 20 12V18A3 3 0 0 1 17 21H7A3 3 0 0 1 4 18V12A3 3 0 0 1 7 9M8 12A1.5 1.5 0 1 0 8 15A1.5 1.5 0 0 0 8 12M16 12A1.5 1.5 0 1 0 16 15A1.5 1.5 0 0 0 16 12Z"),
    ("menu", "M3 6H21V8H3V6M3 11H21V13H3V11M3 16H21V18H3V16Z"),
    ("dots", "M12 16A2 2 0 1 0 12 20A2 2 0 0 0 12 16M12 10A2 2 0 1 0 12 14A2 2 0 0 0 12 10M12 4A2 2 0 1 0 12 8A2 2 0 0 0 12 4Z"),
    ("plus", "M11 4H13V11H20V13H13V20H11V13H4V11H11V4Z"),
    ("send", "M2 21L23 12L2 3V10L17 12L2 14V21Z"),
    ("paperclip", "M16.5 6V17.5A4 4 0 0 1 12.5 21.5A4 4 0 0 1 8.5 17.5V5A2.5 2.5 0 0 1 11 2.5A2.5 2.5 0 0 1 13.5 5V15.5A1 1 0 0 1 12.5 16.5A1 1 0 0 1 11.5 15.5V6H10V15.5A2.5 2.5 0 0 0 12.5 18A2.5 2.5 0 0 0 15 15.5V5A4 4 0 0 0 11 1A4 4 0 0 0 7 5V17.5A5.5 5.5 0 0 0 12.5 23A5.5 5.5 0 0 0 18 17.5V6H16.5Z"),
    ("folder", "M10 4L12 6H20A2 2 0 0 1 22 8V18A2 2 0 0 1 20 20H4A2 2 0 0 1 2 18V6A2 2 0 0 1 4 4H10Z"),
    ("folder-plus", "M10 4L12 6H20A2 2 0 0 1 22 8V18A2 2 0 0 1 20 20H4A2 2 0 0 1 2 18V6A2 2 0 0 1 4 4H10M11 10V12H8V14H11V16H13V14H16V12H13V10H11Z"),
    ("upload", "M9 16V10H5L12 3L19 10H15V16H9M5 19V21H19V19H5Z"),
    ("close", "M19 6.41L17.59 5L12 10.59L6.41 5L5 6.41L10.59 12L5 17.59L6.41 19L12 13.41L17.59 19L19 17.59L13.41 12L19 6.41Z"),
    ("chat", "M4 4H20A2 2 0 0 1 22 6V16A2 2 0 0 1 20 18H13L9 22V18H4A2 2 0 0 1 2 16V6A2 2 0 0 1 4 4Z"),
    ("trash", "M9 3V4H4V6H5V19A2 2 0 0 0 7 21H17A2 2 0 0 0 19 19V6H20V4H15V3H9M7 6H17V19H7V6M9 8V17H11V8H9M13 8V17H15V8H13Z"),
    ("person", "M12 4A4 4 0 0 0 8 8A4 4 0 0 0 12 12A4 4 0 0 0 16 8A4 4 0 0 0 12 4M12 14C8.67 14 4 15.67 4 19V20H20V19C20 15.67 15.33 14 12 14Z"),
    ("warning", "M12 2L1 21H23L12 2M12 7L19.53 20H4.47L12 7M11 13V17H13V13H11M11 18V20H13V18H11Z"),
    ("eye", "M12 9A3 3 0 0 0 9 12A3 3 0 0 0 12 15A3 3 0 0 0 15 12A3 3 0 0 0 12 9M12 17A5 5 0 0 1 7 12A5 5 0 0 1 12 7A5 5 0 0 1 17 12A5 5 0 0 1 12 17M12 4.5C7 4.5 2.73 7.61 1 12C2.73 16.39 7 19.5 12 19.5C17 19.5 21.27 16.39 23 12C21.27 7.61 17 4.5 12 4.5Z"),
    ("image", "M8.5 13.5L11 16.5L14.5 12L19 18H5L8.5 13.5M22 6V18A2 2 0 0 1 20 20H4A2 2 0 0 1 2 18V6A2 2 0 0 1 4 4H20A2 2 0 0 1 22 6M20 6H4V18H20V6M12 9A1.5 1.5 0 0 0 10.5 10.5A1.5 1.5 0 0 0 12 12A1.5 1.5 0 0 0 13.5 10.5A1.5 1.5 0 0 0 12 9Z"),
    ("file", "M14 2H6A2 2 0 0 0 4 4V20A2 2 0 0 0 6 22H18A2 2 0 0 0 20 20V8L14 2M18 20H6V4H13V9H18V20Z"),
    ("code", "M14.6 16.6L19.2 12L14.6 7.4L16 6L22 12L16 18L14.6 16.6M9.4 16.6L4.8 12L9.4 7.4L8 6L2 12L8 18L9.4 16.6Z"),
    ("gear", "M12 8A4 4 0 0 0 8 12A4 4 0 0 0 12 16A4 4 0 0 0 16 12A4 4 0 0 0 12 8M12 10A2 2 0 0 1 14 12A2 2 0 0 1 12 14A2 2 0 0 1 10 12A2 2 0 0 1 12 10M19.14 12.94C19.18 12.64 19.2 12.33 19.2 12C19.2 11.68 19.18 11.36 19.13 11.06L21.16 9.48C21.34 9.34 21.39 9.07 21.28 8.87L19.36 5.55C19.24 5.34 19 5.26 18.79 5.34L16.45 6.28C15.95 5.88 15.41 5.55 14.83 5.31L14.47 2.81C14.44 2.59 14.25 2.43 14 2.43H10.17C9.92 2.43 9.73 2.59 9.7 2.81L9.34 5.31C8.76 5.55 8.22 5.88 7.72 6.28L5.38 5.34C5.17 5.26 4.93 5.34 4.81 5.55L2.89 8.87C2.77 9.07 2.82 9.34 3 9.48L5.03 11.06C4.98 11.36 4.96 11.68 4.96 12C4.96 12.32 4.98 12.64 5.03 12.94L3 14.5C2.83 14.66 2.77 14.93 2.89 15.13L4.81 18.45C4.93 18.66 5.17 18.74 5.38 18.66L7.72 17.72C8.22 18.12 8.76 18.45 9.34 18.69L9.7 21.19C9.73 21.41 9.92 21.57 10.17 21.57H14C14.25 21.57 14.44 21.41 14.47 21.19L14.83 18.69C15.41 18.45 15.95 18.12 16.45 17.72L18.79 18.66C19 18.74 19.24 18.66 19.36 18.45L21.28 15.13C21.39 14.93 21.34 14.66 21.16 14.5L19.14 12.94Z"),
    ("text", "M14 17H7V15H14M17 13H7V11H17M17 9H7V7H17M19 3H5C3.89 3 3 3.89 3 5V19C3 20.1 3.89 21 5 21H19C20.1 21 21 20.1 21 19V5C21 3.89 20.1 3 19 3Z"),
    ("key", "M7 14A3 3 0 0 1 4 11A3 3 0 0 1 7 8A3 3 0 0 1 10 11A3 3 0 0 1 7 14M21.59 16L17.59 12L14 15.59L18 19.59L21.59 16M7 2A9 9 0 0 0 -2 11A9 9 0 0 0 7 20C9.38 20 11.5 19.06 13.07 17.54L17.54 13.07C19.06 11.5 20 9.38 20 7L20 2L7 2Z"),
    ("logout", "M17 7L15.59 8.41L18.17 11H8V13H18.17L15.59 15.58L17 17L22 12L17 7M4 5H12V3H4A2 2 0 0 0 2 5V19A2 2 0 0 0 4 21H12V19H4V5Z"),
    ("copy", "M19 3H14V5H19V18H14V20H19A2 2 0 0 0 21 18V5A2 2 0 0 0 19 3M5 5H5V19H5V5M5 3A2 2 0 0 0 3 5V19A2 2 0 0 0 5 21H12A2 2 0 0 0 14 19V5A2 2 0 0 0 12 3H5M12 5V19H5V5H12Z"),
    ("loading", "M12 4V2A10 10 0 0 0 2 12H4A8 8 0 0 1 12 4Z"),
];

fn icon_path(name: &str) -> &'static str {
    ICONS.iter().find(|(n, _)| *n == name).map(|(_, p)| *p).unwrap_or("")
}

#[component]
fn Icon(name: String, class: Option<String>) -> Element {
    let cls = class.unwrap_or_else(|| "icon-sm".to_string());
    rsx! {
        svg { class: "{cls}", view_box: "0 0 24 24",
            path { fill: "currentColor", d: icon_path(&name) }
        }
    }
}

// ---------- App state ----------

#[derive(Clone, PartialEq)]
enum View {
    Login,
    Register,
    App,
}

#[derive(Clone, PartialEq)]
enum DialogState {
    None,
    TotpSetup { secret: String },
    Invites,
}

fn main() {
    dioxus::launch(App);
}

fn App() -> Element {
    let mut current_view = use_signal(|| View::Login);
    let mut user = use_signal(|| Option::<User>::None);
    let mut threads = use_signal(|| Vec::<Thread>::new());
    let mut groups = use_signal(|| Vec::<ThreadGroup>::new());
    let mut models = use_signal(|| Vec::<ModelInfo>::new());
    let mut active_thread_id = use_signal(|| Option::<String>::None);
    let mut active_thread_detail = use_signal(|| Option::<ThreadDetail>::None);
    let mut login_error = use_signal(|| String::new());
    let mut register_error = use_signal(|| String::new());
    let mut show_totp_field = use_signal(|| false);
    let mut sidebar_open = use_signal(|| false);
    let mut user_menu_open = use_signal(|| false);
    let mut files_panel_open = use_signal(|| false);
    let mut files_path = use_signal(|| Vec::<String>::new());
    let mut files_entries = use_signal(|| Vec::<DirEntry>::new());
    let mut files_error = use_signal(|| String::new());
    let mut dialog = use_signal(|| DialogState::None);
    let mut composer_text = use_signal(|| String::new());
    let mut pending_attachments = use_signal(|| Vec::<String>::new());
    let mut sending = use_signal(|| false);
    let mut selected_model = use_signal(|| String::new());
    let mut selected_permission = use_signal(|| "normal".to_string());
    let mut invites = use_signal(|| Vec::<Invite>::new());

    // Check session on startup.
    use_effect(move || {
        spawn(async move {
            if let Ok(me) = api::api_get::<User>("/api/auth/me").await {
                user.set(Some(me));
                current_view.set(View::App);
                if let Ok(m) = api::api_get::<Vec<ModelInfo>>("/api/models").await {
                    models.set(m);
                    if let Some(first) = models.read().first() {
                        selected_model.set(first.id.clone());
                    }
                }
                let t = api::api_get::<Vec<Thread>>("/api/threads").await;
                let g = api::api_get::<Vec<ThreadGroup>>("/api/thread-groups").await;
                if let Ok(t) = t { threads.set(t); }
                if let Ok(g) = g { groups.set(g); }
            } else {
                current_view.set(View::Login);
            }
        });
    });

    let view = current_view.read().clone();

    rsx! {
        match view {
            View::Login => rsx! {
                LoginView { user, current_view, login_error, show_totp_field }
            },
            View::Register => rsx! {
                RegisterView { user, current_view, register_error }
            },
            View::App => rsx! {
                AppView {
                    user, current_view, threads, groups, models,
                    active_thread_id, active_thread_detail,
                    sidebar_open, user_menu_open,
                    files_panel_open, files_path, files_entries, files_error,
                    dialog, composer_text, pending_attachments, sending,
                    selected_model, selected_permission, invites,
                }
            },
        }
    }
}

// ---------- Login ----------

#[component]
fn LoginView(
    user: Signal<Option<User>>,
    current_view: Signal<View>,
    login_error: Signal<String>,
    show_totp_field: Signal<bool>,
) -> Element {
    let mut username = use_signal(String::new);
    let mut password = use_signal(String::new);
    let mut totp = use_signal(String::new);

    let do_login = move |_| {
        spawn(async move {
            login_error.set(String::new());
            let mut body = serde_json::json!({
                "username": username.read().trim(),
                "password": password.read().clone(),
            });
            if !totp.read().trim().is_empty() {
                body["totp"] = serde_json::json!(totp.read().trim());
            }
            match api::api_post::<LoginResponse, serde_json::Value>("/api/auth/login", &body).await {
                Ok(res) => {
                    if res.totp_required {
                        show_totp_field.set(true);
                        login_error.set("Enter your 6-digit TOTP code.".to_string());
                        return;
                    }
                    if let Ok(me) = api::api_get::<User>("/api/auth/me").await {
                        user.set(Some(me));
                        current_view.set(View::App);
                    }
                }
                Err(e) => login_error.set(e),
            }
        });
    };

    rsx! {
        section { class: "view centered-view",
            div { class: "auth-card m3-card",
                div { class: "auth-header",
                    div { class: "logo",
                        Icon { name: "bot".to_string(), class: Some("icon-lg".to_string()) }
                    }
                    h1 { class: "m3-headline-small", "Devinorium" }
                    p { class: "m3-body-medium auth-subtitle", "Sign in to your account" }
                }
                form { class: "auth-form", onsubmit: do_login,
                    label { class: "m3-text-field",
                        input {
                            r#type: "text",
                            autocomplete: "username",
                            required: true,
                            value: "{username}",
                            oninput: move |e| username.set(e.value()),
                        }
                        span { "Username" }
                    }
                    label { class: "m3-text-field",
                        input {
                            r#type: "password",
                            autocomplete: "current-password",
                            required: true,
                            value: "{password}",
                            oninput: move |e| password.set(e.value()),
                        }
                        span { "Password" }
                    }
                    if *show_totp_field.read() {
                        label { class: "m3-text-field",
                            input {
                                r#type: "text",
                                inputmode: "numeric",
                                autocomplete: "one-time-code",
                                placeholder: "000000",
                                value: "{totp}",
                                oninput: move |e| totp.set(e.value()),
                            }
                            span { "TOTP code" }
                        }
                    }
                    button { r#type: "submit", class: "m3-button m3-filled", "Sign in" }
                    if !login_error.read().is_empty() {
                        p { class: "error-text", "{login_error}" }
                    }
                }
                div { class: "auth-footer",
                    button {
                        class: "m3-text-button",
                        onclick: move |_| current_view.set(View::Register),
                        "Have an invite? Register"
                    }
                }
            }
        }
    }
}

// ---------- Register ----------

#[component]
fn RegisterView(
    user: Signal<Option<User>>,
    current_view: Signal<View>,
    register_error: Signal<String>,
) -> Element {
    let mut invite = use_signal(String::new);
    let mut username = use_signal(String::new);
    let mut password = use_signal(String::new);

    let do_register = move |_| {
        spawn(async move {
            register_error.set(String::new());
            let body = serde_json::json!({
                "invite": invite.read().trim(),
                "username": username.read().trim(),
                "password": password.read().clone(),
            });
            match api::api_post::<serde_json::Value, serde_json::Value>("/api/auth/register", &body).await {
                Ok(_) => {
                    let login_body = serde_json::json!({
                        "username": username.read().trim(),
                        "password": password.read().clone(),
                    });
                    match api::api_post::<LoginResponse, serde_json::Value>("/api/auth/login", &login_body).await {
                        Ok(_) => {
                            if let Ok(me) = api::api_get::<User>("/api/auth/me").await {
                                user.set(Some(me));
                                current_view.set(View::App);
                            }
                        }
                        Err(e) => register_error.set(e),
                    }
                }
                Err(e) => register_error.set(e),
            }
        });
    };

    rsx! {
        section { class: "view centered-view",
            div { class: "auth-card m3-card",
                div { class: "auth-header",
                    div { class: "logo",
                        Icon { name: "bot".to_string(), class: Some("icon-lg".to_string()) }
                    }
                    h1 { class: "m3-headline-small", "Create account" }
                    p { class: "m3-body-medium auth-subtitle", "Enter your invite token" }
                }
                form { class: "auth-form", onsubmit: do_register,
                    label { class: "m3-text-field",
                        input {
                            r#type: "text",
                            required: true,
                            placeholder: "invite token",
                            value: "{invite}",
                            oninput: move |e| invite.set(e.value()),
                        }
                        span { "Invite token" }
                    }
                    label { class: "m3-text-field",
                        input {
                            r#type: "text",
                            autocomplete: "username",
                            required: true,
                            value: "{username}",
                            oninput: move |e| username.set(e.value()),
                        }
                        span { "Username" }
                    }
                    label { class: "m3-text-field",
                        input {
                            r#type: "password",
                            autocomplete: "new-password",
                            required: true,
                            minlength: 12,
                            value: "{password}",
                            oninput: move |e| password.set(e.value()),
                        }
                        span { "Password (min 12 chars)" }
                    }
                    button { r#type: "submit", class: "m3-button m3-filled", "Register" }
                    if !register_error.read().is_empty() {
                        p { class: "error-text", "{register_error}" }
                    }
                    button {
                        r#type: "button",
                        class: "m3-text-button",
                        onclick: move |_| current_view.set(View::Login),
                        "Back to sign in"
                    }
                }
            }
        }
    }
}

// ---------- Main App View ----------

#[component]
fn AppView(
    user: Signal<Option<User>>,
    current_view: Signal<View>,
    threads: Signal<Vec<Thread>>,
    groups: Signal<Vec<ThreadGroup>>,
    models: Signal<Vec<ModelInfo>>,
    active_thread_id: Signal<Option<String>>,
    active_thread_detail: Signal<Option<ThreadDetail>>,
    sidebar_open: Signal<bool>,
    user_menu_open: Signal<bool>,
    files_panel_open: Signal<bool>,
    files_path: Signal<Vec<String>>,
    files_entries: Signal<Vec<DirEntry>>,
    files_error: Signal<String>,
    dialog: Signal<DialogState>,
    composer_text: Signal<String>,
    pending_attachments: Signal<Vec<String>>,
    sending: Signal<bool>,
    selected_model: Signal<String>,
    selected_permission: Signal<String>,
    invites: Signal<Vec<Invite>>,
) -> Element {
    let username = user.read().as_ref().map(|u| u.username.clone()).unwrap_or_default();
    let avatar = username.chars().next().unwrap_or('?').to_uppercase().to_string();

    let toggle_sidebar = move |_| {
        sidebar_open.toggle();
    };

    let close_sidebar = move |_| {
        sidebar_open.set(false);
    };

    let new_thread = move |_| {
        spawn(async move {
            let body = serde_json::json!({
                "title": "New thread",
                "model": selected_model.read().clone(),
                "permission_mode": selected_permission.read().clone(),
            });
            if let Ok(t) = api::api_post::<Thread, serde_json::Value>("/api/threads", &body).await {
                let tid = t.id.clone();
                let mut new_threads = threads.read().clone();
                new_threads.insert(0, t);
                threads.set(new_threads);
                active_thread_id.set(Some(tid.clone()));
                sidebar_open.set(false);
                if let Ok(detail) = api::api_get::<ThreadDetail>(&format!("/api/threads/{}", tid)).await {
                    active_thread_detail.set(Some(detail));
                }
                let t2 = api::api_get::<Vec<Thread>>("/api/threads").await;
                let g2 = api::api_get::<Vec<ThreadGroup>>("/api/thread-groups").await;
                if let Ok(t2) = t2 { threads.set(t2); }
                if let Ok(g2) = g2 { groups.set(g2); }
            }
        });
    };

    let logout = move |_| {
        spawn(async move {
            let _ = api::api_post::<serde_json::Value, serde_json::Value>("/api/auth/logout", &serde_json::json!({})).await;
            user.set(None);
            current_view.set(View::Login);
        });
    };

    let open_files = move |_| {
        files_panel_open.set(true);
        files_path.set(Vec::new());
        spawn(async move {
            let path = String::new();
            match api::api_get::<Vec<DirEntry>>("/api/files").await {
                Ok(entries) => {
                    files_entries.set(entries);
                    files_error.set(String::new());
                }
                Err(e) => files_error.set(e),
            }
        });
    };

    let close_files = move |_: Event<()>| {
        files_panel_open.set(false);
    };

    let open_totp = move |_| {
        spawn(async move {
            if let Ok(res) = api::api_post::<TotpSetupResponse, serde_json::Value>("/api/auth/totp/setup", &serde_json::json!({})).await {
                dialog.set(DialogState::TotpSetup { secret: res.secret });
            }
        });
    };

    let open_invites = move |_| {
        spawn(async move {
            if let Ok(inv) = api::api_get::<Vec<Invite>>("/api/invites").await {
                invites.set(inv);
            }
            dialog.set(DialogState::Invites);
        });
    };

    let thread_title = active_thread_detail.read().as_ref().map(|d| d.thread.title.clone()).unwrap_or_else(|| "Select or create a thread".to_string());

    rsx! {
        section { class: "view app-layout",
            if *sidebar_open.read() {
                div { class: "sidebar-scrim visible", onclick: close_sidebar }
            }

            aside { class: "sidebar",
                div { class: "sidebar-header",
                    div { class: "brand",
                        Icon { name: "bot".to_string(), class: Some("icon-md".to_string()) }
                        span { class: "m3-title-medium", "Devinorium" }
                    }
                    button {
                        class: "m3-fab",
                        title: "New thread",
                        onclick: new_thread,
                        Icon { name: "plus".to_string(), class: Some("icon-sm".to_string()) }
                    }
                }

                ThreadList {
                    threads, groups, active_thread_id, active_thread_detail,
                    sidebar_open,
                }

                div { class: "sidebar-footer",
                    div { class: "user-chip",
                        div { class: "avatar", "{avatar}" }
                        span { class: "m3-body-medium", "{username}" }
                    }
                    button {
                        class: "m3-icon-button",
                        title: "Menu",
                        onclick: move |e| {
                            e.stop_propagation();
                            user_menu_open.toggle();
                        },
                        Icon { name: "dots".to_string(), class: Some("icon-sm".to_string()) }
                    }
                }

                if *user_menu_open.read() {
                    div { class: "user-menu m3-card",
                        button { class: "menu-item", onclick: open_totp,
                            Icon { name: "key".to_string(), class: Some("icon-sm menu-icon".to_string()) }
                            "Enable 2FA (TOTP)"
                        }
                        button { class: "menu-item", onclick: open_invites,
                            Icon { name: "copy".to_string(), class: Some("icon-sm menu-icon".to_string()) }
                            "Invites"
                        }
                        button { class: "menu-item danger", onclick: logout,
                            Icon { name: "logout".to_string(), class: Some("icon-sm menu-icon".to_string()) }
                            "Sign out"
                        }
                    }
                }
            }

            main { class: "main-content",
                header { class: "main-header",
                    button {
                        class: "m3-icon-button mobile-only",
                        onclick: toggle_sidebar,
                        Icon { name: "menu".to_string(), class: Some("icon-sm".to_string()) }
                    }
                    h2 { class: "m3-title-large", "{thread_title}" }
                    div { class: "header-actions",
                        select {
                            class: "m3-select",
                            value: "{selected_model}",
                            onchange: move |e| selected_model.set(e.value()),
                            {models.read().iter().map(|m| rsx! {
                                option { value: "{m.id}", "{m.label}" }
                            })}
                        }
                        select {
                            class: "m3-select",
                            value: "{selected_permission}",
                            onchange: move |e| selected_permission.set(e.value()),
                            option { value: "normal", "Normal" }
                            option { value: "accept-edits", "Accept edits" }
                            option { value: "smart", "Smart" }
                            option { value: "bypass", "Bypass" }
                        }
                        button {
                            class: "m3-icon-button",
                            title: "File manager",
                            onclick: open_files,
                            Icon { name: "folder".to_string(), class: Some("icon-sm".to_string()) }
                        }
                    }
                }

                ChatView {
                    active_thread_detail, active_thread_id, composer_text,
                    pending_attachments, sending, threads, groups,
                }
            }

            if *files_panel_open.read() {
                FilesPanel {
                    files_path, files_entries, files_error, files_panel_open,
                }
            }
        }

        // Global dialogs (rendered outside main layout).
        match dialog.read().clone() {
            DialogState::None => rsx! {},
            DialogState::TotpSetup { secret } => rsx! {
                div { class: "dialog-scrim",
                    div { class: "m3-card dialog",
                        h3 { class: "m3-headline-small", "Enable 2FA" }
                        p { class: "m3-body-medium", "Scan this secret in your authenticator app, then enter the current code." }
                        div { class: "totp-secret", "{secret}" }
                        div { class: "dialog-actions",
                            button {
                                class: "m3-text-button",
                                onclick: move |_| dialog.set(DialogState::None),
                                "Cancel"
                            }
                        }
                    }
                }
            },
            DialogState::Invites => rsx! {
                InvitesDialog { dialog, invites }
            },
        }
    }
}

#[component]
fn InvitesDialog(dialog: Signal<DialogState>, invites: Signal<Vec<Invite>>) -> Element {
    rsx! {
        div { class: "dialog-scrim",
            div { class: "m3-card dialog",
                h3 { class: "m3-headline-small", "Invite tokens" }
                p { class: "m3-body-medium", "Share a token so someone can register. Tokens are single-use and expire in 7 days." }
                {invites.read().iter().map(|i| {
                    let status_class = if i.used_by_user_id.is_some() { "invite-status used" } else { "invite-status fresh" };
                    let status_text = if i.used_by_user_id.is_some() { "Used" } else { "Available" };
                    let token = i.token.clone();
                    rsx! {
                        div { class: "invite-row", key: "{token}",
                            span { class: "invite-token", "{token}" }
                            span { class: "{status_class}", "{status_text}" }
                        }
                    }
                })}
                div { class: "dialog-actions",
                    button {
                        class: "m3-text-button",
                        onclick: move |_| dialog.set(DialogState::None),
                        "Close"
                    }
                }
            }
        }
    }
}

// ---------- Thread List (sidebar) ----------

#[component]
fn ThreadList(
    threads: Signal<Vec<Thread>>,
    groups: Signal<Vec<ThreadGroup>>,
    active_thread_id: Signal<Option<String>>,
    active_thread_detail: Signal<Option<ThreadDetail>>,
    sidebar_open: Signal<bool>,
) -> Element {
    let all_threads = threads.read().clone();
    let all_groups = groups.read().clone();
    let active_id = active_thread_id.read().clone();

    let ungrouped: Vec<Thread> = all_threads.iter().filter(|t| t.thread_group_id.is_none()).cloned().collect();
    let grouped: Vec<(ThreadGroup, Vec<Thread>)> = all_groups.iter().map(|g| {
        let g_threads: Vec<Thread> = all_threads.iter().filter(|t| t.thread_group_id == Some(g.id)).cloned().collect();
        (g.clone(), g_threads)
    }).filter(|(_, ts)| !ts.is_empty()).collect();

    if all_threads.is_empty() {
        return rsx! {
            nav { class: "thread-list",
                div { class: "m3-label-medium", style: "padding:16px;text-align:center", "No threads yet" }
            }
        };
    }

    rsx! {
        nav { class: "thread-list",
            if !ungrouped.is_empty() {
                div { class: "thread-group-section",
                    div { class: "thread-group-label m3-label-medium", "Ungrouped" }
                    {ungrouped.iter().map(|t| {
                        let tid = t.id.clone();
                        let is_active = active_id.as_ref() == Some(&tid);
                        rsx! {
                            ThreadItem {
                                key: "{tid}",
                                thread: t.clone(),
                                is_active,
                                active_thread_id, active_thread_detail, sidebar_open,
                                threads, groups,
                            }
                        }
                    })}
                }
            }
            {grouped.iter().map(|(g, g_threads)| {
                let gid = g.id;
                rsx! {
                    div { class: "thread-group-section", key: "{gid}",
                        div { class: "thread-group-header",
                            Icon { name: "menu".to_string(), class: Some("icon-sm thread-group-chevron".to_string()) }
                            span { class: "thread-group-name", "{g.name}" }
                            span {
                                class: "thread-group-del",
                                title: "Delete group (Shift+click to skip confirmation)",
                                onclick: move |e| {
                                    e.stop_propagation();
                                    let skip = e.modifiers().contains(Modifiers::SHIFT);
                                    spawn(async move {
                                        if skip || web_sys::window().unwrap().confirm_with_message("Delete this group? Threads will become ungrouped.").unwrap_or(false) {
                                            let _ = api::api_delete::<serde_json::Value>(&format!("/api/thread-groups/{}", gid)).await;
                                            let t = api::api_get::<Vec<Thread>>("/api/threads").await;
                                            let g = api::api_get::<Vec<ThreadGroup>>("/api/thread-groups").await;
                                            if let Ok(t) = t { threads.set(t); }
                                            if let Ok(g) = g { groups.set(g); }
                                        }
                                    });
                                },
                                Icon { name: "trash".to_string(), class: Some("icon-xs".to_string()) }
                            }
                        }
                        div { class: "thread-group-items",
                            {g_threads.iter().map(|t| {
                                let tid = t.id.clone();
                                let is_active = active_id.as_ref() == Some(&tid);
                                rsx! {
                                    ThreadItem {
                                        key: "{tid}",
                                        thread: t.clone(),
                                        is_active,
                                        active_thread_id, active_thread_detail, sidebar_open,
                                        threads, groups,
                                    }
                                }
                            })}
                        }
                    }
                }
            })}
        }
    }
}

#[component]
fn ThreadItem(
    thread: Thread,
    is_active: bool,
    active_thread_id: Signal<Option<String>>,
    active_thread_detail: Signal<Option<ThreadDetail>>,
    sidebar_open: Signal<bool>,
    threads: Signal<Vec<Thread>>,
    groups: Signal<Vec<ThreadGroup>>,
) -> Element {
    let tid = thread.id.clone();
    let tid_open = tid.clone();
    let tid_delete = tid.clone();
    let active_class = if is_active { "active" } else { "" };

    let open = move |_| {
        let tid = tid_open.clone();
        spawn(async move {
            active_thread_id.set(Some(tid.clone()));
            sidebar_open.set(false);
            if let Ok(detail) = api::api_get::<ThreadDetail>(&format!("/api/threads/{}", tid)).await {
                active_thread_detail.set(Some(detail));
            }
        });
    };

    let delete = move |e: MouseEvent| {
        e.stop_propagation();
        let tid = tid_delete.clone();
        let skip = e.modifiers().contains(Modifiers::SHIFT);
        spawn(async move {
            if skip || web_sys::window().unwrap().confirm_with_message("Delete this thread? This cannot be undone.").unwrap_or(false) {
                let _ = api::api_delete::<serde_json::Value>(&format!("/api/threads/{}", tid)).await;
                let t = api::api_get::<Vec<Thread>>("/api/threads").await;
                let g = api::api_get::<Vec<ThreadGroup>>("/api/thread-groups").await;
                if let Ok(t) = t { threads.set(t); }
                if let Ok(g) = g { groups.set(g); }
            }
        });
    };

    rsx! {
        div {
            class: "thread-item {active_class}",
            onclick: open,
            Icon { name: "chat".to_string(), class: Some("icon-sm".to_string()) }
            span { class: "thread-title-text", "{thread.title}" }
            span {
                class: "thread-del",
                title: "Delete (Shift+click to skip confirmation)",
                onclick: delete,
                Icon { name: "trash".to_string(), class: Some("icon-sm".to_string()) }
            }
        }
    }
}

// ---------- Chat View ----------

#[component]
fn ChatView(
    active_thread_detail: Signal<Option<ThreadDetail>>,
    active_thread_id: Signal<Option<String>>,
    composer_text: Signal<String>,
    pending_attachments: Signal<Vec<String>>,
    sending: Signal<bool>,
    threads: Signal<Vec<Thread>>,
    groups: Signal<Vec<ThreadGroup>>,
) -> Element {
    let detail = active_thread_detail.read().clone();
    let thread_id = active_thread_id.read().clone();
    let is_sending = *sending.read();

    let send = move |_| {
        let text = composer_text.read().clone();
        let tid = thread_id.clone();
        if text.trim().is_empty() || tid.is_none() {
            return;
        }
        let tid = tid.unwrap();
        spawn(async move {
            sending.set(true);
            composer_text.set(String::new());
            match api::send_message(&format!("/api/threads/{}/send", tid), &text, &[]).await {
                Ok(_) => {
                    if let Ok(d) = api::api_get::<ThreadDetail>(&format!("/api/threads/{}", tid)).await {
                        active_thread_detail.set(Some(d));
                    }
                    let t = api::api_get::<Vec<Thread>>("/api/threads").await;
                    let g = api::api_get::<Vec<ThreadGroup>>("/api/thread-groups").await;
                    if let Ok(t) = t { threads.set(t); }
                    if let Ok(g) = g { groups.set(g); }
                }
                Err(e) => {
                    web_sys::console::log_1(&format!("Send error: {}", e).into());
                }
            }
            sending.set(false);
        });
    };

    let on_keydown = move |e: KeyboardEvent| {
        if e.key() == Key::Enter && !e.modifiers().contains(Modifiers::SHIFT) {
            e.prevent_default();
        }
    };

    rsx! {
        div { class: "messages",
            match &detail {
                None => rsx! {
                    div { class: "m3-body-medium",
                        style: "text-align:center;color:var(--md-on-surface-variant);padding:48px",
                        "Select or create a thread to start chatting."
                    }
                },
                Some(d) if d.messages.is_empty() => rsx! {
                    div { class: "m3-body-medium",
                        style: "text-align:center;color:var(--md-on-surface-variant);padding:48px",
                        "Start the conversation by sending a message below."
                    }
                },
                Some(d) => rsx! {
                    {d.messages.iter().enumerate().map(|(i, m)| rsx! {
                        MessageItem { key: "{i}", message: m.clone() }
                    })}
                },
            }
        }

        form { class: "composer", onsubmit: move |e| { e.prevent_default(); send(()); },
            div { class: "composer-row",
                textarea {
                    class: "m3-text-area",
                    placeholder: "Send a message...",
                    rows: "1",
                    value: "{composer_text}",
                    oninput: move |e| composer_text.set(e.value()),
                    onkeydown: on_keydown,
                }
                button {
                    r#type: "submit",
                    class: "m3-fab send-btn",
                    disabled: is_sending,
                    if is_sending {
                        Icon { name: "loading".to_string(), class: Some("icon-sm icon-spin".to_string()) }
                    } else {
                        Icon { name: "send".to_string(), class: Some("icon-sm".to_string()) }
                    }
                }
            }
        }
    }
}

#[component]
fn MessageItem(message: Message) -> Element {
    let icon = match message.role.as_str() {
        "user" => "person",
        "assistant" => "bot",
        _ => "warning",
    };
    let label = match message.role.as_str() {
        "user" => "You",
        "assistant" => "Assistant",
        _ => "Error",
    };

    rsx! {
        div { class: "message {message.role}",
            div { class: "msg-avatar",
                Icon { name: icon.to_string(), class: Some("icon-sm".to_string()) }
            }
            div { class: "msg-body",
                div { class: "msg-role", "{label}" }
                div { class: "msg-content", "{message.content}" }
                if let Some(atts) = &message.attachments {
                    if !atts.is_empty() {
                        div { class: "msg-attachments",
                            {atts.iter().map(|a| rsx! {
                                span { class: "msg-attachment-chip", key: "{a.filename}",
                                    Icon { name: "paperclip".to_string(), class: Some("icon-xs".to_string()) }
                                    " {a.filename}"
                                }
                            })}
                        }
                    }
                }
            }
        }
    }
}

// ---------- Files Panel ----------

#[component]
fn FilesPanel(
    files_path: Signal<Vec<String>>,
    files_entries: Signal<Vec<DirEntry>>,
    files_error: Signal<String>,
    files_panel_open: Signal<bool>,
) -> Element {
    let entries = files_entries.read().clone();
    let path = files_path.read().clone();
    let error = files_error.read().clone();

    let close = move |_| {
        files_panel_open.set(false);
    };

    let mkdir = move |_| {
        spawn(async move {
            if let Some(Some(name)) = web_sys::window().and_then(|w| w.prompt_with_message_and_default("Folder name:", "").ok()) {
                if !name.trim().is_empty() {
                    let p = files_path.read().join("/");
                    let full_path = if p.is_empty() { name.trim().to_string() } else { format!("{}/{}", p, name.trim()) };
                    let _ = api::api_post::<serde_json::Value, serde_json::Value>(
                        "/api/files/dir",
                        &serde_json::json!({ "path": full_path }),
                    ).await;
                    reload_files(files_path, files_entries, files_error).await;
                }
            }
        });
    };

    rsx! {
        aside { class: "files-panel open",
            div { class: "files-header",
                h3 { class: "m3-title-medium", "Files" }
                div { class: "files-actions",
                    button { class: "m3-icon-button", title: "New folder", onclick: mkdir,
                        Icon { name: "folder-plus".to_string(), class: Some("icon-sm".to_string()) }
                    }
                    button { class: "m3-icon-button", title: "Close", onclick: close,
                        Icon { name: "close".to_string(), class: Some("icon-sm".to_string()) }
                    }
                }
            }

            div { class: "files-breadcrumb",
                span {
                    class: "crumb",
                    onclick: move |_| {
                        files_path.set(Vec::new());
                        spawn(async move { reload_files(files_path, files_entries, files_error).await; });
                    },
                    "root"
                }
                {path.iter().enumerate().map(|(i, p)| rsx! {
                    span { key: "{i}",
                        " / "
                        span {
                            class: "crumb",
                            onclick: move |_| {
                                let mut new_path = files_path.read().clone();
                                new_path.truncate(i + 1);
                                files_path.set(new_path);
                                spawn(async move { reload_files(files_path, files_entries, files_error).await; });
                            },
                            "{p}"
                        }
                    }
                })}
            }

            div { class: "files-list",
                if !error.is_empty() {
                    div { class: "error-text", style: "padding:12px", "{error}" }
                } else if entries.is_empty() {
                    div { class: "m3-body-medium",
                        style: "padding:16px;color:var(--md-on-surface-variant)",
                        "Empty folder"
                    }
                } else {
                    {entries.iter().map(|e| {
                        let name = e.name.clone();
                        let name_click = name.clone();
                        let name_delete = name.clone();
                        let name_display = name.clone();
                        let is_dir = e.is_dir;
                        let icon_name = if is_dir { "folder".to_string() } else { file_icon(&name) };
                        let size_str = if is_dir { "".to_string() } else { format_size(e.size) };
                        rsx! {
                            div { class: "file-entry", key: "{name}",
                                onclick: move |_| {
                                    if is_dir {
                                        let mut new_path = files_path.read().clone();
                                        new_path.push(name_click.clone());
                                        files_path.set(new_path);
                                        spawn(async move { reload_files(files_path, files_entries, files_error).await; });
                                    }
                                },
                                Icon { name: icon_name, class: Some("file-icon".to_string()) }
                                span { class: "file-name", "{name_display}" }
                                span { class: "file-size", "{size_str}" }
                                span { class: "file-actions",
                                    button {
                                        title: "Delete (Shift+click to skip confirmation)",
                                        onclick: move |e| {
                                            e.stop_propagation();
                                            let skip = e.modifiers().contains(Modifiers::SHIFT);
                                            let p = files_path.read().join("/");
                                            let n = name_delete.clone();
                                            spawn(async move {
                                                let full = if p.is_empty() { n.clone() } else { format!("{}/{}", p, n) };
                                                if skip || web_sys::window().unwrap().confirm_with_message(&format!("Delete {}?", n)).unwrap_or(false) {
                                                    let _ = api::api_delete::<serde_json::Value>(&format!("/api/files/delete?path={}", urlencode(&full))).await;
                                                    reload_files(files_path, files_entries, files_error).await;
                                                }
                                            });
                                        },
                                        Icon { name: "trash".to_string(), class: Some("icon-sm".to_string()) }
                                    }
                                }
                            }
                        }
                    })}
                }
            }
        }
    }
}

async fn reload_files(
    files_path: Signal<Vec<String>>,
    mut files_entries: Signal<Vec<DirEntry>>,
    mut files_error: Signal<String>,
) {
    let path = files_path.read().join("/");
    let qs = if path.is_empty() { String::new() } else { format!("?path={}", urlencode(&path)) };
    match api::api_get::<Vec<DirEntry>>(&format!("/api/files{}", qs)).await {
        Ok(entries) => {
            files_entries.set(entries);
            files_error.set(String::new());
        }
        Err(e) => {
            files_error.set(e);
        }
    }
}

// ---------- Utility functions ----------

fn file_icon(name: &str) -> String {
    let ext = name.rsplit('.').next().unwrap_or("").to_lowercase();
    if ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(&ext.as_str()) { "image".into() }
    else if ["md", "txt", "log"].contains(&ext.as_str()) { "text".into() }
    else if ["rs", "js", "ts", "py", "go", "java", "c", "cpp", "rb"].contains(&ext.as_str()) { "code".into() }
    else if ["json", "yaml", "yml", "toml"].contains(&ext.as_str()) { "gear".into() }
    else { "file".into() }
}

fn format_size(n: u64) -> String {
    if n < 1024 { format!("{} B", n) }
    else if n < 1048576 { format!("{:.1} KB", n as f64 / 1024.0) }
    else { format!("{:.1} MB", n as f64 / 1048576.0) }
}

fn urlencode(s: &str) -> String {
    s.chars().map(|c| {
        if c.is_alphanumeric() || c == '-' || c == '_' || c == '.' || c == '~' {
            c.to_string()
        } else if c == '/' {
            "%2F".to_string()
        } else {
            format!("%{:02X}", c as u8)
        }
    }).collect()
}
