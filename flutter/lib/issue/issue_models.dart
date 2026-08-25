import '../merge_request/merge_request_models.dart';

/// Fully loaded GitLab issue details.
///
/// Reuses [MergeRequestAuthor] and [MergeRequestComment] from the merge
/// request models because GitLab returns the same shape for both resources,
/// so duplicating them would only drift over time.
class IssueDetail {
  final String title;
  final String description;
  final String state;
  final int iid;
  final String webUrl;
  final MergeRequestAuthor? author;
  final String createdAt;
  final String updatedAt;
  final List<String> labels;
  final String? milestone;
  final List<MergeRequestAuthor> assignees;
  final List<MergeRequestComment> comments;

  const IssueDetail({
    required this.title,
    this.description = '',
    this.state = '',
    required this.iid,
    required this.webUrl,
    this.author,
    this.createdAt = '',
    this.updatedAt = '',
    this.labels = const [],
    this.milestone,
    this.assignees = const [],
    this.comments = const [],
  });

  bool get isOpen => state == 'opened' || state == 'open';

  bool get isClosed => state == 'closed';
}
