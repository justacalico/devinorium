import 'package:devinorium_frontend/merge_request/merge_request_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MergeRequestPipeline', () {
    test('parses from JSON', () {
      final pipeline = MergeRequestPipeline.fromJson({
        'status': 'failed',
        'name': 'lint-and-test',
        'web_url': 'https://gitlab.com/group/project/-/pipelines/7',
        'ref_name': 'feature',
      });

      expect(pipeline.status, 'failed');
      expect(pipeline.name, 'lint-and-test');
      expect(pipeline.webUrl, 'https://gitlab.com/group/project/-/pipelines/7');
      expect(pipeline.refName, 'feature');
      expect(pipeline.isPresent, isTrue);
    });

    test('treats empty status as not present', () {
      final pipeline = MergeRequestPipeline.fromJson({});

      expect(pipeline.status, '');
      expect(pipeline.isPresent, isFalse);
    });
  });
}
