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

  /// Load the live log for a single CI/CD [job].
  ///
  /// Throws [UnsupportedError] by default; providers that support pipelines
  /// (GitLab) should override this.
  Future<JobLog> loadJobLog(MergeRequestPipelineJob job) {
    throw UnsupportedError('Job logs are not supported by this provider');
  }

  /// Load the raw bytes of the repository file at [path] on git [ref], used
  /// to render image diffs. Returns `null` when the file does not exist at
  /// that ref or cannot be fetched.
  ///
  /// Throws [UnsupportedError] by default; providers that can read repository
  /// files (GitLab) should override this.
  Future<Uint8List?> loadFile(String path, String ref) async {
    throw UnsupportedError('File loading is not supported by this provider');
  }
}
