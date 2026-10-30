//! MCP (Model Context Protocol) server configuration.
//!
//! The owner manages a JSON list of MCP servers in Settings; entries are
//! either a local `command`/`args`/`env` triple (stdio) or a remote `url`
//! with optional `headers` (Streamable HTTP or legacy SSE). The list reaches
//! the agent differently per provider:
//!
//! - ACP agents (OpenCode, Grok) get it through `session/new` and
//!   `session/load`, filtered by the transports the agent advertises.
//! - The Devin CLI gets it merged into `devin/mcp_config.json` under the
//!   temporary `XDG_CONFIG_HOME` the permission config already builds.
//! - Codex gets it merged into `config.toml` under a temporary `CODEX_HOME`.

use std::collections::BTreeMap;

use agent_client_protocol::schema::v1::{
    EnvVariable, HttpHeader, McpCapabilities, McpServer, McpServerHttp, McpServerSse,
    McpServerStdio,
};
use serde::{Deserialize, Serialize};

/// One MCP server entry, as stored on the user row and exchanged with the
/// client. The field layout mirrors the common `mcpServers` JSON format.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpServerConfig {
    /// Server name; also namespaces its tools (`mcp__<name>__<tool>`).
    pub name: String,
    /// Disabled servers are kept in the list but never handed to agents.
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// `stdio`, `http`, or `sse`.
    #[serde(default = "default_transport")]
    pub transport: String,
    /// Executable for stdio servers.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub command: String,
    /// Command-line arguments for stdio servers.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// Extra environment for stdio servers.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    /// Endpoint for http/sse servers.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub url: String,
    /// Request headers for http/sse servers.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub headers: BTreeMap<String, String>,
}

fn default_true() -> bool {
    true
}

fn default_transport() -> String {
    "stdio".to_string()
}

/// Tool namespace of the builtin headless-browser server.
pub const BUILTIN_BROWSER_NAME: &str = "devinorium-browser";

/// Sentinel `command` marking the builtin browser server. It never reaches
/// an agent verbatim: [`McpServerConfig::resolved_stdio`] substitutes the
/// path of the currently-running devinorium binary plus the `browser-mcp`
/// argument at conversion time, so the same config works on the hub and on
/// satellites regardless of where each binary is installed.
pub const BUILTIN_BROWSER_COMMAND: &str = "internal://devinorium-browser";

/// The stdio MCP config injected when the owner's web-access setting is on.
pub fn builtin_browser() -> McpServerConfig {
    McpServerConfig {
        name: BUILTIN_BROWSER_NAME.to_string(),
        enabled: true,
        transport: "stdio".to_string(),
        command: BUILTIN_BROWSER_COMMAND.to_string(),
        args: Vec::new(),
        env: BTreeMap::new(),
        url: String::new(),
        headers: BTreeMap::new(),
    }
}

/// Append the builtin browser server to a run's MCP list when the user has
/// web access enabled. An enabled user server that already claims the name
/// wins: shadowing it would just confuse tool routing. A disabled one is
/// swapped out for the builtin so the toggle is not silently ignored.
pub fn inject_builtin_browser(servers: &mut Vec<McpServerConfig>, enabled: bool) {
    if !enabled {
        return;
    }
    if servers
        .iter()
        .any(|s| s.name == BUILTIN_BROWSER_NAME && s.enabled)
    {
        tracing::warn!(
            server = BUILTIN_BROWSER_NAME,
            "a user MCP server already uses the builtin browser name; not injecting"
        );
        return;
    }
    servers.retain(|s| s.name != BUILTIN_BROWSER_NAME);
    servers.push(builtin_browser());
}

impl McpServerConfig {
    pub fn is_remote(&self) -> bool {
        matches!(self.transport.as_str(), "http" | "sse")
    }

    /// `(command, args)` for a stdio server with builtins resolved: the
    /// browser sentinel becomes `<current_exe> browser-mcp` so the spawned
    /// server is always this host's own binary.
    fn resolved_stdio(&self) -> (String, Vec<String>) {
        if self.command.trim() == BUILTIN_BROWSER_COMMAND {
            let exe = std::env::current_exe()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| "devinorium".to_string());
            (exe, vec!["browser-mcp".to_string()])
        } else {
            (self.command.trim().to_string(), self.args.clone())
        }
    }

    /// The ACP `session/new` / `session/load` entry, or `None` when the
    /// transport is not one the agent advertised support for. stdio is
    /// mandatory in the spec, so it never gets filtered.
    pub fn to_acp(&self, caps: &McpCapabilities) -> Option<McpServer> {
        match self.transport.as_str() {
            "http" if caps.http => Some(McpServer::Http(
                McpServerHttp::new(self.name.trim().to_string(), self.url.trim().to_string())
                    .headers(http_headers(&self.headers)),
            )),
            "sse" if caps.sse => Some(McpServer::Sse(
                McpServerSse::new(self.name.trim().to_string(), self.url.trim().to_string())
                    .headers(http_headers(&self.headers)),
            )),
            "stdio" => {
                let (command, args) = self.resolved_stdio();
                Some(McpServer::Stdio(
                    McpServerStdio::new(self.name.trim().to_string(), command)
                        .args(args)
                        .env(env_vars(&self.env)),
                ))
            }
            _ => None,
        }
    }

    /// Devin CLI `mcp_config.json` `mcpServers` entry. `disabled` is only
    /// written when set so enabled entries stay minimal.
    pub fn to_devin_entry(&self) -> serde_json::Value {
        let mut entry = if self.is_remote() {
            serde_json::json!({
                "url": self.url,
                "transport": self.transport,
                "headers": self.headers,
            })
        } else {
            let (command, args) = self.resolved_stdio();
            serde_json::json!({
                "command": command,
                "args": args,
                "env": self.env,
            })
        };
        if !self.enabled {
            entry["disabled"] = serde_json::json!(true);
        }
        entry
    }

    /// Codex `[mcp_servers.<name>]` table. `None` for SSE, which Codex's
    /// streamable-HTTP client cannot express.
    pub fn to_codex_entry(&self) -> Option<toml::Value> {
        let mut table = toml::map::Map::new();
        table.insert("enabled".to_string(), toml::Value::Boolean(self.enabled));
        match self.transport.as_str() {
            "stdio" => {
                let (command, args) = self.resolved_stdio();
                table.insert("command".to_string(), toml::Value::String(command));
                if !args.is_empty() {
                    table.insert(
                        "args".to_string(),
                        toml::Value::Array(args.into_iter().map(toml::Value::String).collect()),
                    );
                }
                if !self.env.is_empty() {
                    table.insert(
                        "env".to_string(),
                        toml::Value::Table(string_table(&self.env)),
                    );
                }
            }
            "http" => {
                table.insert("url".to_string(), toml::Value::String(self.url.clone()));
                if !self.headers.is_empty() {
                    table.insert(
                        "http_headers".to_string(),
                        toml::Value::Table(string_table(&self.headers)),
                    );
                }
            }
            _ => return None,
        }
        Some(toml::Value::Table(table))
    }
}

fn env_vars(env: &BTreeMap<String, String>) -> Vec<EnvVariable> {
    env.iter()
        .map(|(k, v)| EnvVariable::new(k.clone(), v.clone()))
        .collect()
}

fn http_headers(headers: &BTreeMap<String, String>) -> Vec<HttpHeader> {
    headers
        .iter()
        .map(|(k, v)| HttpHeader::new(k.clone(), v.clone()))
        .collect()
}

fn string_table(map: &BTreeMap<String, String>) -> toml::map::Map<String, toml::Value> {
    map.iter()
        .map(|(k, v)| (k.clone(), toml::Value::String(v.clone())))
        .collect()
}

/// Largest accepted server list; keeps a runaway settings write from
/// growing the user row without bound.
pub const MAX_MCP_SERVERS: usize = 64;

/// The character set MCP tool namespaces rely on (`mcp__<name>__<tool>`):
/// alphanumerics, `-`, `_`, `.`; must start with an alphanumeric.
pub(crate) fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphanumeric())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

fn valid_env_key(key: &str) -> bool {
    !key.is_empty() && !key.contains(['=', '\0', '\n', '\r'])
}

fn valid_header_name(name: &str) -> bool {
    !name.is_empty()
        && name.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '!' | '#' | '$' | '%' | '&' | '\'')
        })
}

fn valid_url(url: &str) -> bool {
    let Ok(u) = reqwest::Url::parse(url) else {
        return false;
    };
    matches!(u.scheme(), "http" | "https") && !u.host_str().unwrap_or("").is_empty()
}

/// Validate one entry. Returns a user-facing error message.
pub fn validate_server(server: &McpServerConfig) -> Result<(), String> {
    if server.name != server.name.trim() {
        return Err(format!(
            "server name {:?} must not have leading or trailing whitespace",
            server.name
        ));
    }
    if !valid_name(server.name.trim()) {
        return Err(format!(
            "invalid server name {:?}: use 1-64 letters, digits, -, _ or ., starting with a letter or digit",
            server.name
        ));
    }
    match server.transport.as_str() {
        "stdio" => {
            if server.command.trim().is_empty() {
                return Err(format!("server {:?} needs a command", server.name));
            }
            for key in server.env.keys() {
                if !valid_env_key(key) {
                    return Err(format!("server {:?} has an invalid env name", server.name));
                }
            }
        }
        "http" | "sse" => {
            if !valid_url(server.url.trim()) {
                return Err(format!(
                    "server {:?} needs an http:// or https:// url",
                    server.name
                ));
            }
            for key in server.headers.keys() {
                if !valid_header_name(key) {
                    return Err(format!(
                        "server {:?} has an invalid header name",
                        server.name
                    ));
                }
            }
        }
        other => {
            return Err(format!(
                "server {:?} has unknown transport {other:?}; use stdio, http or sse",
                server.name
            ))
        }
    }
    Ok(())
}

/// Validate a whole list for storage: size cap, per-entry validation, and
/// unique names (the name keys every provider's config map).
pub fn validate_servers(servers: &[McpServerConfig]) -> Result<(), String> {
    if servers.len() > MAX_MCP_SERVERS {
        return Err(format!("too many servers (max {MAX_MCP_SERVERS})"));
    }
    let mut seen = std::collections::HashSet::new();
    for server in servers {
        validate_server(server)?;
        if !seen.insert(server.name.trim().to_string()) {
            return Err(format!("duplicate server name {:?}", server.name));
        }
    }
    Ok(())
}

/// The enabled subset handed to providers at run start.
pub fn enabled_servers(servers: &[McpServerConfig]) -> impl Iterator<Item = &McpServerConfig> {
    servers.iter().filter(|s| s.enabled)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stdio(name: &str) -> McpServerConfig {
        McpServerConfig {
            name: name.into(),
            enabled: true,
            transport: "stdio".into(),
            command: "npx".into(),
            args: vec!["-y".into(), "pkg".into()],
            env: BTreeMap::from([("TOKEN".to_string(), "x".to_string())]),
            url: String::new(),
            headers: BTreeMap::new(),
        }
    }

    fn http(name: &str) -> McpServerConfig {
        McpServerConfig {
            name: name.into(),
            enabled: true,
            transport: "http".into(),
            command: String::new(),
            args: vec![],
            env: BTreeMap::new(),
            url: "https://mcp.example.com/mcp".into(),
            headers: BTreeMap::from([("Authorization".to_string(), "Bearer t".to_string())]),
        }
    }

    #[test]
    fn validate_accepts_stdio_and_http() {
        assert!(validate_server(&stdio("github")).is_ok());
        assert!(validate_server(&http("notion")).is_ok());
    }

    #[test]
    fn validate_rejects_bad_name() {
        let mut s = stdio("");
        assert!(validate_server(&s).is_err());
        s.name = "bad name!".into();
        assert!(validate_server(&s).is_err());
        s.name = "-leading-dash".into();
        assert!(validate_server(&s).is_err());
        s.name = "ok_name-1.2".into();
        assert!(validate_server(&s).is_ok());
    }

    #[test]
    fn validate_rejects_missing_command_and_bad_url() {
        let mut s = stdio("x");
        s.command = "  ".into();
        assert!(validate_server(&s).is_err());
        let mut h = http("x");
        h.url = "ftp://nope".into();
        assert!(validate_server(&h).is_err());
    }

    #[test]
    fn validate_rejects_unknown_transport_and_dupes() {
        let mut s = stdio("x");
        s.transport = "grpc".into();
        assert!(validate_server(&s).is_err());
        assert!(validate_servers(&[stdio("a"), stdio("a")]).is_err());
        assert!(validate_servers(&[stdio("a"), http("a")]).is_err());
        assert!(validate_servers(&[stdio("a"), http("b")]).is_ok());
    }

    #[test]
    fn acp_stdio_maps_command_args_env() {
        let caps = McpCapabilities::default();
        let McpServer::Stdio(s) = stdio("gh").to_acp(&caps).unwrap() else {
            panic!("expected stdio")
        };
        assert_eq!(s.name, "gh");
        assert_eq!(s.command, std::path::PathBuf::from("npx"));
        assert_eq!(s.args, vec!["-y", "pkg"]);
        assert_eq!(s.env.len(), 1);
        assert_eq!(s.env[0].name, "TOKEN");
    }

    #[test]
    fn builtin_browser_resolves_to_current_exe() {
        // The sentinel command never reaches an agent: every conversion
        // substitutes this host's own binary + `browser-mcp`, which is what
        // makes the same config work on hub and satellites.
        let server = builtin_browser();
        let exe = std::env::current_exe()
            .unwrap()
            .to_string_lossy()
            .to_string();

        let caps = McpCapabilities::default();
        let McpServer::Stdio(s) = server.to_acp(&caps).unwrap() else {
            panic!("expected stdio")
        };
        assert_eq!(s.name, BUILTIN_BROWSER_NAME);
        assert_eq!(s.command, std::path::PathBuf::from(&exe));
        assert_eq!(s.args, vec!["browser-mcp"]);

        let devin = server.to_devin_entry();
        assert_eq!(devin["command"], exe);
        assert_eq!(devin["args"], serde_json::json!(["browser-mcp"]));
        assert!(devin.get("disabled").is_none());

        let toml::Value::Table(codex) = server.to_codex_entry().unwrap() else {
            panic!("expected table")
        };
        assert_eq!(codex["command"], toml::Value::String(exe.clone()));
        assert_eq!(
            codex["args"],
            toml::Value::Array(vec![toml::Value::String("browser-mcp".into())])
        );
        assert_eq!(codex["enabled"], toml::Value::Boolean(true));
    }

    #[test]
    fn inject_builtin_browser_respects_flag_and_name_clash() {
        let mut servers = vec![stdio("mine")];
        inject_builtin_browser(&mut servers, false);
        assert_eq!(servers.len(), 1);

        inject_builtin_browser(&mut servers, true);
        assert_eq!(servers.len(), 2);
        assert_eq!(servers[1].name, BUILTIN_BROWSER_NAME);
        assert_eq!(servers[1].command, BUILTIN_BROWSER_COMMAND);

        // Idempotent: a second injection does not duplicate the server, and
        // a user server that already claims the name is left untouched.
        let mut clash = vec![McpServerConfig {
            name: BUILTIN_BROWSER_NAME.into(),
            ..stdio("user-owned")
        }];
        inject_builtin_browser(&mut clash, true);
        assert_eq!(clash.len(), 1);
        assert_eq!(clash[0].command, "npx");
    }

    #[test]
    fn acp_remote_respects_capabilities() {
        let caps = McpCapabilities::default(); // http=false, sse=false
        assert!(http("n").to_acp(&caps).is_none());
        let caps = McpCapabilities::new().http(true).sse(true);
        match http("n").to_acp(&caps).unwrap() {
            McpServer::Http(h) => {
                assert_eq!(h.url, "https://mcp.example.com/mcp");
                assert_eq!(h.headers[0].name, "Authorization");
            }
            other => panic!("expected http, got {other:?}"),
        }
        let mut sse = http("s");
        sse.transport = "sse".into();
        match sse.to_acp(&caps).unwrap() {
            McpServer::Sse(s) => assert_eq!(s.url, "https://mcp.example.com/mcp"),
            other => panic!("expected sse, got {other:?}"),
        }
    }

    #[test]
    fn devin_entry_marks_disabled_and_transports() {
        let mut s = stdio("x");
        s.enabled = false;
        let v = s.to_devin_entry();
        assert_eq!(v["command"], "npx");
        assert_eq!(v["disabled"], true);
        let h = http("n").to_devin_entry();
        assert_eq!(h["url"], "https://mcp.example.com/mcp");
        assert_eq!(h["transport"], "http");
        assert!(h.get("disabled").is_none());
    }

    #[test]
    fn codex_entry_maps_stdio_and_http_not_sse() {
        let t = stdio("x").to_codex_entry().unwrap();
        assert_eq!(t["command"].as_str(), Some("npx"));
        assert_eq!(t["env"]["TOKEN"].as_str(), Some("x"));
        let t = http("n").to_codex_entry().unwrap();
        assert_eq!(t["url"].as_str(), Some("https://mcp.example.com/mcp"));
        assert_eq!(
            t["http_headers"]["Authorization"].as_str(),
            Some("Bearer t")
        );
        let mut sse = http("s");
        sse.transport = "sse".into();
        assert!(sse.to_codex_entry().is_none());
    }

    #[test]
    fn config_round_trips_as_json() {
        let servers = vec![stdio("a"), http("b")];
        let json = serde_json::to_string(&servers).unwrap();
        let back: Vec<McpServerConfig> = serde_json::from_str(&json).unwrap();
        assert_eq!(back, servers);
    }

    #[test]
    fn defaults_fill_enabled_and_transport() {
        let s: McpServerConfig = serde_json::from_str(r#"{"name":"x","command":"npx"}"#).unwrap();
        assert!(s.enabled);
        assert_eq!(s.transport, "stdio");
    }
}
