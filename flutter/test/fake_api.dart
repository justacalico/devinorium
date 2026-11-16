import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Endpoints every server switch touches while reloading settings data.
/// A [MockClient] that answers `{}` only for these and 404s anything else,
/// so an unstubbed call a test did not expect fails loudly instead of
/// silently "succeeding" on every path.
MockClient infraOnlyClient() {
  const infra = {
    '/api/federation/nodes',
    '/api/machines',
    '/api/plugins',
    '/api/providers/version',
    '/api/settings/mcp-servers',
    '/api/settings/project-root',
    '/api/settings/web-access',
    '/api/usage',
    '/api/users',
    '/healthz',
  };
  return MockClient((req) async {
    if (infra.contains(req.url.path)) {
      return http.Response('{}', 200);
    }
    return http.Response('unexpected request to ${req.url.path}', 404);
  });
}
