import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'client_factory_stub.dart'
    if (dart.library.js_interop) 'client_factory_web.dart';
import 'native_api_client.dart';
import 'preloader_client.dart';

/// Create the right API client for the current platform.
///
/// Web uses the same-origin cookie flow; native uses bearer tokens stored in
/// [SharedPreferences]. A [PreloaderClient] wraps the platform client so list
/// responses are cached and in-flight GETs are coalesced.
BaseApiClient createApiClient() {
  final inner = kIsWeb ? ApiClient.withClient(createClient()) : NativeApiClient();
  return PreloaderClient(inner);
}
