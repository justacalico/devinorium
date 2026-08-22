import 'package:flutter/foundation.dart';

import '../state/async_value.dart';
import 'merge_request_models.dart';

/// Base interface for a merge request data source.
///
/// Implementations are provider-specific (GitLab, GitHub, Bitbucket, ...).
/// The view only depends on this interface and the [AsyncValue] it exposes.
abstract class MergeRequestProvider extends ChangeNotifier {
  AsyncValue<MergeRequestDetail> get value;

  /// Whether this provider can handle the given [url].
  bool canHandle(String url);

  /// Load the merge request at [url] and update [value].
  Future<void> load(String url);
}
