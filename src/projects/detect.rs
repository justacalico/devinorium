//! Project type detection by scanning for marker files.
//!
//! Each detector checks for the presence of a well-known config file in the
//! project root. The first match wins, ordered by specificity (e.g. Flutter
//! before Dart, since a Flutter project also has `pubspec.yaml`).

use std::path::Path;

/// Detect the project type by looking for marker files in the directory.
///
/// Returns a short string identifier like `"flutter"`, `"rust"`, `"node"`,
/// or `"generic"` if nothing matched.
pub fn detect_project_type(path: &Path) -> &'static str {
    for (file, ty) in MARKERS {
        if path.join(file).exists() {
            return ty;
        }
    }
    // .NET: check for any .csproj, .fsproj, or .vbproj file.
    if let Ok(entries) = std::fs::read_dir(path) {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if name.ends_with(".csproj")
                    || name.ends_with(".fsproj")
                    || name.ends_with(".vbproj")
                {
                    return "dotnet";
                }
            }
        }
    }
    "generic"
}

/// Marker files ordered by specificity. The first match wins.
const MARKERS: &[(&str, &str)] = &[
    // Flutter (check before plain Dart since both have pubspec.yaml).
    ("pubspec.yaml", "flutter"),
    // Rust.
    ("Cargo.toml", "rust"),
    // Node.js / JavaScript.
    ("package.json", "node"),
    // Python.
    ("pyproject.toml", "python"),
    ("setup.py", "python"),
    ("requirements.txt", "python"),
    // Go.
    ("go.mod", "go"),
    // Java / Kotlin (Maven).
    ("pom.xml", "java"),
    // Java / Kotlin (Gradle).
    ("build.gradle", "java"),
    ("build.gradle.kts", "java"),
    // C# / .NET — check for any .csproj or .fsproj file.
    // (Handled separately below since it's a glob, not an exact filename.)
    // Ruby.
    ("Gemfile", "ruby"),
    // PHP (Composer).
    ("composer.json", "php"),
    // Elixir.
    ("mix.exs", "elixir"),
    // Swift.
    ("Package.swift", "swift"),
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn detects_flutter() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("pubspec.yaml"), "").unwrap();
        assert_eq!(detect_project_type(dir.path()), "flutter");
    }

    #[test]
    fn detects_rust() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("Cargo.toml"), "").unwrap();
        assert_eq!(detect_project_type(dir.path()), "rust");
    }

    #[test]
    fn detects_node() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("package.json"), "{}").unwrap();
        assert_eq!(detect_project_type(dir.path()), "node");
    }

    #[test]
    fn detects_python_pyproject() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("pyproject.toml"), "").unwrap();
        assert_eq!(detect_project_type(dir.path()), "python");
    }

    #[test]
    fn detects_python_requirements() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("requirements.txt"), "").unwrap();
        assert_eq!(detect_project_type(dir.path()), "python");
    }

    #[test]
    fn detects_go() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("go.mod"), "").unwrap();
        assert_eq!(detect_project_type(dir.path()), "go");
    }

    #[test]
    fn detects_java_gradle() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("build.gradle.kts"), "").unwrap();
        assert_eq!(detect_project_type(dir.path()), "java");
    }

    #[test]
    fn detects_generic_when_no_markers() {
        let dir = TempDir::new().unwrap();
        assert_eq!(detect_project_type(dir.path()), "generic");
    }

    #[test]
    fn flutter_takes_priority_over_dart() {
        // A Flutter project has pubspec.yaml, which is also Dart's marker.
        // Since Flutter is listed first, it should win.
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("pubspec.yaml"), "name: test").unwrap();
        assert_eq!(detect_project_type(dir.path()), "flutter");
    }
}
