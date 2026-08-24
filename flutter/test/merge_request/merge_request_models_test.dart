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
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-02T00:00:00Z',
      });

      expect(pipeline.status, 'failed');
      expect(pipeline.name, 'lint-and-test');
      expect(pipeline.webUrl, 'https://gitlab.com/group/project/-/pipelines/7');
      expect(pipeline.refName, 'feature');
      expect(pipeline.createdAt, '2026-01-01T00:00:00Z');
      expect(pipeline.updatedAt, '2026-01-02T00:00:00Z');
      expect(pipeline.isPresent, isTrue);
    });

    test('treats empty status as not present', () {
      final pipeline = MergeRequestPipeline.fromJson({});

      expect(pipeline.status, '');
      expect(pipeline.isPresent, isFalse);
    });

    test('treats unfinished statuses as active', () {
      for (final status in ['running', 'PENDING', 'created', 'scheduled']) {
        expect(MergeRequestPipeline(status: status).isActive, isTrue,
            reason: status);
      }
      for (final status in ['success', 'failed', 'canceled', '']) {
        expect(MergeRequestPipeline(status: status).isActive, isFalse,
            reason: status);
      }
    });
  });

  group('MergeRequestDetail', () {
    MergeRequestDetail detail({
      String state = 'opened',
      bool draft = false,
      bool hasConflicts = false,
    }) =>
        MergeRequestDetail(
          title: 'MR',
          state: state,
          sourceBranch: 'feature',
          targetBranch: 'main',
          iid: 1,
          webUrl: '',
          draft: draft,
          hasConflicts: hasConflicts,
        );

    test('maps state to flags', () {
      expect(detail().isOpen, isTrue);
      expect(detail(state: 'open').isOpen, isTrue);
      expect(detail().isClosed, isFalse);
      expect(detail(state: 'closed').isClosed, isTrue);
      expect(detail(state: 'merged').isMerged, isTrue);
    });

    test('blocks merging for drafts, conflicts and non-open states', () {
      expect(detail().canMerge, isTrue);
      expect(detail(draft: true).canMerge, isFalse);
      expect(detail(hasConflicts: true).canMerge, isFalse);
      expect(detail(state: 'closed').canMerge, isFalse);
    });
  });

  group('MergeRequestAction', () {
    test('uses the wire names the backend expects', () {
      expect(MergeRequestAction.close.wire, 'close');
      expect(MergeRequestAction.reopen.wire, 'reopen');
      expect(MergeRequestAction.merge.wire, 'merge');
      expect(MergeRequestAction.mergeWhenPipelineSucceeds.wire,
          'merge_when_pipeline_succeeds');
    });
  });
}
