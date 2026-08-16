/// The composer interaction mode. Providers that support it can change how
/// they interpret the user's prompt (e.g. plan before coding, answer questions
/// without editing files, or build directly).
enum ComposerMode { code, plan, ask }

extension ComposerModeX on ComposerMode {
  String get name => switch (this) {
    ComposerMode.code => 'code',
    ComposerMode.plan => 'plan',
    ComposerMode.ask => 'ask',
  };

  String get label => switch (this) {
    ComposerMode.code => 'Code',
    ComposerMode.plan => 'Plan',
    ComposerMode.ask => 'Ask',
  };

  static const _default = ComposerMode.code;

  static ComposerMode fromString(String? value) => switch (value) {
    'plan' => ComposerMode.plan,
    'ask' => ComposerMode.ask,
    _ => _default,
  };
}
