pub mod parser;

use std::collections::HashMap;

/// Metadata parsed from a CSS-like theme file's `@theme` block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThemeMetadata {
    pub version: String,
    pub creator: String,
    pub description: String,
}

impl Default for ThemeMetadata {
    fn default() -> Self {
        Self::new("1.0.0", "", "")
    }
}

impl ThemeMetadata {
    pub fn new(
        version: impl Into<String>,
        creator: impl Into<String>,
        description: impl Into<String>,
    ) -> Self {
        Self {
            version: version.into(),
            creator: creator.into(),
            description: description.into(),
        }
    }
}

/// A parsed color-only theme.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColorTheme {
    pub colors: HashMap<String, u32>,
    pub metadata: ThemeMetadata,
    pub name: Option<String>,
}

impl ColorTheme {
    pub fn new(
        colors: HashMap<String, u32>,
        metadata: ThemeMetadata,
        name: Option<String>,
    ) -> Self {
        Self {
            colors,
            metadata,
            name,
        }
    }
}

/// The user's active theme choice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ThemeChoice {
    System,
    BuiltIn(String),
    Custom(String, Option<String>),
}
