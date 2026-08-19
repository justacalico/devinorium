import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/utils/thread_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('activeThreadTag', () {
    test('returns running while sending', () {
      final tag = activeThreadTag(
        sending: true,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: null,
      );
      expect(tag, 'running');
    });

    test('returns working when last message is user and not sending', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: null,
      );
      expect(tag, 'working');
    });

    test('returns done when last message is assistant', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [
          Message(role: 'user', content: 'hi'),
          Message(role: 'assistant', content: 'hello'),
        ],
        pendingPermissionRequest: null,
      );
      expect(tag, 'done');
    });

    test('returns failed when last message is error', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [Message(role: 'error', content: 'oops')],
        pendingPermissionRequest: null,
      );
      expect(tag, 'failed');
    });

    test('returns needs approval over running', () {
      final tag = activeThreadTag(
        sending: true,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: PermissionRequest(
          requestId: 'r1',
          scope: 'exec',
          title: 'Run',
          options: [PermissionOption(id: 'once', kind: 'once')],
        ),
      );
      expect(tag, 'needs approval');
    });

    test('returns needs answer for pending ask', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: null,
        pendingAskRequest: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Value',
              fieldType: 'text',
            ),
          ],
        ),
      );
      expect(tag, 'needs answer');
    });

    test('returns needs approval over needs answer', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: PermissionRequest(
          requestId: 'r1',
          scope: 'exec',
          title: 'Run',
          options: [PermissionOption(id: 'once', kind: 'once')],
        ),
        pendingAskRequest: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Value',
              fieldType: 'text',
            ),
          ],
        ),
      );
      expect(tag, 'needs approval');
    });

    test('returns needs approval even when not sending', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: PermissionRequest(
          requestId: 'r1',
          scope: 'exec',
          title: 'Run',
          options: [PermissionOption(id: 'once', kind: 'once')],
        ),
      );
      expect(tag, 'needs approval');
    });

    test('returns null for unknown last role', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [Message(role: 'system', content: 'hi')],
        pendingPermissionRequest: null,
      );
      expect(tag, isNull);
    });

    test('returns null for empty messages and no send', () {
      final tag = activeThreadTag(
        sending: false,
        messages: const [],
        pendingPermissionRequest: null,
      );
      expect(tag, isNull);
    });

    test('returns stopped when run was stopped', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: null,
        runStatus: 'stopped',
      );
      expect(tag, 'stopped');
    });

    test('returns failed when run failed', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: null,
        runStatus: 'failed',
      );
      expect(tag, 'failed');
    });

    test('returns done when run completed', () {
      final tag = activeThreadTag(
        sending: false,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: null,
        runStatus: 'completed',
      );
      expect(tag, 'done');
    });

    test('returns running over stopped while sending', () {
      final tag = activeThreadTag(
        sending: true,
        messages: [Message(role: 'user', content: 'hi')],
        pendingPermissionRequest: null,
        runStatus: 'stopped',
      );
      expect(tag, 'running');
    });
  });
}
