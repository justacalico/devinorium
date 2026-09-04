import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('app icon asset is bundled and non-empty', () async {
    final data = await rootBundle.load('assets/icon.png');
    expect(data.lengthInBytes, greaterThan(0));
  });
}
