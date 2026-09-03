import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _appId = 'gitlab.openlyst.devinorium';
const _legacyAppIdPrefix = 'com.example';

const _platformFiles = [
  'android/app/build.gradle.kts',
  'android/app/src/main/kotlin/gitlab/openlyst/devinorium/MainActivity.kt',
  'ios/Runner.xcodeproj/project.pbxproj',
  'macos/Runner.xcodeproj/project.pbxproj',
  'macos/Runner/Configs/AppInfo.xcconfig',
  'linux/CMakeLists.txt',
  'windows/runner/Runner.rc',
];

void main() {
  group('app id', () {
    for (final path in _platformFiles) {
      test(path, () {
        final content = File(path).readAsStringSync();
        expect(content, contains(_appId));
        expect(content, isNot(contains(_legacyAppIdPrefix)));
      });
    }
  });
}
