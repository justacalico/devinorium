import 'package:devinorium_frontend/api/api_types.dart';
import 'package:devinorium_frontend/api/sse_parser.dart';
import 'package:devinorium_frontend/models/composer_mode.dart';
import 'package:devinorium_frontend/models/models.dart';
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
      final updated = user.copyWith(providerId: 'other', providerCommand: 'other-cli');
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
      final m = Message.fromJson({
        'role': 'user',
        'content': 'hello',
      });
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

    test('copyWith updates content', () {
      final m = Message(role: 'user', content: 'hi');
      final updated = m.copyWith(content: 'hello');
      expect(updated.content, 'hello');
      expect(updated.role, 'user');
    });

    test('allParts falls back to content and thinking', () {
      final m = Message(
        role: 'assistant',
        content: 'hello',
        thinking: 'hmm',
      );
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
        'is_repo': true,
        'branch': 'main',
        'created_at': '2026-01-01',
        'updated_at': '2026-01-02',
      });
      expect(p.id, 1);
      expect(p.name, 'My Project');
      expect(p.path, '/tmp/my-project');
      expect(p.position, 5);
      expect(p.isRepo, true);
      expect(p.gitBranch, 'main');
      expect(p.createdAt, '2026-01-01');
      expect(p.updatedAt, '2026-01-02');
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
      final p = Project.fromJson({
        'id': 1,
        'name': 'x',
        'path': 'y',
      });
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
        'created_at': '2026-01-01',
        'updated_at': '2026-01-02',
      });
      expect(t.id, 'abc');
      expect(t.title, 'Thread');
      expect(t.projectId, 1);
      expect(t.model, 'glm-5-2');
      expect(t.permissionMode, 'normal');
      expect(t.threadGroupId, isNull);
      expect(t.devinSessionId, isNull);
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
        'thread': {
          'id': 'abc',
          'title': 'Thread',
          'project_id': 1,
        },
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
      final p = ProviderInfo.fromJson({
        'id': 'devin-cli',
        'name': 'Devin CLI',
      });
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
    });

    test('defaults is_dir to false', () {
      final e = DirEntry.fromJson({'name': 'x', 'size': 0});
      expect(e.isDir, isFalse);
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

  group('PairingResponse', () {
    test('parses pairing fields', () {
      final p = PairingResponse.fromJson({
        'ok': true,
        'token': 'abc123',
        'username': 'owner',
        'server_url': 'http://localhost:7878',
      });
      expect(p.token, 'abc123');
      expect(p.username, 'owner');
      expect(p.serverUrl, 'http://localhost:7878');
      expect(p.ok, true);
    });

    test('defaults missing fields', () {
      final p = PairingResponse.fromJson({'ok': true});
      expect(p.token, '');
      expect(p.username, '');
      expect(p.serverUrl, '');
      expect(p.ok, true);
    });

    test('toJsonString round-trips', () {
      final p = PairingResponse(
        ok: true,
        token: 't',
        username: 'u',
        serverUrl: 'http://x',
      );
      final json = p.toJsonString();
      expect(json.contains('"token":"t"'), true);
      expect(json.contains('"username":"u"'), true);
      expect(json.contains('"server_url":"http://x"'), true);
    });
  });

  group('Device', () {
    test('parses all fields', () {
      final d = Device.fromJson({
        'device_id': 'dev123',
        'token_prefix': 'abc',
        'name': 'Phone',
        'created_at': '2024-01-01',
        'last_seen_at': '2024-01-02',
        'expires_at': '2024-02-01',
        'is_current': true,
      });
      expect(d.deviceId, 'dev123');
      expect(d.tokenPrefix, 'abc');
      expect(d.name, 'Phone');
      expect(d.createdAt, '2024-01-01');
      expect(d.lastSeenAt, '2024-01-02');
      expect(d.expiresAt, '2024-02-01');
      expect(d.isCurrent, true);
    });

    test('defaults missing fields', () {
      final d = Device.fromJson({'device_id': 'd'});
      expect(d.tokenPrefix, '');
      expect(d.name, isNull);
      expect(d.createdAt, '');
      expect(d.lastSeenAt, '');
      expect(d.expiresAt, '');
      expect(d.isCurrent, false);
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

    test('label returns display label', () {
      expect(ComposerMode.code.label, 'Code');
      expect(ComposerMode.plan.label, 'Plan');
      expect(ComposerMode.ask.label, 'Ask');
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
}
