import 'package:devinorium_frontend/api/api_types.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/streaming_reducer.dart';
import 'package:devinorium_frontend/state/streaming_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reduceStreamingEvent plan_update', () {
    test('updates snapshot plan from plan_update event', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'plan_update',
          '{"explanation":"Build","steps":[{"step":"A","status":"completed"},{"step":"B","status":"pending"}]}',
          id: '1',
        ),
      );
      expect(res.snapshot.plan, isNotNull);
      expect(res.snapshot.plan!.explanation, 'Build');
      expect(res.snapshot.plan!.steps.length, 2);
      expect(res.snapshot.plan!.steps[0].isCompleted, isTrue);
      expect(res.snapshot.plan!.steps[1].isPending, isTrue);
      expect(res.snapshot.phase, StreamPhase.running);
    });

    test('ignores malformed plan_update', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('plan_update', 'not json', id: '1'),
      );
      expect(res.snapshot.plan, isNull);
    });

    test('applies plan from state event snapshot', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'state',
          '{"status":"running","parts":[],"plan":{"explanation":"P","steps":[{"step":"S","status":"in_progress"}]}}',
          id: '1',
        ),
      );
      expect(res.snapshot.plan, isNotNull);
      expect(res.snapshot.plan!.steps[0].isInProgress, isTrue);
    });
  });

  group('reduceStreamingEvent thinkingActive', () {
    test('is true when the last part is thinking', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('part', '{"type":"thinking","content":"hmm"}', id: '1'),
      );
      expect(res.snapshot.thinkingActive, isTrue);
    });

    test('is false when the last part is text', () {
      var snapshot = StreamingSnapshot.empty;
      var res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('part', '{"type":"thinking","content":"hmm"}', id: '1'),
      );
      snapshot = res.snapshot;
      res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('part', '{"type":"text","content":"hello"}', id: '2'),
      );
      expect(res.snapshot.thinkingActive, isFalse);
    });

    test('toggles back to true on a second thinking block', () {
      var snapshot = StreamingSnapshot.empty;
      for (final (seq, payload) in [
        (1, '{"type":"thinking","content":"first think"}'),
        (2, '{"type":"text","content":"switched"}'),
        (3, '{"type":"thinking","content":"second think"}'),
      ]) {
        final res = reduceStreamingEvent(
          detail: null,
          snapshot: snapshot,
          event: SseEvent('part', payload, id: '$seq'),
        );
        snapshot = res.snapshot;
      }
      expect(snapshot.parts, hasLength(3));
      expect(snapshot.parts.last.type, 'thinking');
      expect(snapshot.thinkingActive, isTrue);
    });

    test('stays false when interleaved blocks end on text', () {
      var snapshot = StreamingSnapshot.empty;
      for (final (seq, payload) in [
        (1, '{"type":"thinking","content":"first think"}'),
        (2, '{"type":"text","content":"a"}'),
        (3, '{"type":"thinking","content":"second think"}'),
        (4, '{"type":"text","content":"b"}'),
      ]) {
        final res = reduceStreamingEvent(
          detail: null,
          snapshot: snapshot,
          event: SseEvent('part', payload, id: '$seq'),
        );
        snapshot = res.snapshot;
      }
      expect(snapshot.parts.last.type, 'text');
      expect(snapshot.thinkingActive, isFalse);
    });

    test('is false for an empty snapshot', () {
      expect(StreamingSnapshot.empty.thinkingActive, isFalse);
    });
  });

  group('reduceStreamingEvent ask_request', () {
    test('sets pendingAsk from event', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'ask_request',
          '{"request_id":"a1","message":"Need input","questions":[{"id":"q1","prompt":"Value","field_type":"text"}]}',
          id: '1',
        ),
      );
      expect(res.snapshot.pendingAsk, isNotNull);
      expect(res.snapshot.pendingAsk!.requestId, 'a1');
      expect(res.snapshot.pendingAsk!.questions, hasLength(1));
      expect(res.snapshot.pendingAsk!.questions[0].fieldType, 'text');
    });

    test('clears pendingAsk on user_message', () {
      var snapshot = StreamingSnapshot.empty.copyWith(
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(id: 'q1', prompt: 'Value', fieldType: 'text'),
          ],
        ),
      );
      final res = reduceStreamingEvent(
        detail: ThreadDetail(
          thread: Thread(
            id: 't1',
            title: 'T',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
        ),
        snapshot: snapshot,
        event: SseEvent(
          'user_message',
          '{"role":"user","content":"hi"}',
          id: '2',
        ),
      );
      expect(res.snapshot.pendingAsk, isNull);
    });

    test('clears pendingAsk on done', () {
      var snapshot = StreamingSnapshot.empty.copyWith(
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(id: 'q1', prompt: 'Value', fieldType: 'text'),
          ],
        ),
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('done', '{"role":"assistant","content":"ok"}', id: '3'),
      );
      expect(res.snapshot.pendingAsk, isNull);
      expect(res.snapshot.phase, StreamPhase.completed);
    });
  });

  group('runSnapshotFromJson', () {
    test('restores pendingAsk from run snapshot', () {
      final snapshot = runSnapshotFromJson({
        'status': 'running',
        'ask_request': {
          'request_id': 'a1',
          'message': 'Need input',
          'questions': [
            {'id': 'q1', 'prompt': 'Value', 'field_type': 'text'},
          ],
        },
      });
      expect(snapshot.pendingAsk, isNotNull);
      expect(snapshot.pendingAsk!.requestId, 'a1');
      expect(snapshot.phase, StreamPhase.running);
    });

    test('extracts started_at from run snapshot', () {
      final snapshot = runSnapshotFromJson({
        'status': 'running',
        'started_at': '2025-01-01T00:00:00Z',
      });
      expect(snapshot.startedAt, '2025-01-01T00:00:00Z');
    });

    test('started_at is null when not present', () {
      final snapshot = runSnapshotFromJson({'status': 'running'});
      expect(snapshot.startedAt, isNull);
    });
  });

  group('startedAt lifecycle', () {
    test('state event sets startedAt', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'state',
          '{"status":"running","started_at":"2025-01-01T00:00:00Z"}',
          id: '1',
        ),
      );
      expect(res.snapshot.startedAt, '2025-01-01T00:00:00Z');
    });

    test('done event clears startedAt', () {
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        startedAt: '2025-01-01T00:00:00Z',
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('done', '{"role":"assistant","content":"ok"}', id: '2'),
      );
      expect(res.snapshot.startedAt, isNull);
    });

    test('stopped event sets stopped phase', () {
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        startedAt: '2025-01-01T00:00:00Z',
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('stopped', '{}', id: '2'),
      );
      expect(res.snapshot.phase, StreamPhase.stopped);
      expect(res.snapshot.thinkingActive, isFalse);
    });

    test('stopped event keeps parts visible', () {
      final parts = <MessagePart>[
        MessagePart.thinking(content: 'Let me think...'),
        MessagePart.text(content: 'Here is my answer'),
      ];
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        parts: parts,
        thinkingActive: true,
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('stopped', '{}', id: '2'),
      );
      expect(res.snapshot.phase, StreamPhase.stopped);
      expect(res.snapshot.parts, equals(parts));
      expect(res.snapshot.thinkingActive, isFalse);
    });

    test('done event clears parts', () {
      final parts = <MessagePart>[
        MessagePart.thinking(content: 'Let me think...'),
        MessagePart.text(content: 'Here is my answer'),
      ];
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        parts: parts,
        thinkingActive: true,
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('done', '{"role":"assistant","content":"ok"}', id: '2'),
      );
      expect(res.snapshot.parts, isEmpty);
      expect(res.snapshot.thinkingActive, isFalse);
    });

    test('error event clears startedAt', () {
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        startedAt: '2025-01-01T00:00:00Z',
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('error', 'something broke', id: '2'),
      );
      expect(res.snapshot.startedAt, isNull);
    });

    test('user_message event sets startedAt to now', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Test',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
        totalMessages: 0,
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'user_message',
          '{"role":"user","content":"hello"}',
          id: '1',
        ),
      );
      expect(res.snapshot.startedAt, isNotNull);
      final parsed = DateTime.tryParse(res.snapshot.startedAt!);
      expect(parsed, isNotNull);
      final diff = DateTime.now().toUtc().difference(parsed!).inSeconds.abs();
      expect(diff, lessThan(5));
    });

    test('user_message event appends a new message', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Test',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [Message(id: 1, role: 'user', content: 'first')],
        totalMessages: 1,
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'user_message',
          '{"id":2,"role":"user","content":"second"}',
          id: '2',
        ),
      );
      expect(res.detail!.messages, hasLength(2));
      expect(res.detail!.totalMessages, 2);
      expect(res.detail!.messages.last.id, 2);
    });

    test(
      'user_message event replaces an existing message with the same id',
      () {
        final detail = ThreadDetail(
          thread: Thread(
            id: 't1',
            title: 'Test',
            projectId: 1,
            model: 'm1',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          messages: [Message(id: 1, role: 'user', content: 'stale')],
          totalMessages: 1,
        );
        final res = reduceStreamingEvent(
          detail: detail,
          snapshot: StreamingSnapshot.empty,
          event: SseEvent(
            'user_message',
            '{"id":1,"role":"user","content":"fresh"}',
            id: '1',
          ),
        );
        expect(res.detail!.messages, hasLength(1));
        expect(res.detail!.totalMessages, 1);
        expect(res.detail!.messages.first.content, 'fresh');
      },
    );
  });

  group('reduceStreamingEvent thread_update', () {
    test('updates thread title and updated_at', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '2024-01-01T00:00:00.000Z',
          updatedAt: '2024-01-01T00:00:00.000Z',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"title":"New title","updated_at":"2024-01-02T00:00:00.000Z"}',
          id: '1',
        ),
      );
      expect(res.detail, isNotNull);
      expect(res.detail!.thread.title, 'New title');
      expect(res.detail!.thread.updatedAt, '2024-01-02T00:00:00.000Z');
      expect(res.snapshot.lastSeq, 1);
    });

    test('ignores malformed thread_update', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('thread_update', 'not json', id: '1'),
      );
      expect(res.detail!.thread.title, 'Old');
    });

    test('ignores thread_update when detail is null', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('thread_update', '{"title":"New"}', id: '1'),
      );
      expect(res.detail, isNull);
    });

    test('ignores thread_update with missing or empty title', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      );
      var res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"updated_at":"2024-01-02"}',
          id: '1',
        ),
      );
      expect(res.detail!.thread.title, 'Old');

      res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('thread_update', '{"title":""}', id: '2'),
      );
      expect(res.detail!.thread.title, 'Old');
    });

    test('tolerates non-string title fields', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('thread_update', '{"title":123}', id: '1'),
      );
      expect(res.detail!.thread.title, '123');
    });

    test('applies git worktree fields without a title', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
          branch: null,
          worktreePath: null,
          envMode: 'local',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"worktree_path":"/repo/.devinorium-worktrees/wt-1",'
              '"branch":"devinorium/wt-1","env_mode":"worktree"}',
          id: '1',
        ),
      );
      expect(res.detail!.thread.title, 'Old');
      expect(
        res.detail!.thread.worktreePath,
        '/repo/.devinorium-worktrees/wt-1',
      );
      expect(res.detail!.thread.branch, 'devinorium/wt-1');
      expect(res.detail!.thread.envMode, 'worktree');
      expect(res.snapshot.lastSeq, 1);
    });

    test('clears worktree fields when sent as null', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
          branch: 'devinorium/wt-1',
          worktreePath: '/repo/.devinorium-worktrees/wt-1',
          envMode: 'worktree',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"worktree_path":null,"branch":null,"env_mode":"local"}',
          id: '1',
        ),
      );
      expect(res.detail!.thread.branch, isNull);
      expect(res.detail!.thread.worktreePath, isNull);
      expect(res.detail!.thread.envMode, 'local');
    });

    test('leaves git fields untouched when keys are absent', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
          branch: 'main',
          worktreePath: '/repo/main',
          envMode: 'worktree',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"title":"New","updated_at":"2024-01-02T00:00:00.000Z"}',
          id: '1',
        ),
      );
      expect(res.detail!.thread.title, 'New');
      expect(res.detail!.thread.branch, 'main');
      expect(res.detail!.thread.worktreePath, '/repo/main');
      expect(res.detail!.thread.envMode, 'worktree');
    });

    test('updates title and git worktree fields together', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2024-01-01T00:00:00.000Z',
          branch: null,
          worktreePath: null,
          envMode: 'local',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"title":"New",'
              '"updated_at":"2024-01-02T00:00:00.000Z",'
              '"worktree_path":"/repo/.devinorium-worktrees/wt-1",'
              '"branch":"devinorium/wt-1",'
              '"env_mode":"worktree"}',
          id: '1',
        ),
      );
      expect(res.detail!.thread.title, 'New');
      expect(res.detail!.thread.updatedAt, '2024-01-02T00:00:00.000Z');
      expect(res.detail!.thread.branch, 'devinorium/wt-1');
      expect(
        res.detail!.thread.worktreePath,
        '/repo/.devinorium-worktrees/wt-1',
      );
      expect(res.detail!.thread.envMode, 'worktree');
      expect(res.snapshot.lastSeq, 1);
    });

    test('ignores non-string branch and worktree_path values', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
          branch: 'main',
          worktreePath: '/repo/main',
          envMode: 'local',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"branch":123,"worktree_path":456,"env_mode":"worktree"}',
          id: '1',
        ),
      );
      // Non-string values are ignored, so existing fields are preserved.
      expect(res.detail!.thread.branch, 'main');
      expect(res.detail!.thread.worktreePath, '/repo/main');
      // env_mode is a string, so it is still applied.
      expect(res.detail!.thread.envMode, 'worktree');
    });

    test('advances lastSeq on no-op thread_update', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Same',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2024-01-01T00:00:00.000Z',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"title":"Same","updated_at":"2024-01-01T00:00:00.000Z"}',
          id: '7',
        ),
      );
      expect(res.detail, detail);
      expect(res.snapshot.lastSeq, 7);
    });

    test('applies linked_mr from thread_update', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2024-01-01T00:00:00.000Z',
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"linked_mr":{"hostname":"gitlab.example.com",'
              '"project_path":"group/project","iid":42,'
              '"web_url":"https://gitlab.example.com/group/project/-/merge_requests/42"},'
              '"updated_at":"2024-01-02T00:00:00.000Z"}',
          id: '1',
        ),
      );
      expect(res.detail, isNotNull);
      expect(res.detail!.thread.linkedMr, isNotNull);
      expect(res.detail!.thread.linkedMr!.iid, 42);
      expect(
        res.detail!.thread.linkedMr!.webUrl,
        'https://gitlab.example.com/group/project/-/merge_requests/42',
      );
      expect(res.detail!.thread.updatedAt, '2024-01-02T00:00:00.000Z');
      expect(res.snapshot.lastSeq, 1);
    });

    test('clears linked_mr when sent as null', () {
      final ref = LinkedMergeRequestRef(
        hostname: 'gitlab.example.com',
        projectPath: 'group/project',
        iid: 42,
        webUrl: 'https://gitlab.example.com/group/project/-/merge_requests/42',
      );
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Old',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2024-01-01T00:00:00.000Z',
          linkedMr: ref,
        ),
        messages: [],
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'thread_update',
          '{"linked_mr":null,"updated_at":"2024-01-02T00:00:00.000Z"}',
          id: '1',
        ),
      );
      expect(res.detail, isNotNull);
      expect(res.detail!.thread.linkedMr, isNull);
      expect(res.detail!.thread.updatedAt, '2024-01-02T00:00:00.000Z');
      expect(res.snapshot.lastSeq, 1);
    });
  });

  group('StreamingSnapshot digest', () {
    test('part event updates digest incrementally', () {
      var snapshot = StreamingSnapshot.empty;
      final res1 = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('part', '{"type":"text","content":"a"}', id: '1'),
      );
      snapshot = res1.snapshot;
      expect(snapshot.parts, hasLength(1));
      expect(snapshot.digest, isNot(0));

      final res2 = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('part', '{"type":"text","content":"b"}', id: '2'),
      );
      expect(res2.snapshot.digest, isNot(snapshot.digest));
    });

    test('part_update changes digest when tool call output updates', () {
      final snapshot = runSnapshotFromJson({
        'status': 'running',
        'parts': [
          {
            'type': 'tool_call',
            'id': 'tc-1',
            'title': 'Read',
            'kind': 'read',
            'status': 'in_progress',
          },
        ],
      });
      final before = snapshot.digest;
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent(
          'part_update',
          '{"type":"tool_call","id":"tc-1","title":"Read","kind":"read","status":"completed","output":"hello"}',
          id: '2',
        ),
      );
      expect(res.snapshot.digest, isNot(before));
      expect(res.snapshot.parts.first.toolCall!.output, 'hello');
    });

    test('done event resets digest to zero', () {
      final snapshot = runSnapshotFromJson({
        'status': 'running',
        'parts': [{'type': 'text', 'content': 'x'}],
      });
      expect(snapshot.digest, isNot(0));
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('done', '{"role":"assistant","content":"x"}', id: '1'),
      );
      expect(res.snapshot.digest, 0);
      expect(res.snapshot.parts, isEmpty);
    });

    test('each part event returns a new parts list', () {
      final res1 = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('part', '{"type":"text","content":"a"}', id: '1'),
      );
      final res2 = reduceStreamingEvent(
        detail: null,
        snapshot: res1.snapshot,
        event: SseEvent('part', '{"type":"text","content":"b"}', id: '2'),
      );
      expect(res1.snapshot.parts, hasLength(1));
      expect(res2.snapshot.parts, hasLength(2));
      expect(identical(res1.snapshot.parts, res2.snapshot.parts), isFalse);
    });

    test('digest matches StreamingSnapshot.digestForParts', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('part', '{"type":"text","content":"a"}', id: '1'),
      );
      expect(
        res.snapshot.digest,
        StreamingSnapshot.digestForParts(res.snapshot.parts),
      );
      final res2 = reduceStreamingEvent(
        detail: null,
        snapshot: res.snapshot,
        event: SseEvent('part', '{"type":"text","content":"b"}', id: '2'),
      );
      expect(
        res2.snapshot.digest,
        StreamingSnapshot.digestForParts(res2.snapshot.parts),
      );
    });
  });
}
