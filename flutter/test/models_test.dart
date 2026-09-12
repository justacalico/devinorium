import 'package:devinorium_frontend/api/sse_parser.dart';
import 'package:devinorium_frontend/l10n/l10n.dart';
import 'package:devinorium_frontend/models/composer_mode.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('User', () {
    test('parses provider_id with default fallback', () {
      final user = User.fromJson({
        'id': 1,
        'username': 'owner',
        'role': 'user',
        'totp_enabled': false,
      });
      expect(user.providerId, 'devin-cli');
      expect(user.providerCommand, 'devin');
    });

    test('parses explicit provider_id and command', () {
      final user = User.fromJson({
        'id': 1,
        'username': 'owner',
        'role': 'user',
        'totp_enabled': false,
        'provider_id': 'devin-cli',
        'provider_command': 'devin-cli',
      });
      expect(user.providerId, 'devin-cli');
      expect(user.providerCommand, 'devin-cli');
    });

    test('trims empty provider_command to devin', () {
      final user = User.fromJson({
        'id': 1,
        'username': 'owner',
        'role': 'user',
        'totp_enabled': false,
        'provider_command': '   ',
      });
      expect(user.providerCommand, 'devin');
    });

    test('copyWith updates providerId and command', () {
      final user = User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      );
      final updated = user.copyWith(
        providerId: 'other',
        providerCommand: 'other-cli',
      );
      expect(updated.providerId, 'other');
      expect(updated.providerCommand, 'other-cli');
    });

    test('copyWith preserves unchanged fields', () {
      final user = User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      );
      final updated = user.copyWith();
      expect(updated.id, 1);
      expect(updated.username, 'owner');
      expect(updated.providerId, 'devin-cli');
    });
  });

  group('ProviderInfo', () {
    test('parses availability fields from the server', () {
      final p = ProviderInfo.fromJson({
        'id': 'opencode',
        'name': 'OpenCode',
        'installed': false,
        'status': 'error',
        'version': null,
        'message': '`opencode` was not found on PATH',
      });
      expect(p.installed, isFalse);
      expect(p.status, 'error');
      expect(p.message, contains('not found'));
      expect(p.isAvailable, isFalse);
    });

    test('a missing binary keeps the provider visible but unavailable', () {
      final p = ProviderInfo.fromJson({
        'id': 'codex',
        'installed': true,
        'status': 'error',
      });
      expect(p.installed, isTrue);
      expect(p.isAvailable, isFalse);
    });

    test('defaults to available when the server omits the fields', () {
      final p = ProviderInfo.fromJson({'id': 'devin-cli', 'name': 'Devin CLI'});
      expect(p.installed, isTrue);
      expect(p.status, 'ready');
      expect(p.isAvailable, isTrue);
    });
  });

  group('ProviderVersion', () {
    test('parses a full version response', () {
      final v = ProviderVersion.fromJson({
        'provider_id': 'devin-cli',
        'provider_name': 'Devin CLI',
        'installed_version': '3000.6.13',
        'latest_version': '3000.6.14',
        'update_available': true,
      });
      expect(v.providerId, 'devin-cli');
      expect(v.providerName, 'Devin CLI');
      expect(v.installedVersion, '3000.6.13');
      expect(v.latestVersion, '3000.6.14');
      expect(v.updateAvailable, isTrue);
    });

    test('tolerates null and missing fields', () {
      final v = ProviderVersion.fromJson({
        'provider_id': 'devin-cli',
        'installed_version': null,
        'latest_version': null,
      });
      expect(v.providerId, 'devin-cli');
      expect(v.installedVersion, isNull);
      expect(v.latestVersion, isNull);
      expect(v.updateAvailable, isFalse);
    });

    test('empty json yields defaults', () {
      final v = ProviderVersion.fromJson(const {});
      expect(v.providerId, '');
      expect(v.installedVersion, isNull);
      expect(v.updateAvailable, isFalse);
    });
  });

  group('ModelInfo', () {
    test('parses reasoning effort metadata', () {
      final m = ModelInfo.fromJson({
        'id': 'gpt-5.4-terra',
        'label': 'GPT-5.4-Terra',
        'cost_tier': 'high',
        'family': 'gpt',
        'default_reasoning_effort': 'medium',
        'supported_reasoning_efforts': ['low', 'medium', 'high', 'xhigh'],
      });
      expect(m.defaultReasoningEffort, 'medium');
      expect(m.supportedReasoningEfforts, ['low', 'medium', 'high', 'xhigh']);
    });

    test('defaults reasoning fields when absent', () {
      final m = ModelInfo.fromJson({'id': 'm1'});
      expect(m.defaultReasoningEffort, isEmpty);
      expect(m.supportedReasoningEfforts, isEmpty);
    });
  });

  group('reasoningEffortLabel', () {
    test('maps known provider values to labels', () {
      expect(reasoningEffortLabel('low'), 'Low');
      expect(reasoningEffortLabel('xhigh'), 'Extra High');
      expect(reasoningEffortLabel('extra_high'), 'Extra High');
      expect(reasoningEffortLabel('unknown'), 'Unknown');
    });
  });

  group('effectiveReasoningEffort', () {
    final model = ModelInfo(
      id: 'm1',
      label: 'm1',
      costTier: 'free',
      family: 'f',
      defaultReasoningEffort: 'medium',
      supportedReasoningEfforts: const ['low', 'medium', 'high'],
    );

    test('keeps a supported selection', () {
      expect(effectiveReasoningEffort(model, 'high'), 'high');
    });

    test('falls back to the provider default', () {
      expect(effectiveReasoningEffort(model, ''), 'medium');
      expect(effectiveReasoningEffort(model, 'stale'), 'medium');
    });

    test('uses the first level when no default is advertised', () {
      final noDefault = ModelInfo(
        id: 'm2',
        label: 'm2',
        costTier: 'free',
        family: 'f',
        supportedReasoningEfforts: const ['low', 'high'],
      );
      expect(effectiveReasoningEffort(noDefault, ''), 'low');
    });

    test('returns empty when the model has no reasoning levels', () {
      final plain = ModelInfo(
        id: 'm3',
        label: 'm3',
        costTier: 'free',
        family: 'f',
      );
      expect(effectiveReasoningEffort(plain, 'high'), isEmpty);
      expect(effectiveReasoningEffort(null, 'high'), isEmpty);
    });
  });

  group('Plan', () {
    test('parses plan with steps and explanation', () {
      final plan = Plan.fromJson({
        'explanation': 'Build the thing',
        'steps': [
          {'step': 'A', 'status': 'completed'},
          {'step': 'B', 'status': 'in_progress'},
          {'step': 'C', 'status': 'pending'},
        ],
      });
      expect(plan.explanation, 'Build the thing');
      expect(plan.steps.length, 3);
      expect(plan.steps[0].step, 'A');
      expect(plan.steps[0].status, 'completed');
      expect(plan.progressPercent, 33);
    });

    test('progressPercent is zero for empty plan', () {
      final plan = Plan();
      expect(plan.progressPercent, 0);
      expect(plan.isEmpty, isTrue);
    });

    test('status helpers derive from status string', () {
      final step = PlanStep(step: 'X', status: 'in_progress');
      expect(step.isInProgress, isTrue);
      expect(step.isCompleted, isFalse);
      expect(step.isPending, isFalse);
    });

    test('copyWith replaces steps', () {
      final plan = Plan(
        explanation: 'E',
        steps: [PlanStep(step: 'A')],
      );
      final updated = plan.copyWith(
        steps: [PlanStep(step: 'A', status: 'completed')],
      );
      expect(updated.steps[0].isCompleted, isTrue);
      expect(updated.explanation, 'E');
    });

    test('ThreadDetail parses plan', () {
      final detail = ThreadDetail.fromJson({
        'thread': {
          'id': 't1',
          'title': 'Test',
          'project_id': 1,
          'model': 'm1',
          'permission_mode': 'normal',
          'created_at': '',
          'updated_at': '',
        },
        'messages': [],
        'total_messages': 0,
        'plan': {
          'explanation': 'Build',
          'steps': [
            {'step': 'A', 'status': 'completed'},
          ],
        },
      });
      expect(detail.plan, isNotNull);
      expect(detail.plan!.explanation, 'Build');
      expect(detail.plan!.steps[0].isCompleted, isTrue);
    });
  });

  group('LoginResponse', () {
    test('parses successful login', () {
      final res = LoginResponse.fromJson({
        'ok': true,
        'totp_required': false,
        'username': 'owner',
      });
      expect(res.ok, isTrue);
      expect(res.totpRequired, isFalse);
      expect(res.username, 'owner');
    });

    test('defaults missing totp_required to false', () {
      final res = LoginResponse.fromJson({'ok': true});
      expect(res.totpRequired, isFalse);
      expect(res.username, isEmpty);
    });
  });

  group('Attachment', () {
    test('parses filename and size', () {
      final a = Attachment.fromJson({'filename': 'x.png', 'size': 42});
      expect(a.filename, 'x.png');
      expect(a.size, 42);
    });
  });

  group('Message', () {
    test('parses plain message', () {
      final m = Message.fromJson({'role': 'user', 'content': 'hello'});
      expect(m.role, 'user');
      expect(m.content, 'hello');
      expect(m.thinking, isNull);
      expect(m.attachments, isNull);
    });

    test('parses message with attachments', () {
      final m = Message.fromJson({
        'role': 'user',
        'content': 'hello',
        'attachments': [
          {'filename': 'x.png', 'size': 1},
        ],
      });
      expect(m.attachments, hasLength(1));
      expect(m.attachments!.first.filename, 'x.png');
    });

    test('defaults missing content to empty', () {
      final m = Message.fromJson({'role': 'assistant'});
      expect(m.content, isEmpty);
    });

    test('parses model for assistant messages', () {
      final m = Message.fromJson({
        'role': 'assistant',
        'content': 'hello',
        'model': 'swe-1-7',
      });
      expect(m.model, 'swe-1-7');
    });

    test('defaults missing model to empty', () {
      final m = Message.fromJson({'role': 'assistant', 'content': 'hello'});
      expect(m.model, isEmpty);
    });

    test('copyWith updates content', () {
      final m = Message(role: 'user', content: 'hi');
      final updated = m.copyWith(content: 'hello');
      expect(updated.content, 'hello');
      expect(updated.role, 'user');
    });

    test('allParts falls back to content and thinking', () {
      final m = Message(role: 'assistant', content: 'hello', thinking: 'hmm');
      expect(m.allParts, hasLength(2));
      expect(m.allParts.first.type, 'text');
      expect(m.allParts.first.content, 'hello');
      expect(m.allParts[1].type, 'thinking');
      expect(m.allParts[1].content, 'hmm');
    });

    test('parses ordered parts', () {
      final m = Message.fromJson({
        'role': 'assistant',
        'content': 'final',
        'parts': [
          {'type': 'thinking', 'content': 'hmm'},
          {'type': 'text', 'content': 'hello'},
          {
            'type': 'tool_call',
            'id': 'tc-1',
            'title': 'Read file',
            'kind': 'read',
            'status': 'completed',
          },
        ],
      });
      expect(m.allParts, hasLength(3));
      expect(m.allParts[0].type, 'thinking');
      expect(m.allParts[1].type, 'text');
      expect(m.allParts[2].type, 'tool_call');
      expect(m.allParts[2].toolCall?.id, 'tc-1');
    });

    test('allParts uses parts field when present', () {
      final m = Message.fromJson({
        'role': 'assistant',
        'content': 'legacy',
        'parts': [
          {'type': 'text', 'content': 'new'},
        ],
      });
      expect(m.allParts.first.content, 'new');
    });
  });

  group('ToolCallData', () {
    test('parses required fields', () {
      final tc = ToolCallData.fromJson({
        'id': '1',
        'title': 'Run tests',
        'kind': 'command',
        'status': 'running',
      });
      expect(tc.id, '1');
      expect(tc.title, 'Run tests');
      expect(tc.kind, 'command');
      expect(tc.status, 'running');
      expect(tc.changedFiles, isEmpty);
    });

    test('parses optional fields', () {
      final tc = ToolCallData.fromJson({
        'id': '1',
        'title': 'Run tests',
        'kind': 'command',
        'status': 'done',
        'command': 'cargo test',
        'output': 'ok',
        'output_preview': 'ok',
        'changed_files': ['a.rs'],
      });
      expect(tc.command, 'cargo test');
      expect(tc.output, 'ok');
      expect(tc.outputPreview, 'ok');
      expect(tc.changedFiles, ['a.rs']);
    });

    test('copyWith updates fields', () {
      final tc = ToolCallData(id: '1', title: 'x', kind: 'x', status: 'x');
      final updated = tc.copyWith(status: 'done', output: 'ok');
      expect(updated.status, 'done');
      expect(updated.output, 'ok');
      expect(updated.title, 'x');
    });

    test('preserves multibyte output preview', () {
      const preview = '中文工具输出 🌍 这是一个测试...';
      final tc = ToolCallData.fromJson({
        'id': '1',
        'title': 'Run tests',
        'kind': 'command',
        'status': 'done',
        'output_preview': preview,
      });
      expect(tc.outputPreview, preview);
    });

    test('parses diffs with old and new text', () {
      final tc = ToolCallData.fromJson({
        'id': '1',
        'title': 'Edit file',
        'kind': 'edit',
        'status': 'completed',
        'diffs': [
          {
            'path': '/tmp/src/main.rs',
            'old_text': 'fn main() {\n    todo!()\n}\n',
            'new_text': 'fn main() {}\n',
          },
          {'path': '/tmp/src/new.rs', 'new_text': 'pub fn x() {}\n'},
        ],
      });
      expect(tc.diffs, hasLength(2));
      expect(tc.diffs[0].path, '/tmp/src/main.rs');
      expect(tc.diffs[0].oldText, 'fn main() {\n    todo!()\n}\n');
      expect(tc.diffs[0].newText, 'fn main() {}\n');
      expect(tc.diffs[1].path, '/tmp/src/new.rs');
      expect(tc.diffs[1].oldText, isNull);
      expect(tc.diffs[1].newText, 'pub fn x() {}\n');
    });

    test('diffs default to empty when absent', () {
      final tc = ToolCallData.fromJson({
        'id': '1',
        'title': 'Edit file',
        'kind': 'edit',
        'status': 'completed',
      });
      expect(tc.diffs, isEmpty);
    });

    test('copyWith updates diffs', () {
      final tc = ToolCallData(id: '1', title: 'x', kind: 'edit', status: 'x');
      final updated = tc.copyWith(
        diffs: [FileDiff(path: '/a.rs', newText: 'a')],
      );
      expect(updated.diffs, hasLength(1));
      expect(updated.diffs[0].path, '/a.rs');
    });

    test('equality considers diffs', () {
      final a = ToolCallData(
        id: '1',
        title: 'x',
        kind: 'edit',
        status: 'x',
        diffs: [FileDiff(path: '/a.rs', oldText: 'old', newText: 'new')],
      );
      final b = ToolCallData(
        id: '1',
        title: 'x',
        kind: 'edit',
        status: 'x',
        diffs: [FileDiff(path: '/a.rs', oldText: 'old', newText: 'new')],
      );
      final c = ToolCallData(
        id: '1',
        title: 'x',
        kind: 'edit',
        status: 'x',
        diffs: [FileDiff(path: '/a.rs', oldText: 'old', newText: 'different')],
      );
      expect(a, b);
      expect(a == c, isFalse);
    });
  });

  group('FileDiff', () {
    test('parses required and optional fields', () {
      final d = FileDiff.fromJson({
        'path': '/x.rs',
        'old_text': 'old',
        'new_text': 'new',
      });
      expect(d.path, '/x.rs');
      expect(d.oldText, 'old');
      expect(d.newText, 'new');
    });

    test('old_text defaults to null', () {
      final d = FileDiff.fromJson({'path': '/x.rs', 'new_text': 'new'});
      expect(d.oldText, isNull);
    });

    test('round-trips through toJson', () {
      final d = FileDiff(path: '/x.rs', oldText: 'old', newText: 'new');
      final json = d.toJson();
      expect(json['path'], '/x.rs');
      expect(json['old_text'], 'old');
      expect(json['new_text'], 'new');
      expect(FileDiff.fromJson(json), d);
    });

    test('toJson omits null old_text', () {
      final d = FileDiff(path: '/x.rs', newText: 'new');
      expect(d.toJson().containsKey('old_text'), isFalse);
    });

    test('equality and hashCode', () {
      final a = FileDiff(path: '/x', oldText: 'o', newText: 'n');
      final b = FileDiff(path: '/x', oldText: 'o', newText: 'n');
      final c = FileDiff(path: '/x', oldText: 'o', newText: 'other');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });

  group('MessagePart', () {
    test('parses text and thinking', () {
      final p = MessagePart.fromJson({'type': 'text', 'content': 'hello'});
      expect(p.type, 'text');
      expect(p.content, 'hello');

      final t = MessagePart.fromJson({'type': 'thinking', 'content': 'hmm'});
      expect(t.type, 'thinking');
      expect(t.content, 'hmm');
    });

    test('parses tool call', () {
      final p = MessagePart.fromJson({
        'type': 'tool_call',
        'id': 'tc-1',
        'title': 'Read file',
        'kind': 'read',
        'status': 'completed',
        'command': 'cat file.txt',
      });
      expect(p.type, 'tool_call');
      expect(p.id, 'tc-1');
      expect(p.toolCall?.title, 'Read file');
    });

    test('tool_call part carries id', () {
      final p = MessagePart.toolCall(
        toolCall: ToolCallData(
          id: 'tc-1',
          title: 'x',
          kind: 'read',
          status: 'completed',
        ),
      );
      expect(p.id, 'tc-1');
    });
  });

  group('Project', () {
    test('parses project fields', () {
      final p = Project.fromJson({
        'id': 1,
        'name': 'My Project',
        'path': '/tmp/my-project',
        'position': 5,
        'pinned': true,
        'is_repo': true,
        'branch': 'main',
        'project_type': 'flutter',
        'created_at': '2026-01-01',
        'updated_at': '2026-01-02',
      });
      expect(p.id, 1);
      expect(p.name, 'My Project');
      expect(p.path, '/tmp/my-project');
      expect(p.position, 5);
      expect(p.pinned, isTrue);
      expect(p.isRepo, true);
      expect(p.gitBranch, 'main');
      expect(p.projectType, 'flutter');
      expect(p.createdAt, '2026-01-01');
      expect(p.updatedAt, '2026-01-02');
    });

    test('defaults pinned to false when missing', () {
      final p = Project.fromJson({
        'id': 1,
        'name': 'x',
        'path': '/tmp',
        'created_at': '',
        'updated_at': '',
      });
      expect(p.pinned, isFalse);
    });

    test('copyWith updates pinned', () {
      final p = Project(
        id: 1,
        name: 'x',
        path: '/tmp/x',
        createdAt: '',
        updatedAt: '',
      );
      final updated = p.copyWith(pinned: true);
      expect(updated.pinned, isTrue);
      expect(updated.name, 'x');
    });

    test('fromJson defaults project_type to generic when missing', () {
      final p = Project.fromJson({
        'id': 1,
        'name': 'x',
        'path': '/tmp',
        'created_at': '',
        'updated_at': '',
      });
      expect(p.projectType, 'generic');
    });

    test('copyWith updates git fields', () {
      final p = Project(
        id: 1,
        name: 'x',
        path: '/tmp/x',
        createdAt: '',
        updatedAt: '',
      );
      final updated = p.copyWith(isRepo: true, gitBranch: 'develop');
      expect(updated.isRepo, true);
      expect(updated.gitBranch, 'develop');
      expect(updated.name, 'x');
    });

    test('parses branch and worktree_path', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'branch': 'feature-x',
        'worktree_path': '/tmp/project-wt',
      });
      expect(t.branch, 'feature-x');
      expect(t.worktreePath, '/tmp/project-wt');
    });

    test('defaults missing position to 0', () {
      final p = Project.fromJson({'id': 1, 'name': 'x', 'path': 'y'});
      expect(p.position, 0);
    });

    test('defaults missing timestamps to empty', () {
      final p = Project.fromJson({'id': 1, 'name': 'x', 'path': 'y'});
      expect(p.createdAt, isEmpty);
      expect(p.updatedAt, isEmpty);
    });
  });

  group('Thread', () {
    test('parses thread', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'model': 'glm-5-2',
        'permission_mode': 'normal',
        'pinned': true,
        'created_at': '2026-01-01',
        'updated_at': '2026-01-02',
      });
      expect(t.id, 'abc');
      expect(t.title, 'Thread');
      expect(t.projectId, 1);
      expect(t.model, 'glm-5-2');
      expect(t.permissionMode, 'normal');
      expect(t.pinned, isTrue);
      expect(t.threadGroupId, isNull);
      expect(t.devinSessionId, isNull);
    });

    test('defaults pinned to false when missing', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
      });
      expect(t.pinned, isFalse);
    });

    test('copyWith updates pinned', () {
      final t = Thread(
        id: 'abc',
        title: 'Thread',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
      );
      final updated = t.copyWith(pinned: true);
      expect(updated.pinned, isTrue);
      expect(updated.title, 'Thread');
    });

    test('defaults permission_mode and model', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
      });
      expect(t.model, isEmpty);
      expect(t.permissionMode, 'normal');
    });

    test('parses reasoning_effort', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'model': 'gpt-5.4-terra',
        'permission_mode': 'normal',
        'reasoning_effort': 'high',
      });
      expect(t.reasoningEffort, 'high');
    });

    test('parses env_mode and defaults to local', () {
      final worktree = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'env_mode': 'worktree',
      });
      expect(worktree.envMode, 'worktree');

      final local = Thread.fromJson({
        'id': 'def',
        'title': 'Thread',
        'project_id': 1,
      });
      expect(local.envMode, 'local');
    });

    test('copyWith updates env_mode', () {
      final t = Thread(
        id: 'abc',
        title: 'Thread',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
      );
      final updated = t.copyWith(envMode: 'worktree');
      expect(updated.envMode, 'worktree');
      expect(updated.title, 'Thread');
    });

    test('copyWith updates branch and worktreePath', () {
      final t = Thread(
        id: 'abc',
        title: 'Thread',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
        branch: 'main',
        worktreePath: '/repo/main',
      );
      final updated = t.copyWith(
        branch: 'devinorium/wt-1',
        worktreePath: '/repo/.devinorium-worktrees/wt-1',
      );
      expect(updated.branch, 'devinorium/wt-1');
      expect(updated.worktreePath, '/repo/.devinorium-worktrees/wt-1');
      expect(updated.title, 'Thread');
    });

    test('copyWith can clear branch and worktreePath', () {
      final t = Thread(
        id: 'abc',
        title: 'Thread',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
        branch: 'main',
        worktreePath: '/repo/main',
      );
      final updated = t.copyWith(branch: null, worktreePath: null);
      expect(updated.branch, isNull);
      expect(updated.worktreePath, isNull);
    });

    test('copyWith preserves branch and worktreePath when omitted', () {
      final t = Thread(
        id: 'abc',
        title: 'Thread',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
        branch: 'main',
        worktreePath: '/repo/main',
      );
      final updated = t.copyWith(title: 'New');
      expect(updated.branch, 'main');
      expect(updated.worktreePath, '/repo/main');
    });

    test('parses linked_mr from json', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'linked_mr': {
          'hostname': 'gitlab.example.com',
          'project_path': 'g/p',
          'iid': 7,
          'web_url': 'https://gitlab.example.com/g/p/-/merge_requests/7',
        },
      });
      expect(t.linkedMr, isNotNull);
      expect(t.linkedMr!.iid, 7);
      expect(
        t.linkedMr!.webUrl,
        'https://gitlab.example.com/g/p/-/merge_requests/7',
      );
    });

    test('ignores malformed linked_mr', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'linked_mr': 'not-a-map',
      });
      expect(t.linkedMr, isNull);
    });

    test('worktreeName uses basename of worktree_path', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'worktree_path': '/repo/.devinorium-worktrees/feature-x',
        'branch': 'feature/x',
      });
      expect(t.worktreeName, 'feature-x');
    });

    test('worktreeName falls back to branch for worktree mode', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'env_mode': 'worktree',
        'branch': 'feature/x',
      });
      expect(t.worktreeName, 'feature/x');
    });

    test('worktreeName is null for local mode without worktree', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'branch': 'main',
      });
      expect(t.worktreeName, isNull);
    });

    test('worktreeName is null when branch and worktree_path are empty', () {
      final t = Thread(
        id: 'abc',
        title: 'Thread',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
      );
      expect(t.worktreeName, isNull);
    });

    test('worktreeName handles Windows backslash paths', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'worktree_path': r'C:\repo\.devinorium-worktrees\feature-x',
      });
      expect(t.worktreeName, 'feature-x');
    });

    test('worktreeName handles trailing slash', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'worktree_path': '/repo/.devinorium-worktrees/feature-x/',
      });
      expect(t.worktreeName, 'feature-x');
    });

    test('worktreeName rejects empty worktree_path with branch fallback', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'env_mode': 'worktree',
        'branch': 'feature/x',
        'worktree_path': '',
      });
      expect(t.worktreeName, 'feature/x');
    });

    test('worktreeName rejects root-only worktree_path', () {
      final posix = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'worktree_path': '/',
        'branch': 'feature/x',
        'env_mode': 'worktree',
      });
      expect(posix.worktreeName, 'feature/x');

      final windows = Thread.fromJson({
        'id': 'def',
        'title': 'Thread',
        'project_id': 1,
        'worktree_path': r'C:\',
        'branch': 'feature/x',
        'env_mode': 'worktree',
      });
      expect(windows.worktreeName, 'feature/x');
    });

    test('worktreeName is null for worktree mode without branch or path', () {
      final t = Thread.fromJson({
        'id': 'abc',
        'title': 'Thread',
        'project_id': 1,
        'env_mode': 'worktree',
      });
      expect(t.worktreeName, isNull);
    });
  });

  group('ThreadGroup', () {
    test('parses thread group', () {
      final g = ThreadGroup.fromJson({
        'id': 1,
        'name': 'Group',
        'position': 0,
        'created_at': '2026-01-01',
      });
      expect(g.id, 1);
      expect(g.name, 'Group');
      expect(g.position, 0);
    });
  });

  group('ThreadDetail', () {
    test('parses thread detail with messages', () {
      final d = ThreadDetail.fromJson({
        'thread': {'id': 'abc', 'title': 'Thread', 'project_id': 1},
        'messages': [
          {'role': 'user', 'content': 'hello'},
        ],
      });
      expect(d.thread.id, 'abc');
      expect(d.messages, hasLength(1));
      expect(d.messages.first.content, 'hello');
    });

    test('copyWith replaces messages', () {
      final d = ThreadDetail(
        thread: Thread(
          id: 'abc',
          title: 'Thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      );
      final m = Message(role: 'user', content: 'hi');
      final updated = d.copyWith(messages: [m]);
      expect(updated.messages, [m]);
    });
  });

  group('ProviderInfo', () {
    test('parses id and name', () {
      final p = ProviderInfo.fromJson({'id': 'devin-cli', 'name': 'Devin CLI'});
      expect(p.id, 'devin-cli');
      expect(p.name, 'Devin CLI');
    });

    test('falls back to id when name is missing', () {
      final p = ProviderInfo.fromJson({'id': 'devin-cli'});
      expect(p.name, 'devin-cli');
    });
  });

  group('ModelInfo', () {
    test('parses all fields', () {
      final m = ModelInfo.fromJson({
        'id': 'glm-5-2',
        'label': 'GLM 5.2',
        'cost_tier': 'free',
        'family': 'glm',
        'cost_summary': 'free',
        'max_context_tokens': 8192,
        'max_output_tokens': 1024,
        'is_new': true,
        'is_beta': false,
      });
      expect(m.id, 'glm-5-2');
      expect(m.label, 'GLM 5.2');
      expect(m.costTier, 'free');
      expect(m.family, 'glm');
      expect(m.costSummary, 'free');
      expect(m.maxContextTokens, 8192);
      expect(m.maxOutputTokens, 1024);
      expect(m.isNew, isTrue);
      expect(m.isBeta, isFalse);
    });

    test('defaults missing fields', () {
      final m = ModelInfo.fromJson({'id': 'x'});
      expect(m.label, 'x');
      expect(m.costSummary, isEmpty);
      expect(m.maxContextTokens, 0);
      expect(m.isNew, isFalse);
    });

    test('isFree matches free tier or summary', () {
      expect(
        ModelInfo(id: 'a', label: 'a', costTier: 'free', family: 'f').isFree,
        isTrue,
      );
      expect(
        ModelInfo(
          id: 'b',
          label: 'b',
          costTier: 'low',
          family: 'f',
          costSummary: 'Free',
        ).isFree,
        isTrue,
      );
      expect(
        ModelInfo(id: 'c', label: 'c', costTier: 'high', family: 'f').isFree,
        isFalse,
      );
    });

    test('isPromo matches promo tier or summary', () {
      expect(
        ModelInfo(id: 'a', label: 'a', costTier: 'promo', family: 'f').isPromo,
        isTrue,
      );
      expect(
        ModelInfo(
          id: 'b',
          label: 'b',
          costTier: 'paid',
          family: 'f',
          costSummary: 'Promo pricing',
        ).isPromo,
        isTrue,
      );
      expect(
        ModelInfo(id: 'c', label: 'c', costTier: 'high', family: 'f').isPromo,
        isFalse,
      );
    });
  });

  group('FileContent', () {
    test('parses content with diff', () {
      final c = FileContent.fromJson({
        'path': '/x.rs',
        'mime': 'text/x-rust',
        'size': 12,
        'base64': 'Zm4gbWFpbigpIHt9',
        'text': null,
        'diff': {'path': '/x.rs', 'old_text': 'old', 'new_text': 'new'},
      });
      expect(c.path, '/x.rs');
      expect(c.text, 'new');
      expect(c.diff?.oldText, 'old');
      expect(c.diff?.newText, 'new');
    });

    test('falls back to text when diff is absent', () {
      final c = FileContent.fromJson({
        'path': '/x.rs',
        'mime': 'text/plain',
        'size': 4,
        'base64': 'aGVsbA==',
        'text': 'hello',
      });
      expect(c.text, 'hello');
      expect(c.diff, isNull);
    });

    test('defaults missing fields', () {
      final c = FileContent.fromJson({'path': '/bin'});
      expect(c.mime, 'application/octet-stream');
      expect(c.size, 0);
      expect(c.base64, '');
      expect(c.text, isNull);
    });

    test('parses sha256 and lastModified', () {
      final c = FileContent.fromJson({
        'path': '/x.txt',
        'mime': 'text/plain',
        'size': 0,
        'base64': '',
        'text': 'hi',
        'sha256': 'abcd',
        'last_modified': '2026-08-29T12:00:00Z',
      });
      expect(c.sha256, 'abcd');
      expect(c.lastModified, DateTime.utc(2026, 8, 29, 12, 0, 0));
    });

    test('copyWith updates sha256 and lastModified', () {
      final c = FileContent(
        path: '/x.txt',
        mime: 'text/plain',
        size: 0,
        base64: '',
        text: 'hi',
      );
      final updated = c.copyWith(
        sha256: 'xyz',
        lastModified: DateTime.utc(2026),
      );
      expect(updated.sha256, 'xyz');
      expect(updated.lastModified, DateTime.utc(2026));
    });
  });

  group('DirEntry', () {
    test('parses entry', () {
      final e = DirEntry.fromJson({
        'name': 'foo.txt',
        'is_dir': false,
        'size': 123,
      });
      expect(e.name, 'foo.txt');
      expect(e.isDir, isFalse);
      expect(e.size, 123);
      expect(e.gitStatus, isNull);
    });

    test('defaults is_dir to false', () {
      final e = DirEntry.fromJson({'name': 'x', 'size': 0});
      expect(e.isDir, isFalse);
    });

    test('parses git_status', () {
      final e = DirEntry.fromJson({
        'name': 'foo.txt',
        'is_dir': false,
        'size': 123,
        'git_status': 'modified',
      });
      expect(e.gitStatus, 'modified');
    });
  });

  group('User', () {
    test('parses is_owner and disabled', () {
      final user = User.fromJson({
        'id': 1,
        'username': 'owner',
        'role': 'user',
        'is_owner': true,
        'disabled': true,
        'totp_enabled': true,
        'created_at': '2026-01-01',
      });
      expect(user.isOwner, isTrue);
      expect(user.disabled, isTrue);
      expect(user.totpEnabled, isTrue);
      expect(user.createdAt, '2026-01-01');
    });

    test('defaults is_owner, disabled and created_at', () {
      final user = User.fromJson({
        'id': 1,
        'username': 'owner',
        'role': 'user',
        'totp_enabled': false,
      });
      expect(user.isOwner, isFalse);
      expect(user.disabled, isFalse);
      expect(user.createdAt, isEmpty);
    });

    test('copyWith preserves is_owner and disabled', () {
      final user = User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        disabled: true,
        createdAt: '2026-01-01',
        providerId: 'devin-cli',
        providerCommand: 'devin',
      );
      final updated = user.copyWith(providerId: 'other');
      expect(updated.isOwner, isTrue);
      expect(updated.disabled, isTrue);
      expect(updated.createdAt, '2026-01-01');
    });
  });

  group('TotpSetupResponse', () {
    test('parses totp setup', () {
      final t = TotpSetupResponse.fromJson({
        'secret': 'secret',
        'otpauth_uri': 'otpauth://...',
      });
      expect(t.secret, 'secret');
      expect(t.otpauthUri, 'otpauth://...');
    });

    test('defaults missing otpauth_uri', () {
      final t = TotpSetupResponse.fromJson({'secret': 'secret'});
      expect(t.otpauthUri, isEmpty);
    });
  });

  group('PermissionOption', () {
    test('parses option', () {
      final o = PermissionOption.fromJson({
        'id': 'allow',
        'kind': 'Exec',
        'label': 'Allow',
      });
      expect(o.id, 'allow');
      expect(o.kind, 'Exec');
      expect(o.label, 'Allow');
    });

    test('defaults kind to empty', () {
      final o = PermissionOption.fromJson({'id': 'x'});
      expect(o.kind, isEmpty);
    });
  });

  group('PermissionRequest', () {
    test('parses request with options', () {
      final p = PermissionRequest.fromJson({
        'request_id': 'r1',
        'scope': 'Exec(curl)',
        'title': 'Run curl?',
        'input': 'curl https://x',
        'options': [
          {'id': 'allow', 'kind': 'Exec'},
        ],
      });
      expect(p.requestId, 'r1');
      expect(p.scope, 'Exec(curl)');
      expect(p.title, 'Run curl?');
      expect(p.input, 'curl https://x');
      expect(p.options, hasLength(1));
    });

    test('defaults missing fields', () {
      final p = PermissionRequest.fromJson({'request_id': 'r1'});
      expect(p.title, 'Unknown action');
      expect(p.options, isEmpty);
    });
  });

  group('LoginResponse', () {
    test('parses login fields including token', () {
      final p = LoginResponse.fromJson({
        'ok': true,
        'totp_required': false,
        'username': 'owner',
        'token': 'abc123',
      });
      expect(p.ok, true);
      expect(p.totpRequired, false);
      expect(p.username, 'owner');
      expect(p.token, 'abc123');
    });

    test('defaults missing fields', () {
      final p = LoginResponse.fromJson({'ok': true});
      expect(p.token, '');
      expect(p.username, '');
      expect(p.totpRequired, false);
      expect(p.ok, true);
    });
  });

  group('GitRepoInfo', () {
    test('parses repo status', () {
      final r = GitRepoInfo.fromJson({
        'is_repo': true,
        'branch': 'main',
        'worktree_path': '/tmp/project',
        'toplevel': '/tmp/project',
        'common_dir': '/tmp/project/.git',
        'ahead': 2,
        'behind': 3,
      });
      expect(r.isRepo, isTrue);
      expect(r.branch, 'main');
      expect(r.worktreePath, '/tmp/project');
      expect(r.ahead, 2);
      expect(r.behind, 3);
    });

    test('defaults missing fields to empty', () {
      final r = GitRepoInfo.fromJson({});
      expect(r.isRepo, isFalse);
      expect(r.branch, isEmpty);
      expect(r.ahead, 0);
      expect(r.behind, 0);
    });
  });

  group('GitBranch', () {
    test('parses branch flags', () {
      final b = GitBranch.fromJson({
        'name': 'main',
        'refname': 'refs/heads/main',
        'is_current': true,
        'is_default': true,
        'is_remote': false,
        'committer_date': 1234567890,
        'ahead': 2,
        'behind': 3,
      });
      expect(b.name, 'main');
      expect(b.refname, 'refs/heads/main');
      expect(b.isCurrent, isTrue);
      expect(b.isDefault, isTrue);
      expect(b.isRemote, isFalse);
      expect(b.committerDate, 1234567890);
      expect(b.ahead, 2);
      expect(b.behind, 3);
    });
  });

  group('GitWorktree', () {
    test('parses worktree', () {
      final w = GitWorktree.fromJson({
        'path': '/tmp/project-wt',
        'head': 'abc123',
        'branch': 'refs/heads/main',
        'is_main': false,
      });
      expect(w.path, '/tmp/project-wt');
      expect(w.branch, 'refs/heads/main');
      expect(w.isMain, isFalse);
    });
  });

  group('GitStatus', () {
    test('parses status counters', () {
      final s = GitStatus.fromJson({
        'ahead': 1,
        'behind': 2,
        'dirty_files': 3,
        'changed_files': 4,
        'insertions': 5,
        'deletions': 6,
      });
      expect(s.ahead, 1);
      expect(s.dirtyFiles, 3);
      expect(s.insertions, 5);
    });
  });

  group('PermissionRequest', () {
    test('parses request with options', () {
      final req = PermissionRequest.fromJson({
        'request_id': 'r1',
        'scope': 'Exec(curl)',
        'title': 'Run curl?',
        'input': 'curl https://x',
        'options': [
          {'id': 'allow-once', 'kind': 'AllowOnce', 'label': 'Allow'},
          {'id': 'reject', 'kind': 'RejectOnce', 'label': 'Cancel'},
        ],
      });
      expect(req.requestId, 'r1');
      expect(req.scope, 'Exec(curl)');
      expect(req.title, 'Run curl?');
      expect(req.input, 'curl https://x');
      expect(req.options, hasLength(2));
      expect(req.options[0].id, 'allow-once');
      expect(req.options[0].kind, 'AllowOnce');
      expect(req.options[0].label, 'Allow');
    });

    test('defaults missing option label and input', () {
      final req = PermissionRequest.fromJson({
        'request_id': 'r1',
        'scope': 'x',
        'title': 'Run?',
        'options': [
          {'id': 'allow-always', 'kind': 'AllowAlways'},
        ],
      });
      expect(req.options.first.id, 'allow-always');
      expect(req.options.first.kind, 'AllowAlways');
      expect(req.options.first.label, isNull);
      expect(req.input, isNull);
    });
  });

  group('tryDecodeJson', () {
    test('decodes JSON object', () {
      final decoded = tryDecodeJson('{"ok": true}');
      expect(decoded, {'ok': true});
    });

    test('returns null for JSON array', () {
      final decoded = tryDecodeJson('[1, 2]');
      expect(decoded, isNull);
    });

    test('returns null for invalid JSON', () {
      final decoded = tryDecodeJson('not json');
      expect(decoded, isNull);
    });
  });

  group('ComposerMode', () {
    test('name returns lowercase mode identifier', () {
      expect(ComposerMode.code.name, 'code');
      expect(ComposerMode.plan.name, 'plan');
      expect(ComposerMode.ask.name, 'ask');
    });

    test('label returns localized display label', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(ComposerMode.code.label(l10n), 'Code');
      expect(ComposerMode.plan.label(l10n), 'Plan');
      expect(ComposerMode.ask.label(l10n), 'Ask');
    });

    test('fromString defaults to code for null, empty or unknown values', () {
      expect(ComposerModeX.fromString(null), ComposerMode.code);
      expect(ComposerModeX.fromString(''), ComposerMode.code);
      expect(ComposerModeX.fromString('nope'), ComposerMode.code);
      expect(ComposerModeX.fromString('CODE'), ComposerMode.code);
    });

    test('fromString parses valid mode values', () {
      expect(ComposerModeX.fromString('plan'), ComposerMode.plan);
      expect(ComposerModeX.fromString('ask'), ComposerMode.ask);
      expect(ComposerModeX.fromString('code'), ComposerMode.code);
    });

    test('hasAskPrefix matches command with word boundary', () {
      expect(hasAskPrefix('/ask hello'), isTrue);
      expect(hasAskPrefix('/ask'), isTrue);
      expect(hasAskPrefix('/ask\nnext'), isTrue);
      expect(hasAskPrefix('/asking'), isFalse);
      expect(hasAskPrefix(' /ask'), isFalse);
      expect(hasAskPrefix('hello /ask'), isFalse);
    });

    test('stripAskPrefix removes command and following whitespace', () {
      expect(stripAskPrefix('/ask hello'), 'hello');
      expect(stripAskPrefix('/ask  hello'), 'hello');
      expect(stripAskPrefix('/ask'), '');
      expect(stripAskPrefix('/asking'), '/asking');
      expect(stripAskPrefix('/ask\n\nhello'), 'hello');
    });
  });

  group('SSE parser', () {
    test('parses event, id and data lines', () {
      final ev = parseSseBlock('event: part\nid: 7\ndata: {"type":"text"}\n\n');
      expect(ev, isNotNull);
      expect(ev!.event, 'part');
      expect(ev.id, '7');
      expect(ev.data, '{"type":"text"}');
    });

    test('returns null for block without event', () {
      expect(parseSseBlock('data: hello\n\n'), isNull);
    });
  });

  group('AskRequest', () {
    test('parses request with questions and options', () {
      final req = AskRequest.fromJson({
        'request_id': 'a1',
        'message': 'Need input',
        'questions': [
          {
            'id': 'q1',
            'prompt': 'Pick one',
            'description': 'desc',
            'field_type': 'single_select',
            'options': [
              {'value': 'x', 'label': 'X'},
              {'value': 'y', 'label': 'Y'},
            ],
            'required': true,
          },
          {'id': 'q2', 'prompt': 'Notes', 'field_type': 'text'},
        ],
      });
      expect(req.requestId, 'a1');
      expect(req.message, 'Need input');
      expect(req.questions, hasLength(2));
      final first = req.questions[0];
      expect(first.id, 'q1');
      expect(first.prompt, 'Pick one');
      expect(first.description, 'desc');
      expect(first.fieldType, 'single_select');
      expect(first.options, hasLength(2));
      expect(first.options[0].value, 'x');
      expect(first.options[0].label, 'X');
      expect(first.required, isTrue);
      final second = req.questions[1];
      expect(second.id, 'q2');
      expect(second.fieldType, 'text');
      expect(second.required, isFalse);
      expect(second.options, isEmpty);
    });

    test('defaults missing fields', () {
      final req = AskRequest.fromJson({
        'request_id': 'a1',
        'message': '',
        'questions': [
          {'id': 'q1', 'prompt': 'Pick', 'field_type': 'single_select'},
        ],
      });
      expect(req.message, isEmpty);
      expect(req.questions[0].description, isNull);
      expect(req.questions[0].required, isFalse);
      expect(req.questions[0].options, isEmpty);
    });
  });

  group('MergeRequestLink', () {
    test('parses full payload', () {
      final mr = MergeRequestLink.fromJson({
        'iid': 42,
        'title': 'Refactor backend',
        'state': 'opened',
        'source_branch': 'feat/x',
        'target_branch': 'main',
        'web_url': 'https://gitlab.example.com/g/p/-/merge_requests/42',
        'draft': true,
      });
      expect(mr.iid, 42);
      expect(mr.title, 'Refactor backend');
      expect(mr.state, 'opened');
      expect(mr.sourceBranch, 'feat/x');
      expect(mr.targetBranch, 'main');
      expect(mr.webUrl, 'https://gitlab.example.com/g/p/-/merge_requests/42');
      expect(mr.draft, isTrue);
      expect(mr.isOpen, isTrue);
    });

    test('parses string iid as int', () {
      final mr = MergeRequestLink.fromJson({'iid': '7'});
      expect(mr.iid, 7);
    });

    test('defaults missing fields to safe values', () {
      final mr = MergeRequestLink.fromJson({});
      expect(mr.iid, 0);
      expect(mr.title, isEmpty);
      expect(mr.state, isEmpty);
      expect(mr.sourceBranch, isEmpty);
      expect(mr.webUrl, isEmpty);
      expect(mr.draft, isFalse);
      expect(mr.isOpen, isFalse);
    });

    test('treats "open" state as open', () {
      final mr = MergeRequestLink.fromJson({'state': 'open'});
      expect(mr.isOpen, isTrue);
    });

    test('builds from a stored reference', () {
      final ref = LinkedMergeRequestRef(
        hostname: 'gitlab.example.com',
        projectPath: 'g/p',
        iid: 7,
        webUrl: 'https://gitlab.example.com/g/p/-/merge_requests/7',
      );
      final mr = MergeRequestLink.fromRef(ref);
      expect(mr.iid, 7);
      expect(mr.webUrl, ref.webUrl);
    });
  });

  group('LinkedMergeRequestRef', () {
    test('parses a GitLab MR URL', () {
      final ref = LinkedMergeRequestRef.tryParse(
        'https://gitlab.example.com/group/project/-/merge_requests/12',
      );
      expect(ref, isNotNull);
      expect(ref!.hostname, 'gitlab.example.com');
      expect(ref.projectPath, 'group/project');
      expect(ref.iid, 12);
      expect(
        ref.webUrl,
        'https://gitlab.example.com/group/project/-/merge_requests/12',
      );
    });

    test('accepts a self-managed host and trailing path', () {
      final ref = LinkedMergeRequestRef.tryParse(
        'https://git.example.com/a/b/-/merge_requests/7/diffs',
      );
      expect(ref, isNotNull);
      expect(ref!.hostname, 'git.example.com');
      expect(ref.projectPath, 'a/b');
      expect(ref.iid, 7);
    });

    test('rejects invalid or non-MR URLs', () {
      expect(
        LinkedMergeRequestRef.tryParse('https://gitlab.com/group/project'),
        isNull,
      );
      expect(
        LinkedMergeRequestRef.tryParse(
          'https://gitlab.com/group/project/merge_requests/12',
        ),
        isNull,
      );
      expect(LinkedMergeRequestRef.tryParse('not-a-url'), isNull);
      expect(
        LinkedMergeRequestRef.tryParse(
          'https://evil.com/https://gitlab.com/group/project/-/merge_requests/12',
        ),
        isNull,
      );
      expect(
        LinkedMergeRequestRef.tryParse(
          'https://gitlab.com/group%2F..%2Fproject/-/merge_requests/12',
        ),
        isNull,
      );
      expect(
        LinkedMergeRequestRef.tryParse(
          'https://gitlab.com/group/project:foo/-/merge_requests/12',
        ),
        isNull,
      );
    });

    test('lowercases hostname and decodes percent-encoded path', () {
      final ref = LinkedMergeRequestRef.tryParse(
        'https://GITLAB.EXAMPLE.COM/group%2Fproject/-/merge_requests/12',
      )!;
      expect(ref.hostname, 'gitlab.example.com');
      expect(ref.projectPath, 'group/project');
      expect(ref.iid, 12);
    });
  });

  group('Thread providerId', () {
    test('parses provider_id and defaults to devin-cli', () {
      final withProvider = Thread.fromJson({
        'id': 't1',
        'title': 't',
        'project_id': 1,
        'provider_id': 'opencode',
        'model': 'm',
        'permission_mode': 'normal',
        'created_at': '',
        'updated_at': '',
      });
      expect(withProvider.providerId, 'opencode');

      final withoutProvider = Thread.fromJson({
        'id': 't2',
        'title': 't',
        'project_id': 1,
        'model': 'm',
        'permission_mode': 'normal',
        'created_at': '',
        'updated_at': '',
      });
      expect(withoutProvider.providerId, 'devin-cli');
    });
  });

  group('provider commands', () {
    test('User parses provider_commands map', () {
      final user = User.fromJson({
        'id': 1,
        'username': 'o',
        'role': 'user',
        'totp_enabled': false,
        'provider_commands': {'opencode': '/opt/oc'},
      });
      expect(user.providerCommands['opencode'], '/opt/oc');
    });

    test('providerCommandFor prefers override then legacy then default', () {
      final user = User(
        id: 1,
        username: 'o',
        role: 'user',
        totpEnabled: false,
        providerId: 'devin-cli',
        providerCommand: '/usr/bin/devin',
        providerCommands: const {'opencode': '/opt/oc'},
      );
      expect(providerCommandFor(user, 'opencode'), '/opt/oc');
      expect(providerCommandFor(user, 'devin-cli'), '/usr/bin/devin');
      expect(
        providerCommandFor(
          user.copyWith(providerCommands: const {}),
          'opencode',
        ),
        'opencode',
      );
      expect(defaultProviderCommand('opencode'), 'opencode');
      expect(defaultProviderCommand('grok'), 'grok');
      expect(defaultProviderCommand('devin-cli'), 'devin');
    });
  });

  group('TailscaleInfo', () {
    test('parses a full status payload', () {
      final info = TailscaleInfo.fromJson({
        'local_mode': false,
        'installed': true,
        'backend_state': 'Running',
        'magic_dns_name': 'devbox.tail-abc.ts.net',
        'tailnet_ipv4': ['100.64.1.2', '100.64.1.3'],
        'serve_enabled': true,
        'serve_desired': true,
        'serve_port': 8443,
        'https_url': 'https://devbox.tail-abc.ts.net:8443/',
        'https_reachable': true,
        'endpoints': [
          {
            'kind': 'tailnet-ip',
            'label': 'Tailnet IP',
            'url': 'http://100.64.1.2:7878',
            'reachable': true,
          },
          {
            'kind': 'tailscale-https',
            'label': 'Tailscale HTTPS',
            'url': 'https://devbox.tail-abc.ts.net:8443/',
            'reachable': false,
          },
        ],
      });

      expect(info.localMode, isFalse);
      expect(info.installed, isTrue);
      expect(info.backendState, 'Running');
      expect(info.magicDnsName, 'devbox.tail-abc.ts.net');
      expect(info.tailnetIpv4, ['100.64.1.2', '100.64.1.3']);
      expect(info.serveEnabled, isTrue);
      expect(info.serveDesired, isTrue);
      expect(info.servePort, 8443);
      expect(info.httpsUrl, 'https://devbox.tail-abc.ts.net:8443/');
      expect(info.httpsReachable, isTrue);
      expect(info.endpoints, hasLength(2));
      expect(info.endpoints[1].kind, 'tailscale-https');
      expect(info.endpoints[1].reachable, isFalse);
    });

    test('parses a local-mode payload', () {
      final info = TailscaleInfo.fromJson({
        'local_mode': true,
        'installed': false,
        'serve_port': 443,
      });
      expect(info.localMode, isTrue);
      expect(info.installed, isFalse);
      expect(info.magicDnsName, isNull);
      expect(info.endpoints, isEmpty);
    });

    test('tolerates missing fields', () {
      final info = TailscaleInfo.fromJson({});
      expect(info.localMode, isFalse);
      expect(info.installed, isFalse);
      expect(info.serveEnabled, isFalse);
      expect(info.serveDesired, isFalse);
      expect(info.servePort, 443);
      expect(info.tailnetIpv4, isEmpty);
      expect(info.httpsReachable, isNull);
    });
  });
}
