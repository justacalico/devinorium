/// Connection details for the devinorium server bundled inside desktop
/// builds. The app spawns it on a random loopback port with a per-launch
/// bearer token, so the user never logs in but other local processes still
/// cannot call the API.
class LocalServerEndpoint {
  final String baseUrl;
  final String token;

  const LocalServerEndpoint({required this.baseUrl, required this.token});
}
