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

  /// Apply [action] to the loaded merge request, then refresh [value].
  ///
  /// Throws if no merge request is loaded or the host rejects the action.
  Future<void> perform(MergeRequestAction action);

  /// Load the CI/CD jobs for a [pipeline] belonging to the current merge
  /// request.
  ///
  /// Throws [UnsupportedError] by default; providers that support pipelines
  /// (GitLab) should override this.
  Future<List<MergeRequestPipelineJob>> loadJobs(
    MergeRequestPipeline pipeline,
  ) {
    throw UnsupportedError('Pipeline jobs are not supported by this provider');
  }
}
