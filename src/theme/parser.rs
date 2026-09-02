use std::collections::HashMap;

use super::{ColorTheme, ThemeMetadata};

/// An error encountered while parsing a theme file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThemeParseError {
    pub message: String,
    pub line: Option<usize>,
}

impl ThemeParseError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            line: None,
        }
    }

    fn new_with_line(message: impl Into<String>, line: usize) -> Self {
        Self {
            message: message.into(),
            line: Some(line),
        }
    }
}

impl std::fmt::Display for ThemeParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if let Some(line) = self.line {
            write!(f, "ThemeParseError at line {}: {}", line, self.message)
        } else {
            write!(f, "ThemeParseError: {}", self.message)
        }
    }
}

impl std::error::Error for ThemeParseError {}

/// Parses a restricted CSS-like format into a [ColorTheme].
///
/// Only these constructs are allowed:
///   * a leading `/* @theme ... */` block holding `version`, `creator`, and
///     `description` metadata
///   * a single `:root { ... }` block
///   * custom properties (`--name`) whose values are hex colors
///
/// Any standard selector, at-rule, layout property, or non-color value is
/// rejected so users can only change theme colours.
pub fn parse(css: &str, name: Option<&str>) -> Result<ColorTheme, ThemeParseError> {
    let (metadata, stripped) = strip_and_parse_metadata(css)?;
    let root_block = extract_root_block(&stripped)?;
    let colors = parse_root_block(&root_block)?;

    Ok(ColorTheme {
        colors,
        metadata,
        name: name.map(|s| s.to_string()),
    })
}

fn strip_and_parse_metadata(css: &str) -> Result<(ThemeMetadata, String), ThemeParseError> {
    let mut in_block = false;
    let mut buffer = String::new();
    let mut cleaned_lines = Vec::new();
    let mut block_start = None;

    for (index, line) in css.lines().enumerate() {
        let trimmed = line.trim();

        if !in_block {
            if trimmed.starts_with("/* @theme") {
                in_block = true;
                buffer.clear();
                block_start = Some(index);
                let rest = &trimmed["/* @theme".len()..];
                if let Some(end) = rest.find("*/") {
                    buffer.push_str(rest[..end].trim());
                    buffer.push('\n');
                    in_block = false;
                    cleaned_lines.push(String::new());
                    continue;
                } else {
                    buffer.push_str(rest.trim());
                    buffer.push('\n');
                    cleaned_lines.push(String::new());
                    continue;
                }
            }
            cleaned_lines.push(line.to_string());
        } else if let Some(end) = trimmed.find("*/") {
            buffer.push_str(trimmed[..end].trim());
            buffer.push('\n');
            in_block = false;
            cleaned_lines.push(String::new());
        } else {
            buffer.push_str(trimmed);
            buffer.push('\n');
            cleaned_lines.push(String::new());
        }
    }

    if in_block {
        return Err(ThemeParseError::new_with_line(
            "unclosed @theme metadata block",
            block_start.unwrap_or(0) + 1,
        ));
    }

    let stripped = cleaned_lines.join("\n");
    let metadata = parse_metadata_block(&buffer)?;
    Ok((metadata, stripped))
}

fn parse_metadata_block(raw: &str) -> Result<ThemeMetadata, ThemeParseError> {
    if raw.trim().is_empty() {
        return Ok(ThemeMetadata::new("1.0.0", "", ""));
    }

    let mut fields = HashMap::new();
    for line in raw.lines() {
        let clean = line
            .trim_start_matches(|c: char| c == '*' || c.is_whitespace())
            .trim();
        if clean.is_empty() {
            continue;
        }
        if let Some((key, value)) = clean.split_once(':') {
            fields.insert(
                key.trim().to_lowercase(),
                value.trim().to_string(),
            );
        }
    }

    Ok(ThemeMetadata {
        version: fields.remove("version").unwrap_or_else(|| "1.0.0".to_string()),
        creator: fields.remove("creator").unwrap_or_default(),
        description: fields.remove("description").unwrap_or_default(),
    })
}

fn extract_root_block(css: &str) -> Result<String, ThemeParseError> {
    if css.contains('@') {
        return Err(ThemeParseError::new("at-rules are not allowed"));
    }

    let root = css.find(":root").ok_or_else(|| ThemeParseError::new("missing :root block"))?;

    let before = css[..root].trim();
    if !before.is_empty() {
        return Err(ThemeParseError::new(
            "only a single :root block is allowed; remove selectors before it",
        ));
    }

    let open = css[root..].find('{').ok_or_else(|| {
        ThemeParseError::new(":root block is missing an opening brace")
    })? + root;

    let mut depth = 1;
    let mut close = open + 1;
    let bytes = css.as_bytes();
    while depth > 0 && close < css.len() {
        match bytes[close] as char {
            '{' => depth += 1,
            '}' => depth -= 1,
            _ => {}
        }
        close += 1;
    }

    if depth != 0 {
        return Err(ThemeParseError::new(":root block is missing a closing brace"));
    }

    let after = css[close..].trim();
    if !after.is_empty() {
        return Err(ThemeParseError::new(
            "only a single :root block is allowed; remove trailing content",
        ));
    }

    Ok(css[open + 1..close - 1].to_string())
}

fn parse_root_block(block: &str) -> Result<HashMap<String, u32>, ThemeParseError> {
    let mut colors = HashMap::new();

    for decl in split_declarations(block) {
        let decl = decl.trim();
        if decl.is_empty() {
            continue;
        }

        let Some((name, value)) = decl.split_once(':') else {
            continue;
        };

        let name = name.trim();
        let value = value.trim().trim_end_matches(';').trim();

        if name.is_empty() {
            continue;
        }

        if !name.starts_with("--") {
            return Err(ThemeParseError::new(format!(
                "only custom properties are allowed inside :root; found \"{}\"",
                name
            )));
        }

        let token = &name[2..];

        if FORBIDDEN_PROPERTIES.contains(&token) {
            return Err(ThemeParseError::new(format!(
                "layout or typography properties are not allowed: \"{}\"",
                name
            )));
        }

        if !ALLOWED_TOKENS.contains(&token) {
            return Err(ThemeParseError::new(format!(
                "unknown theme color token \"{}\"",
                token
            )));
        }

        let color = parse_color(value).ok_or_else(|| {
            ThemeParseError::new(format!(
                "value for \"{}\" must be a hex color, got \"{}\"",
                token, value
            ))
        })?;

        colors.insert(token.to_string(), color);
    }

    Ok(colors)
}

fn split_declarations(block: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let mut in_comment = false;
    let chars: Vec<char> = block.chars().collect();

    for i in 0..chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1);

        if c == '/' && next == Some(&'*') {
            in_comment = true;
            continue;
        }
        if c == '*' && next == Some(&'/') {
            in_comment = false;
            continue;
        }
        if in_comment {
            continue;
        }

        if c == ';' {
            let trimmed = current.trim().to_string();
            if !trimmed.is_empty() {
                result.push(trimmed);
            }
            current.clear();
        } else {
            current.push(c);
        }
    }

    let trimmed = current.trim().to_string();
    if !trimmed.is_empty() {
        result.push(trimmed);
    }

    result
}

fn parse_color(value: &str) -> Option<u32> {
    let trimmed = value.trim();
    if !trimmed.starts_with('#') {
        return None;
    }
    let hex = &trimmed[1..];

    if hex.len() == 6 {
        return u32::from_str_radix(hex, 16).ok().map(|v| 0xFF00_0000 | v);
    }

    if hex.len() == 8 {
        return u32::from_str_radix(hex, 16).ok();
    }

    None
}

const ALLOWED_TOKENS: &[&str] = &[
    "primary",
    "on-primary",
    "primary-container",
    "on-primary-container",
    "secondary",
    "on-secondary",
    "secondary-container",
    "on-secondary-container",
    "tertiary",
    "on-tertiary",
    "tertiary-container",
    "on-tertiary-container",
    "error",
    "on-error",
    "error-container",
    "on-error-container",
    "surface",
    "on-surface",
    "on-surface-variant",
    "surface-dim",
    "surface-bright",
    "surface-container-lowest",
    "surface-container-low",
    "surface-container",
    "surface-container-high",
    "surface-container-highest",
    "outline",
    "outline-variant",
    "shadow",
    "scrim",
    "inverse-surface",
    "on-inverse-surface",
    "inverse-primary",
    "surface-tint",
];

const FORBIDDEN_PROPERTIES: &[&str] = &[
    "display",
    "position",
    "top",
    "left",
    "right",
    "bottom",
    "width",
    "height",
    "min-width",
    "min-height",
    "max-width",
    "max-height",
    "margin",
    "margin-top",
    "margin-left",
    "margin-right",
    "margin-bottom",
    "padding",
    "padding-top",
    "padding-left",
    "padding-right",
    "padding-bottom",
    "border",
    "border-radius",
    "transform",
    "animation",
    "transition",
    "z-index",
    "flex",
    "grid",
    "float",
    "font",
    "font-size",
    "font-family",
    "font-weight",
    "line-height",
    "text-align",
    "cursor",
];

#[cfg(test)]
mod tests {
    use super::*;

    const LIGHT_CSS: &str = r#"
/* @theme
 * version: 1.0.0
 * creator: Devinorium
 * description: The default Material 3 light theme.
 */

:root {
  --primary: #6750A4;
  --on-primary: #FFFFFF;
  --surface: #FFFBFE;
  --on-surface: #1C1B1F;
}
"#;

    #[test]
    fn parses_metadata_and_colors() {
        let theme = parse(LIGHT_CSS, Some("Light")).unwrap();
        assert_eq!(theme.name.as_deref(), Some("Light"));
        assert_eq!(theme.metadata.version, "1.0.0");
        assert_eq!(theme.metadata.creator, "Devinorium");
        assert_eq!(theme.metadata.description, "The default Material 3 light theme.");
        assert_eq!(theme.colors.get("primary"), Some(&0xFF6750A4));
        assert_eq!(theme.colors.get("on-primary"), Some(&0xFFFFFFFF));
    }

    #[test]
    fn rejects_standard_selectors() {
        let css = r#"
/* @theme */
body { color: red; }
:root {
  --primary: #6750A4;
}
"#;
        let err = parse(css, None).unwrap_err();
        assert!(err.message.contains(":root"));
    }

    #[test]
    fn rejects_at_rules() {
        let css = r#"
/* @theme */
@media (prefers-color-scheme: dark) {
  :root {
    --primary: #000000;
  }
}
"#;
        let err = parse(css, None).unwrap_err();
        assert!(err.message.contains("at-rules"));
    }

    #[test]
    fn rejects_layout_properties() {
        let css = r#"
/* @theme */
:root {
  --primary: #6750A4;
  --display: block;
}
"#;
        let err = parse(css, None).unwrap_err();
        assert!(err.message.contains("display"));
    }

    #[test]
    fn rejects_unknown_tokens() {
        let css = r#"
/* @theme */
:root {
  --primary: #6750A4;
  --unknown-token: #000000;
}
"#;
        let err = parse(css, None).unwrap_err();
        assert!(err.message.contains("unknown theme color token"));
    }

    #[test]
    fn rejects_non_hex_colors() {
        let css = r#"
/* @theme */
:root {
  --primary: rgb(0, 0, 0);
}
"#;
        let err = parse(css, None).unwrap_err();
        assert!(err.message.contains("hex color"));
    }

    #[test]
    fn accepts_eight_digit_hex() {
        let css = r#"
/* @theme */
:root {
  --primary: #806750A4;
}
"#;
        let theme = parse(css, None).unwrap();
        assert_eq!(theme.colors.get("primary"), Some(&0x806750A4));
    }

    #[test]
    fn provides_default_metadata() {
        let css = r#"
:root {
  --primary: #6750A4;
}
"#;
        let theme = parse(css, None).unwrap();
        assert_eq!(theme.metadata.version, "1.0.0");
        assert!(theme.metadata.creator.is_empty());
    }

    #[test]
    fn trailing_content_after_root_is_rejected() {
        let css = r#"
/* @theme */
:root {
  --primary: #6750A4;
}
body { margin: 0; }
"#;
        let err = parse(css, None).unwrap_err();
        assert!(err.message.contains("trailing content"));
    }
}
