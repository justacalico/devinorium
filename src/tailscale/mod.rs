//! Tailscale integration.
//!
//! Wraps the `tailscale` CLI the same way t3code's `@t3tools/tailscale`
//! package does: `status --json` parsing for the MagicDNS name and tailnet
//! IPs, `serve` lifecycle for publishing the backend over Tailscale HTTPS,
//! the 100.64.0.0/10 CGNAT check, and a short probe of the resulting
//! endpoint. Raw stderr is never surfaced: `tailscale` prints auth keys and
//! node names there, so failures are reported as classified labels only.

use std::io::ErrorKind;
use std::time::Duration;

use serde::Deserialize;
use tokio::process::Command;

/// Default HTTPS port for `tailscale serve`, same as t3code.
pub const DEFAULT_SERVE_PORT: u16 = 443;

const STATUS_TIMEOUT: Duration = Duration::from_millis(1_500);
const SERVE_TIMEOUT: Duration = Duration::from_secs(10);
const PROBE_TIMEOUT: Duration = Duration::from_millis(2_500);

/// What `tailscale status --json` tells us about this node.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Status {
    /// MagicDNS name without the trailing dot, e.g. `host.tail-abc.ts.net`.
    /// Absent when the device is logged out or the tailnet has MagicDNS off.
    pub magic_dns_name: Option<String>,
    /// This node's tailnet IPv4 addresses (100.64.0.0/10 only; IPv6 is
    /// filtered out since we never advertise it).
    pub tailnet_ipv4: Vec<String>,
    /// Raw `BackendState` (`Running`, `NeedsLogin`, ...), for diagnostics.
    pub backend_state: Option<String>,
}

/// Safe failure labels for `tailscale` CLI errors. Matches t3code's
/// `TailscaleStderrDiagnostic`: a closed set so logs and API responses never
/// carry raw stderr (which can contain auth keys).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StderrDiagnostic {
    /// `serve off` on a port with no mapping.
    NoExistingHandler,
    /// The node is logged out of Tailscale.
    NotLoggedIn,
    /// The process lacks permission to talk to tailscaled.
    PermissionDenied,
    /// Anything else.
    Unknown,
}

impl StderrDiagnostic {
    pub fn label(self) -> &'static str {
        match self {
            Self::NoExistingHandler => "no-existing-handler",
            Self::NotLoggedIn => "not-logged-in",
            Self::PermissionDenied => "permission-denied",
            Self::Unknown => "unknown",
        }
    }
}

fn classify_stderr(stderr: &[u8]) -> StderrDiagnostic {
    let text = String::from_utf8_lossy(stderr);
    let text = text.trim();
    if text.is_empty() {
        return StderrDiagnostic::Unknown;
    }
    let lower = text.to_lowercase();
    if lower.contains("handler does not exist") {
        StderrDiagnostic::NoExistingHandler
    } else if lower.contains("not logged in")
        || lower.contains("logged out")
        || lower.contains("needs login")
    {
        StderrDiagnostic::NotLoggedIn
    } else if lower.contains("permission denied")
        || lower.contains("access denied")
        || lower.contains("must be root")
        || lower.contains("operation not permitted")
    {
        StderrDiagnostic::PermissionDenied
    } else {
        StderrDiagnostic::Unknown
    }
}

#[derive(Debug, thiserror::Error)]
pub enum TailscaleError {
    #[error("tailscale CLI was not found on PATH")]
    NotInstalled,
    #[error("`tailscale {subcommand}` failed: {diagnostic}")]
    Command {
        subcommand: &'static str,
        diagnostic: &'static str,
    },
    #[error("`tailscale {subcommand}` timed out")]
    Timeout { subcommand: &'static str },
    #[error("`tailscale status` returned unreadable JSON")]
    Parse,
}

/// Thin client over the `tailscale` binary. Cheap to clone; all methods take
/// `&self` and spawn short-lived CLI invocations.
#[derive(Clone)]
pub struct Tailscale {
    bin: String,
    client: reqwest::Client,
}

fn probe_client() -> reqwest::Client {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
}

#[derive(Debug, Deserialize)]
struct StatusJson {
    #[serde(rename = "BackendState")]
    backend_state: Option<String>,
    #[serde(rename = "Self")]
    self_node: Option<SelfNode>,
}

#[derive(Debug, Deserialize)]
struct SelfNode {
    #[serde(rename = "DNSName")]
    dns_name: Option<serde_json::Value>,
    #[serde(rename = "TailscaleIPs")]
    tailscale_ips: Option<serde_json::Value>,
}

impl Tailscale {
    pub fn new(bin: impl Into<String>) -> Self {
        Self {
            bin: bin.into(),
            client: probe_client(),
        }
    }

    /// `tailscale status --json`, parsed into [`Status`].
    pub async fn read_status(&self) -> Result<Status, TailscaleError> {
        let out = self
            .run("status", &["status", "--json"], STATUS_TIMEOUT)
            .await?;
        parse_status_json(&out.stdout)
    }

    /// `tailscale serve status --json` reduced to the tailnet HTTPS ports
    /// that proxy to our local listener plus every HTTPS port in use.
    pub async fn serve_https_ports(
        &self,
        local_host: &str,
        local_port: u16,
    ) -> Result<ServePorts, TailscaleError> {
        let out = self
            .run("serve", &["serve", "status", "--json"], STATUS_TIMEOUT)
            .await?;
        Ok(serve_status_https_ports(
            &out.stdout,
            local_host,
            local_port,
        ))
    }

    /// Publish `target` (e.g. `http://127.0.0.1:7878`) over Tailscale Serve
    /// HTTPS on `https_port`. Mappings persist in tailscaled until removed.
    pub async fn ensure_serve(&self, target: &str, https_port: u16) -> Result<(), TailscaleError> {
        let port = format!("--https={https_port}");
        self.run(
            "serve",
            &["serve", "--bg", port.as_str(), target],
            SERVE_TIMEOUT,
        )
        .await?;
        Ok(())
    }

    /// Remove the HTTPS mapping on `https_port`. Already-absent mappings are
    /// a success so toggling off is idempotent.
    pub async fn disable_serve(&self, https_port: u16) -> Result<(), TailscaleError> {
        let port = format!("--https={https_port}");
        match self
            .run("serve", &["serve", port.as_str(), "off"], SERVE_TIMEOUT)
            .await
        {
            Ok(_) => Ok(()),
            Err(TailscaleError::Command { diagnostic, .. })
                if diagnostic == StderrDiagnostic::NoExistingHandler.label() =>
            {
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    /// GET `{base_url}healthz` with a short timeout. Used to confirm the
    /// MagicDNS HTTPS endpoint answers; first requests can be slow while
    /// Tailscale provisions the cert, so false does not always mean broken.
    /// Redirects are not followed: a serve mapping pointing somewhere else
    /// must not count as reachable.
    pub async fn probe_https(&self, base_url: &str) -> bool {
        let url = format!("{}/healthz", base_url.trim_end_matches('/'));
        match self.client.get(url).timeout(PROBE_TIMEOUT).send().await {
            Ok(resp) => resp.status().is_success(),
            Err(_) => false,
        }
    }

    async fn run(
        &self,
        subcommand: &'static str,
        args: &[&str],
        timeout: Duration,
    ) -> Result<std::process::Output, TailscaleError> {
        let fut = Command::new(&self.bin)
            .args(args)
            .kill_on_drop(true)
            .output();
        match tokio::time::timeout(timeout, fut).await {
            Err(_) => Err(TailscaleError::Timeout { subcommand }),
            Ok(Err(e)) if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::PermissionDenied) => {
                Err(TailscaleError::NotInstalled)
            }
            Ok(Err(e)) => {
                tracing::debug!("failed to spawn tailscale {subcommand}: {e}");
                Err(TailscaleError::Command {
                    subcommand,
                    diagnostic: StderrDiagnostic::Unknown.label(),
                })
            }
            Ok(Ok(out)) if out.status.success() => Ok(out),
            Ok(Ok(out)) => Err(TailscaleError::Command {
                subcommand,
                diagnostic: classify_stderr(&out.stderr).label(),
            }),
        }
    }
}

/// 100.64.0.0/10: the CGNAT range Tailscale assigns to tailnet nodes.
pub fn is_tailscale_ipv4(addr: &str) -> bool {
    let parts: Vec<&str> = addr.split('.').collect();
    if parts.len() != 4 {
        return false;
    }
    let mut octets = [0u8; 4];
    for (i, part) in parts.iter().enumerate() {
        match part.parse::<u8>() {
            Ok(v) => octets[i] = v,
            Err(_) => return false,
        }
    }
    octets[0] == 100 && (64..=127).contains(&octets[1])
}

/// Parse `tailscale status --json`. Only the fields we use are decoded;
/// unknown shape elements are ignored.
pub fn parse_status_json(raw: &[u8]) -> Result<Status, TailscaleError> {
    let parsed: StatusJson = serde_json::from_slice(raw).map_err(|_| TailscaleError::Parse)?;
    let magic_dns_name = parsed
        .self_node
        .as_ref()
        .and_then(|s| s.dns_name.as_ref())
        .and_then(|v| v.as_str())
        .map(|s| s.trim().trim_end_matches('.').to_string())
        .filter(|s| !s.is_empty());
    let tailnet_ipv4 = parsed
        .self_node
        .as_ref()
        .and_then(|s| s.tailscale_ips.as_ref())
        .and_then(|v| v.as_array())
        .map(|ips| {
            ips.iter()
                .filter_map(|v| v.as_str())
                .filter(|ip| is_tailscale_ipv4(ip))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    Ok(Status {
        magic_dns_name,
        tailnet_ipv4,
        backend_state: parsed.backend_state.filter(|s| !s.is_empty()),
    })
}

/// `https://<dns>/`, with the port spelled out when it is not 443. Same shape
/// t3code's `buildTailscaleHttpsBaseUrl` produces.
pub fn build_https_base_url(magic_dns_name: &str, serve_port: u16) -> String {
    if serve_port == DEFAULT_SERVE_PORT {
        format!("https://{magic_dns_name}/")
    } else {
        format!("https://{magic_dns_name}:{serve_port}/")
    }
}

/// The loopback URL `tailscale serve` should proxy to. A specific non-loopback
/// bind address is used as-is; wildcard and loopback binds collapse to
/// 127.0.0.1 since tailscaled runs on the same host.
pub fn local_serve_target(host: &str, port: u16) -> String {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    let is_wildcard = bare
        .parse::<std::net::IpAddr>()
        .map(|ip| ip.is_unspecified())
        .unwrap_or(false);
    let is_loopback = bare
        .parse::<std::net::IpAddr>()
        .map(|ip| ip.is_loopback())
        .unwrap_or_else(|_| bare.eq_ignore_ascii_case("localhost"));
    let target_host = if is_wildcard || is_loopback || bare.is_empty() {
        "127.0.0.1".to_string()
    } else {
        match bare.parse::<std::net::IpAddr>() {
            Ok(std::net::IpAddr::V6(_)) => format!("[{bare}]"),
            _ => bare.to_string(),
        }
    };
    format!("http://{target_host}:{port}")
}

/// The `tailscale serve` HTTPS port split: `ours` are `Web` ports whose
/// proxy handler forwards to our listener, `all` is every `Web` port with a
/// mapping. `all` lets the enable path refuse to clobber a foreign mapping
/// on the configured port.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ServePorts {
    pub ours: Vec<u16>,
    pub all: Vec<u16>,
}

/// Walk `tailscale serve status --json` and bucket the `Web` https ports by
/// whether their `Proxy` handler forwards to `host:port`, so the reported
/// URL and the disable path use the ports mappings actually listen on
/// rather than assuming the configured one.
fn serve_status_https_ports(raw: &[u8], local_host: &str, local_port: u16) -> ServePorts {
    let mut out = ServePorts::default();
    let Ok(json) = serde_json::from_slice::<serde_json::Value>(raw) else {
        return out;
    };
    let Some(web) = json.get("Web").and_then(|w| w.as_object()) else {
        return out;
    };
    for (key, entry) in web {
        let Some(port) = key
            .rsplit_once(':')
            .and_then(|(_, p)| p.parse::<u16>().ok())
        else {
            continue;
        };
        out.all.push(port);
        let mut targets = Vec::new();
        collect_proxy_targets(entry, &mut targets);
        if targets
            .iter()
            .any(|t| proxy_target_matches(t, local_host, local_port))
        {
            out.ours.push(port);
        }
    }
    out
}

fn collect_proxy_targets<'a>(v: &'a serde_json::Value, out: &mut Vec<&'a str>) {
    match v {
        serde_json::Value::Object(map) => {
            for (k, val) in map {
                if k == "Proxy" {
                    if let Some(s) = val.as_str() {
                        out.push(s);
                    }
                }
                collect_proxy_targets(val, out);
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                collect_proxy_targets(item, out);
            }
        }
        _ => {}
    }
}

/// Does a `Proxy` URL like `http://127.0.0.1:7878` point at our listener?
/// The port must match exactly; the host may be any loopback spelling or our
/// configured bind address.
fn proxy_target_matches(target: &str, local_host: &str, local_port: u16) -> bool {
    let after_scheme = match target.split_once("://") {
        Some((_, rest)) => rest,
        None => target,
    };
    let host_port = after_scheme.split('/').next().unwrap_or("");
    let (host, port_str) = match host_port.rsplit_once(':') {
        Some((h, p)) => (h, p),
        None => return false,
    };
    if port_str.parse::<u16>() != Ok(local_port) {
        return false;
    }
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    let host_is_loopback = bare
        .parse::<std::net::IpAddr>()
        .map(|ip| ip.is_loopback())
        .unwrap_or_else(|_| bare.eq_ignore_ascii_case("localhost"));
    host_is_loopback || bare == local_host.trim_start_matches('[').trim_end_matches(']')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cgnat_range_check() {
        assert!(is_tailscale_ipv4("100.64.0.1"));
        assert!(is_tailscale_ipv4("100.127.255.254"));
        assert!(!is_tailscale_ipv4("100.63.255.255"));
        assert!(!is_tailscale_ipv4("100.128.0.1"));
        assert!(!is_tailscale_ipv4("192.168.1.1"));
        assert!(!is_tailscale_ipv4("fd7a:115c:a1e0::1"));
        assert!(!is_tailscale_ipv4("100.64.0"));
        assert!(!is_tailscale_ipv4("100.64.0.256"));
        assert!(!is_tailscale_ipv4(""));
    }

    #[test]
    fn parses_dns_name_and_filters_ipv4() {
        let raw = br#"{
            "BackendState": "Running",
            "Self": {
                "DNSName": "host.tail-abc.ts.net.",
                "TailscaleIPs": ["100.96.1.2", "fd7a:115c:a1e0::1"]
            }
        }"#;
        let status = parse_status_json(raw).unwrap();
        assert_eq!(
            status.magic_dns_name.as_deref(),
            Some("host.tail-abc.ts.net")
        );
        assert_eq!(status.tailnet_ipv4, vec!["100.96.1.2".to_string()]);
        assert_eq!(status.backend_state.as_deref(), Some("Running"));
    }

    #[test]
    fn status_without_self_or_dns() {
        let status = parse_status_json(br#"{"BackendState":"NeedsLogin"}"#).unwrap();
        assert_eq!(status.magic_dns_name, None);
        assert!(status.tailnet_ipv4.is_empty());
        assert_eq!(status.backend_state.as_deref(), Some("NeedsLogin"));

        let status = parse_status_json(br#"{"Self":{"DNSName":""}}"#).unwrap();
        assert_eq!(status.magic_dns_name, None);
    }

    #[test]
    fn status_rejects_garbage() {
        assert!(matches!(
            parse_status_json(b"not json"),
            Err(TailscaleError::Parse)
        ));
    }

    #[test]
    fn https_url_omits_default_port() {
        assert_eq!(
            build_https_base_url("host.tail.ts.net", 443),
            "https://host.tail.ts.net/"
        );
        assert_eq!(
            build_https_base_url("host.tail.ts.net", 8443),
            "https://host.tail.ts.net:8443/"
        );
    }

    #[test]
    fn serve_target_prefers_loopback_for_wildcard_and_loopback_binds() {
        assert_eq!(local_serve_target("0.0.0.0", 7878), "http://127.0.0.1:7878");
        assert_eq!(local_serve_target("::", 7878), "http://127.0.0.1:7878");
        assert_eq!(
            local_serve_target("127.0.0.1", 7878),
            "http://127.0.0.1:7878"
        );
        assert_eq!(
            local_serve_target("localhost", 7878),
            "http://127.0.0.1:7878"
        );
        assert_eq!(
            local_serve_target("192.168.1.5", 7878),
            "http://192.168.1.5:7878"
        );
        assert_eq!(
            local_serve_target("fd7a:115c:a1e0::1", 7878),
            "http://[fd7a:115c:a1e0::1]:7878"
        );
        assert_eq!(
            local_serve_target("[fd7a:115c:a1e0::1]", 7878),
            "http://[fd7a:115c:a1e0::1]:7878"
        );
    }

    #[test]
    fn serve_status_finds_our_proxy() {
        let raw = br#"{
            "TCP": {"443": {"HTTPS": true}},
            "Web": {
                "host.tail.ts.net:443": {
                    "Handlers": {"/": {"Proxy": "http://127.0.0.1:7878"}}
                }
            }
        }"#;
        assert_eq!(
            serve_status_https_ports(raw, "127.0.0.1", 7878),
            ServePorts {
                ours: vec![443],
                all: vec![443]
            }
        );
        assert_eq!(
            serve_status_https_ports(raw, "127.0.0.1", 9999),
            ServePorts {
                ours: vec![],
                all: vec![443]
            }
        );
    }

    #[test]
    fn serve_status_reports_the_actual_https_port() {
        let raw = br#"{
            "Web": {
                "host.tail.ts.net:8443": {
                    "Handlers": {"/": {"Proxy": "http://127.0.0.1:7878"}}
                }
            }
        }"#;
        assert_eq!(
            serve_status_https_ports(raw, "127.0.0.1", 7878).ours,
            vec![8443]
        );
    }

    #[test]
    fn serve_status_matches_localhost_and_specific_bind() {
        let raw =
            br#"{"Web":{"h.t.ts.net:443":{"Handlers":{"/":{"Proxy":"http://localhost:7878/"}}}}}"#;
        assert_eq!(
            serve_status_https_ports(raw, "0.0.0.0", 7878).ours,
            vec![443]
        );
        let raw =
            br#"{"Web":{"h.t.ts.net:443":{"Handlers":{"/":{"Proxy":"http://192.168.1.5:7878"}}}}}"#;
        assert_eq!(
            serve_status_https_ports(raw, "192.168.1.5", 7878).ours,
            vec![443]
        );
        assert!(serve_status_https_ports(raw, "127.0.0.1", 7878)
            .ours
            .is_empty());
    }

    #[test]
    fn serve_status_matches_bracketed_bind_host() {
        let raw = br#"{
            "Web": {
                "h.t.ts.net:443": {
                    "Handlers": {"/": {"Proxy": "http://[fd7a::1]:7878"}}
                }
            }
        }"#;
        assert_eq!(
            serve_status_https_ports(raw, "[fd7a::1]", 7878).ours,
            vec![443]
        );
        assert_eq!(
            serve_status_https_ports(raw, "fd7a::1", 7878).ours,
            vec![443]
        );
    }

    #[test]
    fn serve_status_reports_every_matching_port() {
        let raw = br#"{
            "Web": {
                "h.t.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:7878"}}},
                "h.t.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:7878"}}}
            }
        }"#;
        let ports = serve_status_https_ports(raw, "127.0.0.1", 7878);
        assert_eq!(ports.ours, vec![443, 8443]);
        assert_eq!(ports.all, vec![443, 8443]);
    }

    #[test]
    fn serve_status_ignores_unrelated_json() {
        assert_eq!(
            serve_status_https_ports(br#"{}"#, "127.0.0.1", 7878),
            ServePorts::default()
        );
        assert_eq!(
            serve_status_https_ports(b"garbage", "127.0.0.1", 7878),
            ServePorts::default()
        );
        // A Proxy outside a Web entry has no https port to report.
        let raw = br#"{"Proxy":"http://127.0.0.1:7878"}"#;
        assert_eq!(
            serve_status_https_ports(raw, "127.0.0.1", 7878),
            ServePorts::default()
        );
    }

    #[test]
    fn stderr_classification() {
        assert_eq!(
            classify_stderr(b"error: handler does not exist"),
            StderrDiagnostic::NoExistingHandler
        );
        assert_eq!(
            classify_stderr(b"Tailscale is not logged in"),
            StderrDiagnostic::NotLoggedIn
        );
        assert_eq!(
            classify_stderr(b"Access denied"),
            StderrDiagnostic::PermissionDenied
        );
        assert_eq!(
            classify_stderr(b"something else entirely"),
            StderrDiagnostic::Unknown
        );
        assert_eq!(classify_stderr(b""), StderrDiagnostic::Unknown);
    }

    #[cfg(unix)]
    mod fake_bin {
        use super::*;
        use std::io::Write;
        use std::os::unix::fs::PermissionsExt;

        /// Write a shell script that answers the tailscale subcommands we use.
        /// `serve` mutations append their args to a log file the test reads.
        fn make_fake(script_body: &str) -> (tempfile::TempDir, Tailscale) {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("tailscale");
            let mut f = std::fs::File::create(&path).unwrap();
            f.write_all(script_body.as_bytes()).unwrap();
            let mut perms = f.metadata().unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&path, perms).unwrap();
            (dir, Tailscale::new(path.to_string_lossy().to_string()))
        }

        #[tokio::test]
        async fn missing_binary_reports_not_installed() {
            let ts = Tailscale::new("definitely-no-tailscale-binary-xyz");
            assert!(matches!(
                ts.read_status().await,
                Err(TailscaleError::NotInstalled)
            ));
            assert!(matches!(
                ts.ensure_serve("http://127.0.0.1:7878", 443).await,
                Err(TailscaleError::NotInstalled)
            ));
        }

        #[tokio::test]
        async fn status_parses_cli_json() {
            let (_dir, ts) = make_fake(
                "#!/bin/sh\n\
                 if [ \"$1\" = status ]; then\n\
                   echo '{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"h.t.ts.net.\",\"TailscaleIPs\":[\"100.1.2.3\"]}}'\n\
                 else\n\
                   echo '{}' >&2; exit 0\n\
                 fi\n",
            );
            let status = ts.read_status().await.unwrap();
            assert_eq!(status.magic_dns_name.as_deref(), Some("h.t.ts.net"));
        }

        #[tokio::test]
        async fn ensure_serve_invokes_bg_https() {
            let dir = tempfile::tempdir().unwrap();
            let log = dir.path().join("args.log");
            let script = format!("#!/bin/sh\necho \"$@\" >> '{}'\n", log.display());
            let path = dir.path().join("tailscale");
            std::fs::write(&path, &script).unwrap();
            let mut perms = std::fs::metadata(&path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&path, perms).unwrap();

            let ts = Tailscale::new(path.to_string_lossy().to_string());
            ts.ensure_serve("http://127.0.0.1:7878", 443).await.unwrap();
            ts.disable_serve(443).await.unwrap();
            let logged = std::fs::read_to_string(&log).unwrap();
            assert!(logged.contains("serve --bg --https=443 http://127.0.0.1:7878"));
            assert!(logged.contains("serve --https=443 off"));
        }

        #[tokio::test]
        async fn disable_serve_tolerates_missing_handler() {
            let (_dir, ts) = make_fake("#!/bin/sh\necho 'handler does not exist' >&2\nexit 1\n");
            ts.disable_serve(443).await.unwrap();
        }

        #[tokio::test]
        async fn serve_https_ports_reads_serve_status() {
            let (_dir, ts) = make_fake(
                "#!/bin/sh\n\
                 if [ \"$2\" = status ]; then\n\
                   echo '{\"Web\":{\"h.t.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7878\"}}}}}'\n\
                 else\n\
                   echo '{}'\n\
                 fi\n",
            );
            let ports = ts.serve_https_ports("127.0.0.1", 7878).await.unwrap();
            assert_eq!(ports.ours, vec![443]);
            let ports = ts.serve_https_ports("127.0.0.1", 9999).await.unwrap();
            assert!(ports.ours.is_empty());
            assert_eq!(ports.all, vec![443]);
        }
    }
}
