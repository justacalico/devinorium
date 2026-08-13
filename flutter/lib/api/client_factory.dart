import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'native_api_client.dart';

/// Create the right API client for the current platform.
///
/// Web uses the same-origin cookie flow; native uses bearer tokens stored in
/// [SharedPreferences].
BaseApiClient createApiClient() {
  if (kIsWeb) return ApiClient();
  return NativeApiClient();
}
