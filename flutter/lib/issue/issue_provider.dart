import 'package:flutter/foundation.dart';

import '../state/async_value.dart';
import 'issue_models.dart';

/// Base interface for an issue data source.
///
/// Implementations are provider-specific (GitLab, GitHub, Bitbucket, ...).
/// The view only depends on this interface and the [AsyncValue] it exposes.
abstract class IssueProvider extends ChangeNotifier {
  AsyncValue<IssueDetail> get value;

  /// Whether this provider can handle the given [url].
  bool canHandle(String url);

  /// Load the issue at [url] and update [value].
  Future<void> load(String url);
}
