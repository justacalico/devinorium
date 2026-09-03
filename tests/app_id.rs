use std::fs;

const APP_ID: &str = "gitlab.openlyst.devinorium";
const LEGACY_APP_ID_PREFIX: &str = "com.example";

const PLATFORM_FILES: &[&str] = &[
    "flutter/android/app/build.gradle.kts",
    "flutter/android/app/src/main/kotlin/gitlab/openlyst/devinorium/MainActivity.kt",
    "flutter/ios/Runner.xcodeproj/project.pbxproj",
    "flutter/macos/Runner.xcodeproj/project.pbxproj",
    "flutter/macos/Runner/Configs/AppInfo.xcconfig",
    "flutter/linux/CMakeLists.txt",
    "flutter/windows/runner/Runner.rc",
];

#[test]
fn app_id_matches_platform_configs() {
    for path in PLATFORM_FILES {
        let content =
            fs::read_to_string(path).unwrap_or_else(|e| panic!("failed to read {path}: {e}"));
        assert!(
            content.contains(APP_ID),
            "{path} does not contain app id {APP_ID}"
        );
        assert!(
            !content.contains(LEGACY_APP_ID_PREFIX),
            "{path} still contains legacy app id prefix {LEGACY_APP_ID_PREFIX}"
        );
    }
}
