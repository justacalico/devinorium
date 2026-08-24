import 'package:devinorium_frontend/issue/issue_models.dart';
import 'package:devinorium_frontend/merge_request/merge_request_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IssueDetail', () {
    test('isOpen / isClosed derive from state', () {
      const open = IssueDetail(title: 't', state: 'opened', iid: 1, webUrl: '');
      const openAlt = IssueDetail(title: 't', state: 'open', iid: 1, webUrl: '');
      const closed = IssueDetail(title: 't', state: 'closed', iid: 1, webUrl: '');
      const unknown = IssueDetail(title: 't', state: 'locked', iid: 1, webUrl: '');

      expect(open.isOpen, isTrue);
      expect(openAlt.isOpen, isTrue);
      expect(closed.isClosed, isTrue);
      expect(unknown.isOpen, isFalse);
      expect(unknown.isClosed, isFalse);
    });

    test('defaults to empty collections', () {
      const detail = IssueDetail(title: 't', iid: 1, webUrl: '');

      expect(detail.labels, isEmpty);
      expect(detail.assignees, isEmpty);
      expect(detail.comments, isEmpty);
      expect(detail.description, '');
      expect(detail.milestone, isNull);
      expect(detail.author, isNull);
    });

    test('carries author, labels, milestone, assignees and comments', () {
      const detail = IssueDetail(
        title: 'Bug',
        description: 'desc',
        state: 'opened',
        iid: 7,
        webUrl: 'https://gitlab.com/g/p/-/issues/7',
        author: MergeRequestAuthor(name: 'Dev', username: 'dev'),
        labels: ['bug', 'urgent'],
        milestone: 'v2.0',
        assignees: [
          MergeRequestAuthor(name: 'Alice', username: 'alice'),
          MergeRequestAuthor(name: 'Bob', username: 'bob'),
        ],
        comments: [
          MergeRequestComment(body: 'note'),
        ],
      );

      expect(detail.author?.username, 'dev');
      expect(detail.labels, ['bug', 'urgent']);
      expect(detail.milestone, 'v2.0');
      expect(detail.assignees.map((a) => a.username).toList(), ['alice', 'bob']);
      expect(detail.comments.first.body, 'note');
    });
  });
}
