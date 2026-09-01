import 'package:flutter/foundation.dart';

import '../servers/server_profile.dart';
import 'api_client.dart';
import 'client_factory_stub.dart'
    if (dart.library.js_interop) 'client_factory_web.dart';
import 'native_api_client.dart';
import 'preloader_client.dart';

/// Create the right API client for the current platform.
///
/// Web uses the same-origin cookie flow and ignores [profile]; native uses
/// bearer tokens from [ServerProfile]. A [PreloaderClient] wraps the platform
/// client so list responses are cached and in-flight GETs are coalesced.
BaseApiClient createApiClient([ServerProfile? profile]) {
  final BaseApiClient inner;
  if (kIsWeb) {
    inner = ApiClient.withClient(createClient());
  } else if (profile != null) {
    inner = NativeApiClient.fromProfile(profile);
  } else {
    inner = NativeApiClient();
  }
  return PreloaderClient(inner);
}
