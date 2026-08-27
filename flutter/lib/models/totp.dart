class TotpSetupResponse {
  final String secret;
  final String otpauthUri;

  TotpSetupResponse({required this.secret, required this.otpauthUri});

  factory TotpSetupResponse.fromJson(Map<String, dynamic> j) =>
      TotpSetupResponse(
        secret: j['secret'] as String,
        otpauthUri: j['otpauth_uri'] as String? ?? '',
      );
}
