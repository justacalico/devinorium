//! MCPB (.mcpb) bundle support.
//!
//! An `.mcpb` file is a zip archive with a `manifest.json` at its root that
//! packages a local stdio MCP server: metadata, an entry point, an
//! `mcp_config` (command/args/env with `${...}` placeholders), and a
//! `user_config` schema for values the owner must supply at install time.
//! Inspecting a bundle parses the manifest only; installing extracts the
//! archive under `bundle_root` and resolves the placeholders into a regular
//! [`McpServerConfig`] the existing providers already know how to run.

use std::collections::BTreeMap;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::config::Config;
use crate::mcp::{validate_server, McpServerConfig};

/// Hard cap on the uploaded archive; the multipart body limit is usually
/// smaller. Bundles shipping `node_modules` get large, so this stays generous.
pub const MAX_MCPB_BYTES: usize = 256 * 1024 * 1024;
/// Cap on `manifest.json`; a manifest past this is malformed or hostile.
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
/// Extraction caps: entry count and total decompressed size.
const MAX_MCPB_FILES: usize = 20_000;
const MAX_MCPB_TOTAL_BYTES: u64 = 512 * 1024 * 1024;
/// Cap on any single extracted file.
const MAX_MCPB_FILE_BYTES: u64 = 256 * 1024 * 1024;

/// One `user_config` field from the manifest, surfaced to the client so the
/// settings dialog can render the right input before installing.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct McpbUserConfig {
    pub key: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub title: String,
    pub description: String,
    pub required: bool,
    pub sensitive: bool,
    pub multiple: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max: Option<f64>,
}

/// The manifest summary returned by the inspect endpoint.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct McpbInspection {
    pub name: String,
    pub display_name: String,
    pub version: String,
    pub description: String,
    pub author: String,
    pub license: String,
    pub homepage: String,
    /// `node`, `python`, `binary` or `uv`.
    pub server_type: String,
    pub user_config: Vec<McpbUserConfig>,
    /// Non-fatal problems: unsupported platform, unknown placeholders, ...
    pub warnings: Vec<String>,
}

/// A successful install: the inspection plus the resolved server entry.
#[derive(Debug)]
pub struct McpbInstall {
    pub inspection: McpbInspection,
    pub server: McpServerConfig,
}

#[derive(Debug, Deserialize)]
struct RawManifest {
    name: String,
    version: Option<String>,
    description: Option<String>,
    display_name: Option<String>,
    author: Option<RawAuthor>,
    license: Option<String>,
    homepage: Option<String>,
    server: Option<RawServer>,
    #[serde(default)]
    user_config: BTreeMap<String, RawUserConfig>,
    compatibility: Option<RawCompatibility>,
}

#[derive(Debug, Deserialize)]
struct RawAuthor {
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawServer {
    #[serde(rename = "type", default)]
    server_type: String,
    entry_point: Option<String>,
    mcp_config: Option<RawMcpConfig>,
}

#[derive(Debug, Default, Clone, Deserialize)]
struct RawMcpConfig {
    command: Option<String>,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default)]
    env: BTreeMap<String, String>,
    #[serde(default)]
    platform_overrides: BTreeMap<String, RawOverride>,
}

/// A `platform_overrides` entry: any subset of the `mcp_config` fields,
/// applied over the base config on the matching platform.
#[derive(Debug, Default, Clone, Deserialize)]
struct RawOverride {
    command: Option<String>,
    args: Option<Vec<String>>,
    env: Option<BTreeMap<String, String>>,
}

#[derive(Debug, Default, Deserialize)]
struct RawUserConfig {
    #[serde(rename = "type", default = "default_config_kind")]
    kind: String,
    title: Option<String>,
    description: Option<String>,
    #[serde(default)]
    required: bool,
    #[serde(default)]
    sensitive: bool,
    #[serde(default)]
    multiple: bool,
    default: Option<Value>,
    min: Option<f64>,
    max: Option<f64>,
}

fn default_config_kind() -> String {
    "string".to_string()
}

#[derive(Debug, Deserialize)]
struct RawCompatibility {
    platforms: Option<Vec<String>>,
}

/// The Node-style platform name used by `compatibility.platforms` and
/// `platform_overrides`: `darwin`, `win32`, `linux`, else the raw `cfg` OS.
fn current_platform() -> &'static str {
    match std::env::consts::OS {
        "macos" => "darwin",
        "windows" => "win32",
        os => os,
    }
}

/// Read `manifest.json` out of the archive without extracting anything.
fn read_manifest(bytes: &[u8]) -> Result<RawManifest, String> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
        .map_err(|e| format!("not a valid .mcpb archive: {e}"))?;
    let entry = archive
        .by_name("manifest.json")
        .map_err(|_| "bundle has no manifest.json".to_string())?;
    if entry.size() > MAX_MANIFEST_BYTES {
        return Err("manifest.json is too large".to_string());
    }
    let mut text = String::new();
    entry
        .take(MAX_MANIFEST_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|e| format!("cannot read manifest.json: {e}"))?;
    if text.len() as u64 > MAX_MANIFEST_BYTES {
        return Err("manifest.json is too large".to_string());
    }
    serde_json::from_str(&text).map_err(|e| format!("invalid manifest.json: {e}"))
}

fn user_config_fields(manifest: &RawManifest) -> Vec<McpbUserConfig> {
    manifest
        .user_config
        .iter()
        .map(|(key, f)| McpbUserConfig {
            key: key.clone(),
            kind: f.kind.clone(),
            title: f.title.clone().unwrap_or_else(|| key.clone()),
            description: f.description.clone().unwrap_or_default(),
            required: f.required,
            sensitive: f.sensitive,
            multiple: f.multiple,
            default: f.default.clone(),
            min: f.min,
            max: f.max,
        })
        .collect()
}

/// The `${...}` variable tokens appearing in a string.
fn variable_tokens(input: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut rest = input;
    while let Some(start) = rest.find("${") {
        let after = &rest[start + 2..];
        match after.find('}') {
            Some(end) => {
                tokens.push(after[..end].to_string());
                rest = &after[end + 1..];
            }
            None => break,
        }
    }
    tokens
}

/// Variables known to the substituter besides `user_config.*` entries.
fn is_known_variable(name: &str) -> bool {
    matches!(
        name,
        "__dirname" | "HOME" | "DESKTOP" | "DOCUMENTS" | "DOWNLOADS" | "pathSeparator" | "/"
    )
}

fn platform_supported(manifest: &RawManifest) -> bool {
    match manifest
        .compatibility
        .as_ref()
        .and_then(|c| c.platforms.as_ref())
    {
        Some(platforms) => platforms.iter().any(|p| p == current_platform()),
        None => true,
    }
}

/// Collect warnings: unsupported platform, undeclared `${user_config.*}`
/// references, and unknown `${...}` tokens in `mcp_config`.
fn manifest_warnings(manifest: &RawManifest) -> Vec<String> {
    let mut warnings = Vec::new();
    if !platform_supported(manifest) {
        warnings.push(format!(
            "bundle does not list {:?} as a supported platform",
            current_platform()
        ));
    }
    let mut tokens = Vec::new();
    if let Some(cfg) = manifest.server.as_ref().and_then(|s| s.mcp_config.as_ref()) {
        if let Some(c) = cfg.command.as_ref() {
            tokens.extend(variable_tokens(c));
        }
        for a in &cfg.args {
            tokens.extend(variable_tokens(a));
        }
        for v in cfg.env.values() {
            tokens.extend(variable_tokens(v));
        }
        if let Some(over) = cfg.platform_overrides.get(current_platform()) {
            if let Some(c) = over.command.as_ref() {
                tokens.extend(variable_tokens(c));
            }
            for a in over.args.iter().flatten() {
                tokens.extend(variable_tokens(a));
            }
            if let Some(env) = over.env.as_ref() {
                for v in env.values() {
                    tokens.extend(variable_tokens(v));
                }
            }
        }
    }
    let mut seen = std::collections::HashSet::new();
    for token in tokens {
        if !seen.insert(token.clone()) {
            continue;
        }
        if let Some(key) = token.strip_prefix("user_config.") {
            if !manifest.user_config.contains_key(key) {
                warnings.push(format!(
                    "manifest references undeclared user config {key:?}"
                ));
            }
        } else if !is_known_variable(&token) {
            warnings.push(format!("manifest uses unknown variable ${{{token}}}"));
        }
    }
    warnings
}

/// Windows device names; a bundle named `con` or `nul` would break
/// directory creation on a Windows host.
fn is_reserved_name(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or(name).to_ascii_lowercase();
    matches!(
        stem.as_str(),
        "con"
            | "prn"
            | "aux"
            | "nul"
            | "com1"
            | "com2"
            | "com3"
            | "com4"
            | "com5"
            | "com6"
            | "com7"
            | "com8"
            | "com9"
            | "lpt1"
            | "lpt2"
            | "lpt3"
            | "lpt4"
            | "lpt5"
            | "lpt6"
            | "lpt7"
            | "lpt8"
            | "lpt9"
    )
}

fn validate_manifest(manifest: &RawManifest) -> Result<(), String> {
    if !crate::mcp::valid_name(&manifest.name) || is_reserved_name(&manifest.name) {
        return Err(format!(
            "invalid bundle name {:?}: use 1-64 letters, digits, -, _ or ., starting with a letter or digit",
            manifest.name
        ));
    }
    let server = manifest
        .server
        .as_ref()
        .ok_or_else(|| "manifest has no server section".to_string())?;
    match server.server_type.as_str() {
        "node" | "python" | "binary" | "uv" => {}
        "" => return Err("manifest server.type is missing".to_string()),
        other => {
            return Err(format!(
                "unsupported server.type {other:?}; use node, python, binary or uv"
            ))
        }
    }
    // The entry point must stay inside the bundle dir.
    if let Some(ep) = server.entry_point.as_deref() {
        if ep.is_empty()
            || Path::new(ep)
                .components()
                .any(|c| !matches!(c, std::path::Component::Normal(_)))
        {
            return Err(format!("invalid entry point {ep:?}"));
        }
    }
    let has_command = server
        .mcp_config
        .as_ref()
        .and_then(|c| c.command.as_ref())
        .is_some_and(|c| !c.trim().is_empty());
    if !has_command && server.entry_point.is_none() {
        return Err(
            "manifest has neither server.mcp_config.command nor server.entry_point".to_string(),
        );
    }
    Ok(())
}

fn inspection(manifest: &RawManifest) -> McpbInspection {
    McpbInspection {
        name: manifest.name.clone(),
        display_name: manifest
            .display_name
            .clone()
            .unwrap_or_else(|| manifest.name.clone()),
        version: manifest.version.clone().unwrap_or_default(),
        description: manifest.description.clone().unwrap_or_default(),
        author: manifest
            .author
            .as_ref()
            .and_then(|a| a.name.clone())
            .unwrap_or_default(),
        license: manifest.license.clone().unwrap_or_default(),
        homepage: manifest.homepage.clone().unwrap_or_default(),
        server_type: manifest
            .server
            .as_ref()
            .map(|s| s.server_type.clone())
            .unwrap_or_default(),
        user_config: user_config_fields(manifest),
        warnings: manifest_warnings(manifest),
    }
}

/// Parse a bundle's manifest and report what installing it would look like.
/// Reads only `manifest.json`; nothing touches disk.
pub fn inspect_bundle(bytes: &[u8]) -> Result<McpbInspection, String> {
    if bytes.len() > MAX_MCPB_BYTES {
        return Err("bundle is too large".to_string());
    }
    let manifest = read_manifest(bytes)?;
    validate_manifest(&manifest)?;
    Ok(inspection(&manifest))
}

/// Directory `.mcpb` bundles extract into. A file-backed sqlite database
/// puts them next to the db (`data/mcp-bundles`); the in-memory dev database
/// has no home of its own, so bundles land in a temp dir instead. The path
/// is always absolute — `${__dirname}` embeds it in stored server args and
/// agents run from other working directories.
pub fn bundle_root(config: &Config) -> PathBuf {
    let root = if let Some(spec) = config.db_url.strip_prefix("sqlite:") {
        let path = spec.split('?').next().unwrap_or("");
        if !path.is_empty() && path != ":memory:" {
            match Path::new(path).parent() {
                Some(parent) if !parent.as_os_str().is_empty() => parent.join("mcp-bundles"),
                // Bare filename like `devinorium.db`: sit beside it via cwd.
                _ => Path::new(".").join("mcp-bundles"),
            }
        } else {
            std::env::temp_dir().join("devinorium-mcp-bundles")
        }
    } else {
        std::env::temp_dir().join("devinorium-mcp-bundles")
    };
    if root.is_absolute() {
        root
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(root)
    }
}

/// The extracted bundle directory for a manifest name. The name already
/// passed `valid_name`, so it cannot escape `root`.
fn bundle_dir(root: &Path, name: &str) -> PathBuf {
    root.join(name)
}

/// `${DESKTOP}`/`${DOCUMENTS}`/`${DOWNLOADS}` resolve under the home dir.
fn named_home_dir(home: &Path, name: &str) -> PathBuf {
    home.join(name)
}

/// Resolve a `user_config` value to a single string for embedded
/// substitution. Arrays join with `,` — the common convention for list env
/// vars; args that want real expansion go through `config_value_items`.
fn config_value_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Array(items) => items
            .iter()
            .map(config_value_string)
            .collect::<Vec<_>>()
            .join(","),
        _ => String::new(),
    }
}

/// Resolve a `user_config` value to the list of strings it expands to when
/// it fills a whole arg: arrays become one arg per element, everything else
/// stays a single arg.
fn config_value_items(value: &Value) -> Vec<String> {
    match value {
        Value::Array(items) => items.iter().map(config_value_string).collect(),
        other => vec![config_value_string(other)],
    }
}

/// Check one supplied `user_config` value against the field's declared
/// type: `string`/`directory`/`file` take strings, `number` takes numbers
/// with `min`/`max` enforced, `boolean` takes bools, and `multiple` fields
/// take an array of the scalar type.
fn check_user_config_value(key: &str, field: &RawUserConfig, value: &Value) -> Result<(), String> {
    let scalar_ok = |v: &Value| match field.kind.as_str() {
        "number" => v.is_number(),
        "boolean" => v.is_boolean(),
        _ => v.is_string(),
    };
    let values: Vec<&Value> = match value {
        Value::Array(items) if field.multiple => items.iter().collect(),
        Value::Array(_) => return Err(format!("config {key:?} does not accept a list")),
        v => vec![v],
    };
    if values.iter().any(|v| v.is_null()) {
        return Err(format!("config {key:?} must not be null"));
    }
    if !values.iter().all(|v| scalar_ok(v)) {
        return Err(format!("config {key:?} must be a {}", field.kind));
    }
    if field.kind == "number" {
        for v in &values {
            let n = v.as_f64().unwrap_or_default();
            if let Some(min) = field.min {
                if n < min {
                    return Err(format!("config {key:?} must be at least {min}"));
                }
            }
            if let Some(max) = field.max {
                if n > max {
                    return Err(format!("config {key:?} must be at most {max}"));
                }
            }
        }
    }
    Ok(())
}

/// Merge each manifest `user_config` entry with the value the owner sent:
/// supplied value, else manifest default, else an error when the field is
/// required.
fn resolve_user_config(
    manifest: &RawManifest,
    values: &Map<String, Value>,
) -> Result<Map<String, Value>, String> {
    let mut resolved = Map::new();
    let mut missing = Vec::new();
    for (key, field) in &manifest.user_config {
        let value = values.get(key).cloned().or_else(|| field.default.clone());
        match value {
            Some(v) => {
                check_user_config_value(key, field, &v)?;
                resolved.insert(key.clone(), v);
            }
            None => {
                if field.required {
                    missing.push(format!("{key:?}"));
                }
            }
        }
    }
    if !missing.is_empty() {
        return Err(format!(
            "missing required configuration: {}",
            missing.join(", ")
        ));
    }
    Ok(resolved)
}

/// Replace `${...}` tokens in `input` through `lookup`; unknown tokens pass
/// through unchanged so `${PATH}`-style references survive verbatim.
fn substitute(input: &str, lookup: &dyn Fn(&str) -> Option<String>) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        match after.find('}') {
            Some(end) => {
                let key = &after[..end];
                match lookup(key) {
                    Some(value) => out.push_str(&value),
                    None => {
                        out.push_str("${");
                        out.push_str(key);
                        out.push('}');
                    }
                }
                rest = &after[end + 1..];
            }
            None => {
                out.push_str(&rest[start..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

/// A base `mcp_config` for manifests that omit `command`: the conventional
/// per-type invocation of `entry_point`.
fn synthesized_config(manifest: &RawManifest) -> RawMcpConfig {
    let server = manifest.server.as_ref();
    let entry_point = server
        .and_then(|s| s.entry_point.clone())
        .unwrap_or_default();
    let dir_entry = format!("${{__dirname}}/{entry_point}");
    match server.map(|s| s.server_type.as_str()) {
        Some("node") => RawMcpConfig {
            command: Some("node".to_string()),
            args: vec![dir_entry],
            ..Default::default()
        },
        Some("python") => RawMcpConfig {
            command: Some(if cfg!(windows) { "python" } else { "python3" }.to_string()),
            args: vec![dir_entry],
            ..Default::default()
        },
        Some("binary") => RawMcpConfig {
            command: Some(dir_entry),
            ..Default::default()
        },
        // `uv` runs the entry point inside the bundle's project so
        // pyproject.toml dependencies resolve.
        Some("uv") => RawMcpConfig {
            command: Some("uv".to_string()),
            args: vec![
                "run".to_string(),
                "--project".to_string(),
                "${__dirname}".to_string(),
                dir_entry,
            ],
            ..Default::default()
        },
        _ => RawMcpConfig::default(),
    }
}

/// The manifest's `mcp_config` (or the synthesized default) with this
/// platform's `platform_overrides` applied.
fn effective_config(manifest: &RawManifest) -> Result<RawMcpConfig, String> {
    let server = manifest
        .server
        .as_ref()
        .ok_or_else(|| "manifest has no server section".to_string())?;
    let mut config = match server.mcp_config.clone() {
        Some(mut c) => {
            if c.command.as_deref().unwrap_or("").trim().is_empty() {
                let synth = synthesized_config(manifest);
                c.command = synth.command;
                if c.args.is_empty() {
                    c.args = synth.args;
                }
            }
            c
        }
        None => synthesized_config(manifest),
    };
    if let Some(over) = config.platform_overrides.get(current_platform()).cloned() {
        if let Some(c) = over.command {
            config.command = Some(c);
        }
        if let Some(a) = over.args {
            config.args = a;
        }
        if let Some(env) = over.env {
            config.env.extend(env);
        }
    }
    Ok(config)
}

/// Write every regular file in the archive under `dest`, rejecting entries
/// that escape it, symlinks, and anything past the size caps. Byte caps
/// count what actually lands on disk, not the declared sizes — a forged
/// header cannot shrink a bomb.
fn extract_zip(bytes: &[u8], dest: &Path, entry_point: Option<&str>) -> Result<(), String> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
        .map_err(|e| format!("not a valid .mcpb archive: {e}"))?;
    if archive.len() > MAX_MCPB_FILES {
        return Err(format!("bundle has too many files (max {MAX_MCPB_FILES})"));
    }
    std::fs::create_dir_all(dest).map_err(|e| format!("cannot create bundle dir: {e}"))?;
    let mut total: u64 = 0;
    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("cannot read archive entry: {e}"))?;
        if entry.is_dir() {
            continue;
        }
        let rel = entry
            .enclosed_name()
            .ok_or_else(|| format!("archive entry {:?} escapes the bundle dir", entry.name()))?;
        // Reject symlinks: a bundle could point one outside the dir and a
        // later file would write through it.
        if let Some(mode) = entry.unix_mode() {
            if mode & 0o170000 == 0o120000 {
                return Err(format!(
                    "archive entry {:?} is a symlink; bundles cannot contain links",
                    entry.name()
                ));
            }
        }
        let out = dest.join(&rel);
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        }
        let mut file = std::fs::File::create(&out)
            .map_err(|e| format!("cannot write {}: {e}", out.display()))?;
        let written = std::io::copy(&mut entry.by_ref().take(MAX_MCPB_FILE_BYTES + 1), &mut file)
            .map_err(|e| format!("cannot write {}: {e}", out.display()))?;
        if written > MAX_MCPB_FILE_BYTES {
            return Err(format!("archive entry {:?} is too large", entry.name()));
        }
        total += written;
        if total > MAX_MCPB_TOTAL_BYTES {
            return Err("bundle is too large once extracted".to_string());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = entry.unix_mode().unwrap_or(0o644);
            // Honour archive exec bits; the declared entry point is always
            // executable so binary bundles work from zip files that store
            // no permissions.
            let is_entry = entry_point.is_some_and(|ep| rel == Path::new(ep));
            let mode = if mode & 0o111 != 0 || is_entry {
                mode | 0o111
            } else {
                mode
            };
            let _ = std::fs::set_permissions(&out, std::fs::Permissions::from_mode(mode & 0o777));
        }
    }
    Ok(())
}

/// The `KEY` when `input` is exactly `${user_config.KEY}` and nothing else.
fn whole_user_config_ref(input: &str) -> Option<&str> {
    input
        .trim()
        .strip_prefix("${user_config.")
        .and_then(|k| k.strip_suffix('}'))
        .filter(|k| !k.is_empty() && !k.contains(['}', '{']))
}

/// Inspect, extract, and resolve a bundle into an [`McpServerConfig`]. The
/// archive lands at `root/<name>` — a previous install of the same name is
/// replaced wholesale. On failure the partially extracted dir is removed so
/// a broken bundle never leaves a runnable config behind.
pub fn install_bundle(
    bytes: &[u8],
    root: &Path,
    home: &Path,
    values: &Map<String, Value>,
) -> Result<McpbInstall, String> {
    if bytes.len() > MAX_MCPB_BYTES {
        return Err("bundle is too large".to_string());
    }
    let manifest = read_manifest(bytes)?;
    validate_manifest(&manifest)?;
    if !platform_supported(&manifest) {
        return Err(format!(
            "bundle does not support this platform ({})",
            current_platform()
        ));
    }
    let resolved = resolve_user_config(&manifest, values)?;

    std::fs::create_dir_all(root).map_err(|e| format!("cannot create bundle root: {e}"))?;
    let dest = bundle_dir(root, &manifest.name);
    if dest.exists() {
        std::fs::remove_dir_all(&dest)
            .map_err(|e| format!("cannot replace existing bundle dir: {e}"))?;
    }
    let entry_point = manifest.server.as_ref().and_then(|s| s.entry_point.clone());
    if let Err(e) = extract_zip(bytes, &dest, entry_point.as_deref()) {
        let _ = std::fs::remove_dir_all(&dest);
        return Err(e);
    }
    // `${__dirname}` lands in stored server args; it must be absolute.
    let dest = match std::fs::canonicalize(&dest) {
        Ok(d) => d,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&dest);
            return Err(format!("cannot resolve bundle dir: {e}"));
        }
    };

    // The entry point has to exist once extracted — either the config
    // references it directly or the synthesized config needs it.
    if let Some(ep) = entry_point.as_deref() {
        if !dest.join(ep).is_file() {
            let _ = std::fs::remove_dir_all(&dest);
            return Err(format!("entry point {ep:?} is not in the bundle"));
        }
    }

    let config = effective_config(&manifest)?;
    let dir_str = dest.to_string_lossy().to_string();
    let sep = std::path::MAIN_SEPARATOR.to_string();
    let lookup = |key: &str| -> Option<String> {
        match key {
            "__dirname" => Some(dir_str.clone()),
            "HOME" => Some(home.to_string_lossy().to_string()),
            "DESKTOP" => Some(
                named_home_dir(home, "Desktop")
                    .to_string_lossy()
                    .to_string(),
            ),
            "DOCUMENTS" => Some(
                named_home_dir(home, "Documents")
                    .to_string_lossy()
                    .to_string(),
            ),
            "DOWNLOADS" => Some(
                named_home_dir(home, "Downloads")
                    .to_string_lossy()
                    .to_string(),
            ),
            "pathSeparator" | "/" => Some(sep.clone()),
            _ => key
                .strip_prefix("user_config.")
                .and_then(|k| resolved.get(k))
                .map(config_value_string),
        }
    };

    let command = substitute(config.command.as_deref().unwrap_or("").trim(), &lookup);
    // A whole-arg `${user_config.x}` holding an array expands to one arg
    // per element, matching the spec's multi-select semantics. An unset
    // optional value drops the arg rather than passing the token verbatim.
    let mut args = Vec::new();
    for arg in &config.args {
        match whole_user_config_ref(arg) {
            Some(key) => match resolved.get(key) {
                Some(v @ Value::Array(_)) => args.extend(config_value_items(v)),
                Some(v) => args.push(config_value_string(v)),
                None => {}
            },
            None => args.push(substitute(arg, &lookup)),
        }
    }
    let env = config
        .env
        .iter()
        .filter(|(_, v)| whole_user_config_ref(v).is_none_or(|k| resolved.contains_key(k)))
        .map(|(k, v)| (k.clone(), substitute(v, &lookup)))
        .collect();

    // Windows binary bundles name the executable without the suffix; hosts
    // append it. Only when the .exe actually exists so `cmd`-style commands
    // are untouched.
    #[cfg(windows)]
    let command = if manifest
        .server
        .as_ref()
        .is_some_and(|s| s.server_type == "binary")
        && !command.to_ascii_lowercase().ends_with(".exe")
        && Path::new(&format!("{command}.exe")).is_file()
    {
        format!("{command}.exe")
    } else {
        command
    };

    let server = McpServerConfig {
        name: manifest.name.clone(),
        enabled: true,
        transport: "stdio".to_string(),
        command,
        args,
        env,
        url: String::new(),
        headers: BTreeMap::new(),
    };
    if let Err(e) = validate_server(&server) {
        let _ = std::fs::remove_dir_all(&dest);
        return Err(e);
    }
    Ok(McpbInstall {
        inspection: inspection(&manifest),
        server,
    })
}

/// Delete extracted bundle dirs no remaining server references. Runs after
/// the server list is written, so deleting or renaming a bundle-installed
/// server also removes its files. Only dirs containing a `manifest.json`
/// are touched; a dir stays if any server's command, args, or env still
/// point into it. Paths are canonicalized on both sides so a relative root
/// or a symlinked component cannot make a referenced dir look stale.
pub fn prune_bundles(root: &Path, servers: &[McpServerConfig]) {
    let root = match std::fs::canonicalize(root) {
        Ok(r) => r,
        Err(_) => return,
    };
    let entries = match std::fs::read_dir(&root) {
        Ok(e) => e,
        Err(_) => return,
    };
    let referenced = |dir: &Path| {
        let dir = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
        let dir_str = dir.to_string_lossy();
        let prefix = format!("{dir_str}{}", std::path::MAIN_SEPARATOR);
        servers.iter().any(|s| {
            std::iter::once(&s.command)
                .chain(s.args.iter())
                .chain(s.env.values())
                .any(|v| *v == dir_str || v.starts_with(&prefix))
        })
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() || !dir.join("manifest.json").is_file() || referenced(&dir) {
            continue;
        }
        if let Err(e) = std::fs::remove_dir_all(&dir) {
            tracing::warn!(dir = %dir.display(), error = %e, "failed to prune mcp bundle dir");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Build a `.mcpb` in memory: `manifest.json` plus any extra files.
    fn bundle(manifest: &str, files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let opts = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        writer.start_file("manifest.json", opts).unwrap();
        writer.write_all(manifest.as_bytes()).unwrap();
        for (name, content) in files {
            writer.start_file(name, opts).unwrap();
            writer.write_all(content).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }

    fn manifest(extra: &str) -> String {
        format!(
            r#"{{"manifest_version":"0.3","name":"test-bundle","version":"1.0.0",
            "description":"A test","author":{{"name":"T"}},
            "server":{{"type":"node","entry_point":"server/index.js",
            "mcp_config":{{"command":"node","args":["${{__dirname}}/server/index.js","--key","${{user_config.api_key}}"],
            "env":{{"HOME_VAR":"${{HOME}}","KEY":"${{user_config.api_key}}"}}}}}}{extra}}}"#
        )
    }

    fn node_bundle() -> Vec<u8> {
        bundle(
            &manifest(""),
            &[("server/index.js", b"console.log(1)".as_slice())],
        )
    }

    #[test]
    fn inspect_reports_manifest_fields() {
        let info = inspect_bundle(&node_bundle()).unwrap();
        assert_eq!(info.name, "test-bundle");
        assert_eq!(info.version, "1.0.0");
        assert_eq!(info.server_type, "node");
        assert!(info.user_config.is_empty());
    }

    #[test]
    fn inspect_reports_user_config() {
        let m = manifest(
            r#","user_config":{"api_key":{"type":"string","title":"API Key","required":true,"sensitive":true}}"#,
        );
        let info = inspect_bundle(&bundle(&m, &[("server/index.js", b"x")])).unwrap();
        let field = info
            .user_config
            .iter()
            .find(|f| f.key == "api_key")
            .unwrap();
        assert!(field.required);
        assert!(field.sensitive);
        assert_eq!(field.title, "API Key");
    }

    #[test]
    fn inspect_warns_on_undeclared_user_config_ref() {
        let m = manifest("");
        let info = inspect_bundle(&bundle(&m, &[("server/index.js", b"x")])).unwrap();
        assert!(info.warnings.iter().any(|w| w.contains("api_key")));
    }

    #[test]
    fn inspect_rejects_bad_archives_and_manifests() {
        assert!(inspect_bundle(b"not a zip").is_err());
        let no_manifest = {
            let mut w = zip::ZipWriter::new(Cursor::new(Vec::new()));
            w.start_file("x.txt", zip::write::SimpleFileOptions::default())
                .unwrap();
            w.finish().unwrap().into_inner()
        };
        assert!(inspect_bundle(&no_manifest).is_err());
        let bad_name = bundle(
            &manifest("").replace("\"test-bundle\"", "\"bad name!\""),
            &[("server/index.js", b"x")],
        );
        assert!(inspect_bundle(&bad_name).is_err());
    }

    #[test]
    fn install_extracts_and_substitutes() {
        let dir = tempfile::tempdir().unwrap();
        let mut values = Map::new();
        values.insert("api_key".to_string(), Value::String("sekret".into()));
        let m = manifest(r#","user_config":{"api_key":{"type":"string","required":true}}"#);
        let bytes = bundle(&m, &[("server/index.js", b"x")]);
        let install = install_bundle(&bytes, dir.path(), dir.path(), &values).unwrap();
        let dest = dir.path().join("test-bundle");
        let dest_str = dest.canonicalize().unwrap().to_string_lossy().to_string();
        assert!(dest.join("server/index.js").is_file());
        assert_eq!(install.server.name, "test-bundle");
        assert_eq!(install.server.transport, "stdio");
        assert_eq!(install.server.command, "node");
        assert_eq!(
            install.server.args,
            vec![
                format!("{dest_str}/server/index.js"),
                "--key".to_string(),
                "sekret".to_string()
            ]
        );
        assert_eq!(install.server.env["KEY"], "sekret");
        assert_eq!(
            install.server.env["HOME_VAR"],
            dir.path()
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .to_string()
        );
    }

    #[test]
    fn install_requires_user_config_values() {
        let dir = tempfile::tempdir().unwrap();
        let m = manifest(r#","user_config":{"api_key":{"type":"string","required":true}}"#);
        let bytes = bundle(&m, &[("server/index.js", b"x")]);
        let err = install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).unwrap_err();
        assert!(err.contains("api_key"), "{err}");
        assert!(!dir.path().join("test-bundle").exists());
    }

    #[test]
    fn install_uses_manifest_default() {
        let dir = tempfile::tempdir().unwrap();
        let m = manifest(
            r#","user_config":{"api_key":{"type":"string","required":true,"default":"fallback"}}"#,
        );
        let bytes = bundle(&m, &[("server/index.js", b"x")]);
        let install = install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).unwrap();
        assert_eq!(install.server.env["KEY"], "fallback");
    }

    #[test]
    fn install_expands_array_arg() {
        let dir = tempfile::tempdir().unwrap();
        let m = r#"{"manifest_version":"0.3","name":"dirs","version":"1","description":"d",
            "author":{"name":"a"},
            "server":{"type":"node","entry_point":"s.js",
            "mcp_config":{"command":"node","args":["${__dirname}/s.js","${user_config.dirs}"]}},
            "user_config":{"dirs":{"type":"directory","multiple":true,"required":true}}}"#;
        let bytes = bundle(m, &[("s.js", b"x")]);
        let mut values = Map::new();
        values.insert(
            "dirs".to_string(),
            Value::Array(vec!["/a".into(), "/b".into()]),
        );
        let install = install_bundle(&bytes, dir.path(), dir.path(), &values).unwrap();
        assert_eq!(
            install.server.args[1..],
            ["/a".to_string(), "/b".to_string()]
        );
    }

    #[test]
    fn install_rejects_zip_slip() {
        let dir = tempfile::tempdir().unwrap();
        let mut w = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let opts = zip::write::SimpleFileOptions::default();
        w.start_file("manifest.json", opts).unwrap();
        w.write_all(manifest("").as_bytes()).unwrap();
        w.start_file("../escape.txt", opts).unwrap();
        w.write_all(b"bad").unwrap();
        w.start_file("server/index.js", opts).unwrap();
        w.write_all(b"x").unwrap();
        let bytes = w.finish().unwrap().into_inner();
        assert!(install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).is_err());
        assert!(!dir.path().join("test-bundle").exists());
        assert!(!dir.path().join("escape.txt").exists());
    }

    #[test]
    fn install_applies_platform_overrides() {
        let dir = tempfile::tempdir().unwrap();
        let platform = current_platform();
        let m = format!(
            r#"{{"manifest_version":"0.3","name":"ovr","version":"1","description":"d",
            "author":{{"name":"a"}},
            "server":{{"type":"node","entry_point":"s.js",
            "mcp_config":{{"command":"node","args":["base"],
            "platform_overrides":{{"{platform}":{{"command":"bun","env":{{"P":"1"}}}}}}}}}}}}"#
        );
        let bytes = bundle(&m, &[("s.js", b"x")]);
        let install = install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).unwrap();
        assert_eq!(install.server.command, "bun");
        assert_eq!(install.server.args, ["base"]);
        assert_eq!(install.server.env["P"], "1");
    }

    #[test]
    fn install_synthesizes_uv_command() {
        let dir = tempfile::tempdir().unwrap();
        let m = r#"{"manifest_version":"0.4","name":"uvsrv","version":"1","description":"d",
            "author":{"name":"a"},
            "server":{"type":"uv","entry_point":"src/main.py"}}"#;
        let bytes = bundle(m, &[("src/main.py", b"x")]);
        let install = install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).unwrap();
        assert_eq!(install.server.command, "uv");
        assert_eq!(install.server.args[0], "run");
        assert!(install.server.args.last().unwrap().ends_with("src/main.py"));
    }

    #[cfg(unix)]
    #[test]
    fn install_marks_entry_point_executable() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let m = r#"{"manifest_version":"0.3","name":"bin","version":"1","description":"d",
            "author":{"name":"a"},
            "server":{"type":"binary","entry_point":"srv"}}"#;
        let bytes = bundle(m, &[("srv", b"\x7fELF")]);
        let install = install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).unwrap();
        assert_eq!(
            install.server.command,
            format!(
                "{}/srv",
                dir.path().join("bin").canonicalize().unwrap().display()
            )
        );
        let mode = std::fs::metadata(dir.path().join("bin/srv"))
            .unwrap()
            .permissions()
            .mode();
        assert_ne!(mode & 0o111, 0);
    }

    #[test]
    fn install_rejects_unsupported_platform() {
        let dir = tempfile::tempdir().unwrap();
        let other = if current_platform() == "linux" {
            "plan9"
        } else {
            "linux"
        };
        let m = manifest(&format!(r#","compatibility":{{"platforms":["{other}"]}}"#));
        let bytes = bundle(&m, &[("server/index.js", b"x")]);
        assert!(install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).is_err());
    }

    #[test]
    fn prune_removes_unreferenced_bundle_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let keep = dir.path().join("keep");
        let drop = dir.path().join("drop");
        std::fs::create_dir_all(&keep).unwrap();
        std::fs::create_dir_all(&drop).unwrap();
        std::fs::write(keep.join("manifest.json"), "{}").unwrap();
        std::fs::write(drop.join("manifest.json"), "{}").unwrap();
        let stranger = dir.path().join("stranger");
        std::fs::create_dir_all(&stranger).unwrap();

        let keep_str = keep.to_string_lossy().to_string();
        let servers = vec![McpServerConfig {
            name: "keep".into(),
            enabled: true,
            transport: "stdio".into(),
            command: "node".into(),
            args: vec![format!("{keep_str}/server/index.js")],
            env: BTreeMap::new(),
            url: String::new(),
            headers: BTreeMap::new(),
        }];
        prune_bundles(dir.path(), &servers);
        assert!(keep.exists());
        assert!(!drop.exists());
        assert!(stranger.exists());
    }

    /// The stored server args are canonical absolute paths, so the prune
    /// must still match when `root` arrives as a non-canonical spelling
    /// (relative or `..`-containing), which `bundle_root` can be under the
    /// default `sqlite:data/...` db URL.
    #[test]
    fn prune_handles_noncanonical_root() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("mcp-bundles");
        let keep = root.join("keep");
        std::fs::create_dir_all(&keep).unwrap();
        std::fs::write(keep.join("manifest.json"), "{}").unwrap();

        let keep_str = keep.canonicalize().unwrap().to_string_lossy().to_string();
        let servers = vec![McpServerConfig {
            name: "keep".into(),
            enabled: true,
            transport: "stdio".into(),
            command: "node".into(),
            args: vec![format!("{keep_str}/server/index.js")],
            env: BTreeMap::new(),
            url: String::new(),
            headers: BTreeMap::new(),
        }];
        let funny_root = root.join("x").join("..").join(".");
        prune_bundles(&funny_root, &servers);
        assert!(keep.exists());
    }

    #[test]
    fn bundle_root_is_absolute_for_relative_db_url() {
        let cfg = Config {
            host: "127.0.0.1".into(),
            port: 0,
            session_key: vec![0; 48],
            db_url: "sqlite:data/devinorium.db?mode=rwc".into(),
            bootstrap_username: "o".into(),
            bootstrap_password: "x".into(),
            home_dir: PathBuf::from("."),
            default_model: "m".into(),
            trust_proxy: false,
            max_body_bytes: 1024,
            secure_cookie: false,
            allowed_origin: None,
            local_token: None,
            tailscale_bin: "tailscale".into(),
            dev_mode: false,
            push_contact: "mailto:t@localhost".into(),
            satellite: false,
            node_name: String::new(),
        };
        let root = bundle_root(&cfg);
        assert!(root.is_absolute(), "{root:?}");
        assert!(root.ends_with(Path::new("data").join("mcp-bundles")));
    }

    #[test]
    fn install_rejects_traversal_entry_point() {
        let dir = tempfile::tempdir().unwrap();
        let m = manifest("").replace("server/index.js", "../escape.js");
        let bytes = bundle(&m, &[("escape.js", b"x")]);
        assert!(install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).is_err());
        assert!(!dir.path().join("escape.js").exists());
    }

    #[test]
    fn install_rejects_reserved_names() {
        let dir = tempfile::tempdir().unwrap();
        let m = manifest("").replace("\"test-bundle\"", "\"con\"");
        let bytes = bundle(&m, &[("server/index.js", b"x")]);
        assert!(install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).is_err());
    }

    #[test]
    fn install_validates_user_config_types() {
        let dir = tempfile::tempdir().unwrap();
        let m = manifest(
            r#","user_config":{"api_key":{"type":"number","required":true,"min":1,"max":10}}"#,
        );
        let bytes = bundle(&m, &[("server/index.js", b"x")]);
        // A string where a number belongs.
        let mut values = Map::new();
        values.insert("api_key".to_string(), Value::String("abc".into()));
        assert!(install_bundle(&bytes, dir.path(), dir.path(), &values).is_err());
        // Out of range.
        values.insert("api_key".to_string(), Value::from(99));
        assert!(install_bundle(&bytes, dir.path(), dir.path(), &values).is_err());
        // In range.
        values.insert("api_key".to_string(), Value::from(5));
        assert!(install_bundle(&bytes, dir.path(), dir.path(), &values).is_ok());
    }

    #[test]
    fn install_drops_unset_optional_whole_arg() {
        let dir = tempfile::tempdir().unwrap();
        let m = manifest(r#","user_config":{"extra":{"type":"string","required":false}}"#)
            .replace("\"${user_config.api_key}\"", "\"${user_config.extra}\"");
        let bytes = bundle(&m, &[("server/index.js", b"x")]);
        let install = install_bundle(&bytes, dir.path(), dir.path(), &Map::new()).unwrap();
        assert_eq!(install.server.args.len(), 2, "{:?}", install.server.args);
        assert!(!install.server.env.contains_key("KEY"));
    }
}
