//! Project app-icon discovery.
//!
//! Finds a representative icon file inside a project directory so the
//! sidebar can show the project's real icon instead of a generic marker.
//! Resolution mirrors what t3code does: a `devinorium.json` `iconPath`
//! override first, then well-known favicon/app-icon locations, then icon
//! links found in project HTML files, then PWA manifests, and finally a
//! shallow scan for `icon*`/`logo*` files.

use std::path::{Path, PathBuf};
use std::time::Duration;

use once_cell::sync::Lazy;
use regex::Regex;

use crate::security::paths;

/// Largest icon file the endpoint will serve.
const MAX_ICON_BYTES: u64 = 4 * 1024 * 1024;

/// Largest HTML/manifest/config source file parsed while looking for an icon
/// reference. Anything bigger is skipped rather than slurped into memory.
const MAX_SOURCE_BYTES: u64 = 1024 * 1024;

/// How long a resolved path (or a miss) stays cached. Hits are
/// re-canonicalized and re-loaded on every read, so a swapped or deleted
/// icon never survives on the fast path.
const ICON_CACHE_TTL: Duration = Duration::from_secs(60);

/// Well-known icon locations relative to the project root, checked in order.
/// `.ico` files sit below `.png`/`.svg` since Flutter can only render them
/// when they embed a PNG.
const ICON_CANDIDATES: &[&str] = &[
    "favicon.svg",
    "favicon.png",
    "favicon.ico",
    "icon.svg",
    "icon.png",
    "logo.svg",
    "logo.png",
    "apple-touch-icon.png",
    "apple-touch-icon-precomposed.png",
    "public/favicon.svg",
    "public/favicon.png",
    "public/favicon.ico",
    "public/icon.svg",
    "public/icon.png",
    "public/logo.svg",
    "public/logo.png",
    "public/apple-touch-icon.png",
    "app/favicon.png",
    "app/icon.svg",
    "app/icon.png",
    "app/favicon.ico",
    "app/icon.ico",
    "src/favicon.svg",
    "src/favicon.ico",
    "src/app/icon.svg",
    "src/app/icon.png",
    "src/app/favicon.ico",
    "web/favicon.svg",
    "web/favicon.png",
    "web/icon.png",
    "web/icons/Icon-512.png",
    "web/icons/Icon-192.png",
    "static/favicon.svg",
    "static/favicon.png",
    "static/favicon.ico",
    "static/icon.svg",
    "static/icon.png",
    "assets/icon.svg",
    "assets/icon.png",
    "assets/logo.svg",
    "assets/logo.png",
    ".idea/icon.svg",
];

/// Files that may declare an icon through `<link rel="icon">` or icon
/// metadata objects (`{ rel: "icon", href: "..." }`).
const ICON_SOURCE_FILES: &[&str] = &[
    "index.html",
    "public/index.html",
    "web/index.html",
    "src/index.html",
    "app.html",
    "src/app.html",
    "app/root.tsx",
    "src/root.tsx",
    "app/routes/__root.tsx",
    "src/routes/__root.tsx",
];

/// Web app manifests whose `icons` array may point at an app icon.
const MANIFEST_FILES: &[&str] = &[
    "manifest.json",
    "manifest.webmanifest",
    "site.webmanifest",
    "public/manifest.json",
    "public/manifest.webmanifest",
    "public/site.webmanifest",
    "web/manifest.json",
    "static/manifest.json",
    "static/site.webmanifest",
    "app/manifest.json",
];

/// Directories scanned (non-recursively) for icon-named image files.
const SCAN_DIRS: &[&str] = &["", "public", "assets", "web", "static", "icons"];

static REL_ATTR_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?i)\brel\s*=\s*["']([^"']+)["']"#).expect("rel attr regex"));
static HREF_ATTR_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?i)\bhref\s*=\s*["']([^"']+)["']"#).expect("href attr regex"));
static META_REL_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?i)\brel\s*:\s*["'](?:icon|shortcut icon|apple-touch-icon)["']"#)
        .expect("meta rel regex")
});
static META_HREF_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?i)\bhref\s*:\s*["']([^"']+)["']"#).expect("meta href regex"));

/// Resolved icon path per canonical project root. A `None` value is a
/// negative hit — the project has no icon.
static ICON_PATH_CACHE: Lazy<mini_moka::sync::Cache<PathBuf, Option<PathBuf>>> = Lazy::new(|| {
    mini_moka::sync::Cache::builder()
        .max_capacity(512)
        .time_to_live(ICON_CACHE_TTL)
        .build()
});

/// MIME types the endpoint will serve. Anything else under an icon-like name
/// (e.g. `icon.ttf`) is not an icon.
fn mime_for_extension(ext: &str) -> Option<&'static str> {
    Some(match ext.to_ascii_lowercase().as_str() {
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "ico" => "image/x-icon",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "bmp" => "image/bmp",
        _ => return None,
    })
}

/// Read a source file that may declare an icon, capped so a huge file is
/// skipped instead of slurped into memory.
fn read_source(path: &Path) -> Option<String> {
    use std::io::Read;
    let meta = path.metadata().ok()?;
    if meta.len() == 0 || meta.len() > MAX_SOURCE_BYTES {
        return None;
    }
    let mut buf = String::new();
    std::fs::File::open(path)
        .ok()?
        .take(MAX_SOURCE_BYTES)
        .read_to_string(&mut buf)
        .ok()?;
    Some(buf)
}

/// True when `canon` sits under a dot-directory other than the `.idea`
/// allowlist. `.git` and `.devinorium-attachments` are already covered by
/// `paths::is_hidden_within`; this catches every other dot-directory so an
/// icon href can never point into `.secrets/`, `.ssh/` and friends. The
/// basename itself may be dot-prefixed — only ancestor directories matter.
fn has_hidden_component(root: &Path, canon: &Path) -> bool {
    let Ok(rel) = canon.strip_prefix(root) else {
        return true;
    };
    rel.parent().is_some_and(|dir| {
        dir.components().any(|c| {
            let s = c.as_os_str().to_string_lossy();
            s.starts_with('.') && s != ".idea"
        })
    })
}

/// Join `rel` onto `root` and return the canonical path when it is a real
/// image file inside `root` that is not under a protected directory.
fn icon_candidate(root: &Path, rel: &Path) -> Option<PathBuf> {
    if rel.is_absolute() || rel.as_os_str().is_empty() {
        return None;
    }
    let canon = root.join(rel).canonicalize().ok()?;
    if !canon.is_file()
        || !paths::is_within(&canon, root)
        || paths::is_hidden_within(root, &canon)
        || has_hidden_component(root, &canon)
    {
        return None;
    }
    let meta = canon.metadata().ok()?;
    if meta.len() == 0 || meta.len() > MAX_ICON_BYTES {
        return None;
    }
    mime_for_extension(canon.extension()?.to_str()?)?;
    Some(canon)
}

/// Candidate paths for an `href` found in `source_rel`'s file. Relative
/// hrefs resolve next to the file that declared them; site-root hrefs
/// (`/icon.png`) and the leftover fallbacks are tried under the common web
/// roots before the project root. Query strings and fragments are dropped
/// since they never map to the filesystem.
fn href_candidates(source_rel: &Path, href: &str) -> Vec<PathBuf> {
    let clean = href
        .split(['?', '#'])
        .next()
        .unwrap_or("")
        .trim_start_matches('/');
    if clean.is_empty() {
        return Vec::new();
    }
    let mut out: Vec<PathBuf> = Vec::with_capacity(4);
    let mut push = |p: PathBuf| {
        if !out.contains(&p) {
            out.push(p);
        }
    };
    if !href.trim_start().starts_with('/') {
        if let Some(dir) = source_rel.parent() {
            push(dir.join(clean));
        }
    }
    push(Path::new("public").join(clean));
    push(Path::new("web").join(clean));
    push(PathBuf::from(clean));
    out
}

fn usable_href(href: &str) -> bool {
    let h = href.trim();
    !h.is_empty()
        && !h.starts_with("//")
        && !h.contains("://")
        && !h.to_ascii_lowercase().starts_with("data:")
}

/// Pull every icon href out of an HTML/TSX source in document order: `<link>`
/// tags whose `rel` names an icon relationship, and object literals carrying
/// `rel: "icon"` next to an `href`.
fn extract_icon_hrefs(source: &str) -> Vec<String> {
    let mut hrefs = Vec::new();
    let lower = source.to_ascii_lowercase();
    let mut scan = 0;
    while let Some(off) = lower[scan..].find("<link") {
        let start = scan + off;
        let after = &source[start + 5..];
        let end = after.find('>').map(|e| e + 1).unwrap_or(after.len());
        let tag = &after[..end];
        let is_icon = REL_ATTR_RE
            .captures(tag)
            .and_then(|c| c.get(1))
            .is_some_and(|m| m.as_str().to_ascii_lowercase().contains("icon"));
        if is_icon {
            if let Some(m) = HREF_ATTR_RE.captures(tag).and_then(|c| c.get(1)) {
                let href = m.as_str().trim();
                if usable_href(href) {
                    hrefs.push(href.to_string());
                }
            }
        }
        scan = start + 5;
    }
    // Icon metadata objects: rel and href must share a brace-free run so a
    // run with `rel` but no `href` does not end the search.
    for run in source.split('}') {
        if !META_REL_RE.is_match(run) {
            continue;
        }
        if let Some(m) = META_HREF_RE.captures(run) {
            let href = m[1].trim();
            if usable_href(href) {
                hrefs.push(href.to_string());
            }
        }
    }
    hrefs
}

/// Score a manifest `icons[]` entry by its largest declared size. `"any"`
/// (scalable, usually SVG) outranks every raster size.
fn manifest_icon_score(icon: &serde_json::Value) -> u64 {
    let sizes = icon.get("sizes").and_then(|s| s.as_str()).unwrap_or("");
    if sizes
        .split_whitespace()
        .any(|t| t.eq_ignore_ascii_case("any"))
    {
        return u64::MAX;
    }
    sizes
        .split_whitespace()
        .filter_map(|t| t.split('x').next()?.parse::<u64>().ok())
        .max()
        .unwrap_or(0)
}

/// Every `icons[].src` in a web manifest, best score first, so a missing
/// top pick falls through to the runner-up instead of abandoning the file.
fn manifest_icon_srcs(root: &Path, manifest_rel: &str) -> Vec<String> {
    let Some(text) = read_source(&root.join(manifest_rel)) else {
        return Vec::new();
    };
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
        return Vec::new();
    };
    let Some(icons) = json.get("icons").and_then(|i| i.as_array()) else {
        return Vec::new();
    };
    let mut scored: Vec<(u64, usize, &str)> = icons
        .iter()
        .enumerate()
        .filter_map(|(i, icon)| {
            let src = icon.get("src").and_then(|s| s.as_str())?;
            usable_href(src).then(|| (manifest_icon_score(icon), i, src))
        })
        .collect();
    // Stable sort keeps document order between equally scored entries.
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    scored
        .into_iter()
        .map(|(_, _, src)| src.to_string())
        .collect()
}

/// Rank a file found by the directory scan: exact icon names first, then a
/// format preference (svg > png > ico > others), then the name itself.
fn scan_rank(name: &str) -> (u8, u8) {
    let lower = name.to_ascii_lowercase();
    let (stem, ext) = lower.rsplit_once('.').unwrap_or((lower.as_str(), ""));
    let stem_rank = match stem {
        "favicon" | "icon" | "logo" | "appicon" | "app-icon" | "app_icon" => 0,
        s if s.starts_with("icon") || s.starts_with("favicon") => 1,
        s if s.starts_with("logo") => 2,
        _ => 3,
    };
    let ext_rank = match ext {
        "svg" => 0,
        "png" => 1,
        "ico" => 2,
        "webp" => 3,
        "jpg" | "jpeg" => 4,
        "gif" => 5,
        "avif" => 6,
        _ => 7,
    };
    (stem_rank, ext_rank)
}

/// Shallow scan of common asset directories for files named `icon*`,
/// `favicon*` or `logo*` with an image extension, best rank first.
fn scan_candidates(root: &Path) -> Vec<PathBuf> {
    let mut hits: Vec<(u8, u8, String, PathBuf)> = Vec::new();
    for dir_rel in SCAN_DIRS {
        let dir = if dir_rel.is_empty() {
            root.to_path_buf()
        } else {
            root.join(dir_rel)
        };
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let lower = name.to_ascii_lowercase();
            let Some((stem, ext)) = lower.rsplit_once('.') else {
                continue;
            };
            if mime_for_extension(ext).is_none() {
                continue;
            }
            if !(stem.starts_with("icon")
                || stem.starts_with("logo")
                || stem.starts_with("favicon")
                || stem.starts_with("app-icon")
                || stem.starts_with("app_icon")
                || stem == "appicon")
            {
                continue;
            }
            let (a, b) = scan_rank(&lower);
            hits.push((a, b, lower, entry.path()));
        }
    }
    hits.sort_by(|x, y| (x.0, x.1, x.2.as_str()).cmp(&(y.0, y.1, y.2.as_str())));
    hits.into_iter()
        .filter_map(|(_, _, _, path)| path.strip_prefix(root).ok().map(Path::to_path_buf))
        .collect()
}

/// Cheap candidates first: the configured `iconPath`, then the well-known
/// locations. Both are plain stat probes, so resolution usually finishes
/// here without opening any source files.
fn primary_candidates(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for name in ["devinorium.json", ".devinorium.json"] {
        let Some(text) = read_source(&root.join(name)) else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        if let Some(rel) = json.get("iconPath").and_then(|v| v.as_str()) {
            out.push(PathBuf::from(rel));
        }
    }
    out.extend(ICON_CANDIDATES.iter().map(PathBuf::from));
    out
}

/// The expensive half: icon links in HTML/TSX sources, PWA manifest icons,
/// then the directory scan.
fn secondary_candidates(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for rel in ICON_SOURCE_FILES {
        let Some(source) = read_source(&root.join(rel)) else {
            continue;
        };
        for href in extract_icon_hrefs(&source) {
            out.extend(href_candidates(Path::new(rel), &href));
        }
    }
    for rel in MANIFEST_FILES {
        for src in manifest_icon_srcs(root, rel) {
            out.extend(href_candidates(Path::new(rel), &src));
        }
    }
    out.extend(scan_candidates(root));
    out
}

/// A cached path is only trusted when it still canonicalizes to itself —
/// a file swapped for a symlink (or a dir that became one) re-runs the full
/// resolve instead of serving through the link.
fn cached_path_valid(root: &Path, path: &Path) -> bool {
    let Ok(canon) = path.canonicalize() else {
        return false;
    };
    canon == *path
        && canon.is_file()
        && paths::is_within(&canon, root)
        && !paths::is_hidden_within(root, &canon)
        && !has_hidden_component(root, &canon)
}

fn load_first(root: &Path, candidates: Vec<PathBuf>) -> Option<(PathBuf, Vec<u8>, &'static str)> {
    candidates.into_iter().find_map(|rel| {
        let path = icon_candidate(root, &rel)?;
        load_icon(&path).map(|(bytes, mime)| (path, bytes, mime))
    })
}

fn resolve_uncached(root: &Path) -> Option<(PathBuf, Vec<u8>, &'static str)> {
    load_first(root, primary_candidates(root))
        .or_else(|| load_first(root, secondary_candidates(root)))
}

/// Resolve the project's icon and read it, cached per project root. The
/// first candidate that both validates and decodes wins; a `.ico` without an
/// embedded PNG, an unreadable file, or a path that fails containment just
/// moves on to the next candidate.
pub(crate) fn resolve_and_load(root: &Path) -> Option<(Vec<u8>, &'static str)> {
    let root = root.canonicalize().ok()?;
    if let Some(cached) = ICON_PATH_CACHE.get(&root) {
        match cached {
            Some(p) if cached_path_valid(&root, &p) => {
                if let Some(icon) = load_icon(&p) {
                    return Some(icon);
                }
                ICON_PATH_CACHE.invalidate(&root);
            }
            Some(_) => {
                ICON_PATH_CACHE.invalidate(&root);
            }
            None => return None,
        }
    }
    if let Some((path, bytes, mime)) = resolve_uncached(&root) {
        ICON_PATH_CACHE.insert(root, Some(path));
        return Some((bytes, mime));
    }
    ICON_PATH_CACHE.insert(root, None);
    None
}

/// Read the icon bytes with a hard cap, refusing anything that grew past
/// the limit since the candidate check. `.ico` containers are unpacked and
/// their largest embedded PNG is served instead, since Flutter cannot decode
/// ICO files — an ICO without a PNG entry is treated as no icon, while a
/// `.ico` file that actually holds a raw PNG (common in the wild) is served
/// as-is.
fn load_icon(path: &Path) -> Option<(Vec<u8>, &'static str)> {
    use std::io::Read;
    let ext = path.extension()?.to_str()?;
    let mime = mime_for_extension(ext)?;
    let meta = path.metadata().ok()?;
    if meta.len() == 0 || meta.len() > MAX_ICON_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .ok()?
        .take(MAX_ICON_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.is_empty() || bytes.len() as u64 > MAX_ICON_BYTES {
        return None;
    }
    if bytes.starts_with(&PNG_MAGIC) {
        return Some((bytes, "image/png"));
    }
    if ext.eq_ignore_ascii_case("ico") {
        return extract_ico_png(&bytes).map(|png| (png, "image/png"));
    }
    Some((bytes, mime))
}

/// The PNG file signature; ICO entries embedding PNG payloads start with it.
const PNG_MAGIC: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Extract the largest PNG image embedded in an ICO container. Entries whose
/// declared size overruns the file are clamped to what is actually there so
/// one corrupt header does not sink an otherwise valid image. Returns `None`
/// when the file is not an ICO or holds only raw bitmap (DIB) entries.
fn extract_ico_png(bytes: &[u8]) -> Option<Vec<u8>> {
    if bytes.len() < 6 || bytes[..4] != [0, 0, 1, 0] {
        return None;
    }
    let count = u16::from_le_bytes([bytes[4], bytes[5]]) as usize;
    let mut best: Option<(u32, usize, usize)> = None;
    for i in 0..count {
        let e = 6 + i * 16;
        if e + 16 > bytes.len() {
            break;
        }
        let w = if bytes[e] == 0 { 256 } else { bytes[e] as u32 };
        let h = if bytes[e + 1] == 0 {
            256
        } else {
            bytes[e + 1] as u32
        };
        let size = u32::from_le_bytes(bytes[e + 8..e + 12].try_into().ok()?) as usize;
        let off = u32::from_le_bytes(bytes[e + 12..e + 16].try_into().ok()?) as usize;
        let end = off.saturating_add(size).min(bytes.len());
        if off + PNG_MAGIC.len() <= bytes.len() && bytes[off..off + 8] == PNG_MAGIC {
            let px = w * h;
            if best.is_none_or(|(b, _, _)| px > b) {
                best = Some((px, off, end - off));
            }
        }
    }
    let (_, off, size) = best?;
    bytes.get(off..off + size).map(|s| s.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn dir() -> TempDir {
        TempDir::new().unwrap()
    }

    fn resolve_path(d: &TempDir) -> Option<PathBuf> {
        resolve_uncached(&d.path().canonicalize().unwrap()).map(|(p, _, _)| p)
    }

    #[test]
    fn finds_root_favicon() {
        let d = dir();
        fs::write(d.path().join("favicon.svg"), "<svg/>").unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("favicon.svg"));
    }

    #[test]
    fn config_icon_path_wins_over_candidates() {
        let d = dir();
        fs::write(d.path().join("favicon.svg"), "<svg/>").unwrap();
        fs::create_dir_all(d.path().join("assets")).unwrap();
        fs::write(d.path().join("assets/brand.png"), b"png").unwrap();
        fs::write(
            d.path().join("devinorium.json"),
            r#"{"iconPath": "assets/brand.png"}"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("assets/brand.png"));
    }

    #[test]
    fn config_icon_path_outside_root_is_ignored() {
        let d = dir();
        let outside = dir();
        fs::write(outside.path().join("secret.png"), b"png").unwrap();
        fs::write(
            d.path().join("devinorium.json"),
            format!(
                r#"{{"iconPath": "{}"}}"#,
                outside.path().join("secret.png").display()
            ),
        )
        .unwrap();
        assert!(resolve_path(&d).is_none());
    }

    #[test]
    fn config_icon_path_traversal_is_ignored() {
        let d = dir();
        let outside = dir();
        fs::write(outside.path().join("secret.png"), b"png").unwrap();
        fs::write(
            d.path().join("devinorium.json"),
            format!(
                r#"{{"iconPath": "../{}/secret.png"}}"#,
                outside.path().file_name().unwrap().to_string_lossy()
            ),
        )
        .unwrap();
        assert!(resolve_path(&d).is_none());
    }

    #[test]
    fn html_link_icon_resolves_under_public() {
        let d = dir();
        fs::create_dir_all(d.path().join("public")).unwrap();
        fs::write(d.path().join("public/favicon.png"), b"png").unwrap();
        fs::write(
            d.path().join("index.html"),
            r#"<html><head><link rel="icon" href="/favicon.png"></head></html>"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("public/favicon.png"));
    }

    #[test]
    fn html_second_link_wins_when_first_is_missing() {
        let d = dir();
        fs::create_dir_all(d.path().join("public")).unwrap();
        fs::write(d.path().join("public/real.png"), b"png").unwrap();
        fs::write(
            d.path().join("index.html"),
            r#"<link rel="icon" href="/missing.svg">
               <link rel="icon" href="/real.png">"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("public/real.png"));
    }

    #[test]
    fn html_link_with_query_string_resolves() {
        let d = dir();
        fs::create_dir_all(d.path().join("public")).unwrap();
        fs::write(d.path().join("public/favicon.png"), b"png").unwrap();
        fs::write(
            d.path().join("index.html"),
            r#"<link rel="icon" href="/favicon.png?v=3">"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("public/favicon.png"));
    }

    #[test]
    fn html_relative_href_prefers_file_dir_over_public() {
        let d = dir();
        fs::create_dir_all(d.path().join("icons")).unwrap();
        fs::create_dir_all(d.path().join("public/icons")).unwrap();
        fs::write(d.path().join("icons/app.png"), b"root").unwrap();
        fs::write(d.path().join("public/icons/app.png"), b"public").unwrap();
        fs::write(
            d.path().join("index.html"),
            r#"<link rel="icon" href="icons/app.png">"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("icons/app.png"));
        assert!(!hit.ends_with("public/icons/app.png"));
    }

    #[test]
    fn html_relative_href_resolves_next_to_source() {
        let d = dir();
        fs::create_dir_all(d.path().join("web/icons")).unwrap();
        fs::write(d.path().join("web/icons/app.png"), b"png").unwrap();
        fs::write(
            d.path().join("web/index.html"),
            r#"<link rel="shortcut icon" href="icons/app.png">"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("web/icons/app.png"));
    }

    #[test]
    fn manifest_picks_largest_icon() {
        let d = dir();
        fs::create_dir_all(d.path().join("web/icons")).unwrap();
        fs::write(d.path().join("web/icons/small.png"), b"a").unwrap();
        fs::write(d.path().join("web/icons/big.png"), b"bb").unwrap();
        fs::write(
            d.path().join("web/manifest.json"),
            r#"{"icons": [
                {"src": "icons/small.png", "sizes": "48x48"},
                {"src": "icons/big.png", "sizes": "512x512"}
            ]}"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("web/icons/big.png"));
    }

    #[test]
    fn manifest_falls_back_to_runner_up() {
        let d = dir();
        fs::create_dir_all(d.path().join("web/icons")).unwrap();
        fs::write(d.path().join("web/icons/small.png"), b"a").unwrap();
        fs::write(
            d.path().join("web/manifest.json"),
            r#"{"icons": [
                {"src": "icons/small.png", "sizes": "48x48"},
                {"src": "icons/gone.png", "sizes": "512x512"}
            ]}"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("web/icons/small.png"));
    }

    #[test]
    fn manifest_src_with_query_string_resolves() {
        let d = dir();
        fs::create_dir_all(d.path().join("web/icons")).unwrap();
        fs::write(d.path().join("web/icons/app.png"), b"png").unwrap();
        fs::write(
            d.path().join("web/manifest.json"),
            r#"{"icons": [{"src": "icons/app.png?v=2", "sizes": "192x192"}]}"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("web/icons/app.png"));
    }

    #[test]
    fn scan_finds_icon_named_file() {
        let d = dir();
        fs::write(d.path().join("icon-512.png"), b"png").unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("icon-512.png"));
    }

    #[test]
    fn hidden_dir_icon_is_rejected() {
        let d = dir();
        fs::create_dir_all(d.path().join(".git")).unwrap();
        fs::write(d.path().join(".git/icon.png"), b"png").unwrap();
        fs::write(
            d.path().join("index.html"),
            r#"<link rel="icon" href=".git/icon.png">"#,
        )
        .unwrap();
        assert!(resolve_path(&d).is_none());
    }

    #[test]
    fn dot_prefixed_basename_at_root_is_allowed() {
        let d = dir();
        fs::write(d.path().join(".icon.png"), b"png").unwrap();
        fs::write(
            d.path().join("devinorium.json"),
            r#"{"iconPath": ".icon.png"}"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with(".icon.png"));
    }

    #[test]
    fn other_dot_dirs_are_rejected_but_idea_is_allowed() {
        let d = dir();
        fs::create_dir_all(d.path().join(".secrets")).unwrap();
        fs::write(d.path().join(".secrets/icon.png"), b"png").unwrap();
        fs::write(
            d.path().join("devinorium.json"),
            r#"{"iconPath": ".secrets/icon.png"}"#,
        )
        .unwrap();
        assert!(resolve_path(&d).is_none());

        fs::create_dir_all(d.path().join(".idea")).unwrap();
        fs::write(d.path().join(".idea/icon.svg"), "<svg/>").unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with(".idea/icon.svg"));
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_icon_file_outside_root_is_rejected() {
        let d = dir();
        let outside = dir();
        fs::write(outside.path().join("secret.png"), b"png").unwrap();
        std::os::unix::fs::symlink(
            outside.path().join("secret.png"),
            d.path().join("favicon.png"),
        )
        .unwrap();
        assert!(resolve_path(&d).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_dir_escape_is_rejected() {
        let d = dir();
        let outside = dir();
        fs::write(outside.path().join("favicon.png"), b"png").unwrap();
        std::os::unix::fs::symlink(outside.path(), d.path().join("public")).unwrap();
        assert!(resolve_path(&d).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn cached_hit_survives_plain_rewrite_but_not_symlink_swap() {
        let d = dir();
        let root = d.path().canonicalize().unwrap();
        fs::write(d.path().join("favicon.png"), b"v1").unwrap();
        assert_eq!(resolve_and_load(&root).unwrap().0, b"v1");
        // Same path, new bytes: cached path still canonicalizes to itself.
        fs::write(d.path().join("favicon.png"), b"v2").unwrap();
        assert_eq!(resolve_and_load(&root).unwrap().0, b"v2");
        // Swapped for a symlink out of the root: cache is dropped, icon gone.
        let outside = dir();
        fs::write(outside.path().join("secret.png"), b"png").unwrap();
        fs::remove_file(d.path().join("favicon.png")).unwrap();
        std::os::unix::fs::symlink(
            outside.path().join("secret.png"),
            d.path().join("favicon.png"),
        )
        .unwrap();
        assert!(resolve_and_load(&root).is_none());
    }

    #[test]
    fn deleted_icon_reruns_resolution() {
        let d = dir();
        let root = d.path().canonicalize().unwrap();
        fs::write(d.path().join("favicon.svg"), "<svg/>").unwrap();
        fs::write(d.path().join("icon.png"), b"png").unwrap();
        assert_eq!(resolve_and_load(&root).unwrap().1, "image/svg+xml");
        fs::remove_file(d.path().join("favicon.svg")).unwrap();
        assert_eq!(resolve_and_load(&root).unwrap().1, "image/png");
    }

    #[test]
    fn non_image_extension_is_not_an_icon() {
        let d = dir();
        fs::write(d.path().join("icon.txt"), b"text").unwrap();
        fs::write(d.path().join("icon.ttf"), b"font").unwrap();
        assert!(resolve_path(&d).is_none());
    }

    #[test]
    fn tsx_icon_metadata_resolves() {
        let d = dir();
        fs::create_dir_all(d.path().join("public")).unwrap();
        fs::create_dir_all(d.path().join("src")).unwrap();
        fs::write(d.path().join("public/head-icon.svg"), "<svg/>").unwrap();
        fs::write(
            d.path().join("src/root.tsx"),
            r#"export const links = () => [{ rel: "icon", href: "/head-icon.svg" }];"#,
        )
        .unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("public/head-icon.svg"));
    }

    #[test]
    fn ico_with_png_entry_extracts_png() {
        let png = [PNG_MAGIC.as_slice(), b"fakepngdata"].concat();
        let mut ico = vec![0, 0, 1, 0, 1, 0];
        // One 32x32 entry pointing at offset 6+16.
        ico.extend_from_slice(&[32, 32, 0, 0, 1, 0, 32, 0]);
        ico.extend_from_slice(&(png.len() as u32).to_le_bytes());
        ico.extend_from_slice(&22u32.to_le_bytes());
        ico.extend_from_slice(&png);
        assert_eq!(extract_ico_png(&ico).unwrap(), png);
    }

    #[test]
    fn ico_without_png_entry_returns_none() {
        let ico = vec![0, 0, 1, 0, 0, 0];
        assert!(extract_ico_png(&ico).is_none());
        assert!(extract_ico_png(b"not an ico").is_none());
    }

    #[test]
    fn ico_holding_raw_png_is_served_as_png() {
        let d = dir();
        let png = [PNG_MAGIC.as_slice(), b"fakepngdata"].concat();
        fs::write(d.path().join("favicon.ico"), &png).unwrap();
        let (_, bytes, mime) = resolve_uncached(&d.path().canonicalize().unwrap()).unwrap();
        assert_eq!(mime, "image/png");
        assert_eq!(bytes, png);
    }

    #[test]
    fn ico_oversized_entry_is_clamped() {
        let png = [PNG_MAGIC.as_slice(), b"fakepngdata"].concat();
        let mut ico = vec![0, 0, 1, 0, 1, 0];
        ico.extend_from_slice(&[32, 32, 0, 0, 1, 0, 32, 0]);
        // Declared size far past EOF — the payload is still recoverable.
        ico.extend_from_slice(&u32::MAX.to_le_bytes());
        ico.extend_from_slice(&22u32.to_le_bytes());
        ico.extend_from_slice(&png);
        assert_eq!(extract_ico_png(&ico).unwrap(), png);
    }

    #[test]
    fn bmp_only_ico_falls_through_to_next_candidate() {
        let d = dir();
        // BMP-style ICO (no PNG payload): header + one entry, no magic.
        let mut ico = vec![0, 0, 1, 0, 1, 0];
        ico.extend_from_slice(&[16, 16, 0, 0, 1, 0, 32, 0]);
        ico.extend_from_slice(&100u32.to_le_bytes());
        ico.extend_from_slice(&22u32.to_le_bytes());
        ico.extend_from_slice(&[0u8; 100]);
        fs::write(d.path().join("favicon.ico"), ico).unwrap();
        fs::write(d.path().join("icon.png"), b"png").unwrap();
        let hit = resolve_path(&d).unwrap();
        assert!(hit.ends_with("icon.png"));
    }
}
