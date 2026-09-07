import '../l10n/l10n.dart';

/// The composer interaction mode. Providers that support it can change how
/// they interpret the user's prompt (e.g. plan before coding, answer questions
/// without editing files, or build directly).
enum ComposerMode { code, plan, ask }

/// Whether [text] starts with the `/ask` command prefix.
bool hasAskPrefix(String text) => _askPrefix.hasMatch(text);

/// Removes a leading `/ask` command prefix and any following whitespace.
String stripAskPrefix(String text) => text.replaceFirst(_askSendPrefix, '');

final _askPrefix = RegExp(r'^/ask(?:\s|$)');
final _askSendPrefix = RegExp(r'^/ask(?:\s+|$)');

extension ComposerModeX on ComposerMode {
  String get name => switch (this) {
    ComposerMode.code => 'code',
    ComposerMode.plan => 'plan',
    ComposerMode.ask => 'ask',
  };

  String label(AppLocalizations l10n) => switch (this) {
    ComposerMode.code => l10n.composerModeCode,
    ComposerMode.plan => l10n.composerModePlan,
    ComposerMode.ask => l10n.composerModeAsk,
  };

  ComposerMode get next => switch (this) {
    ComposerMode.code => ComposerMode.ask,
    ComposerMode.ask => ComposerMode.plan,
    ComposerMode.plan => ComposerMode.code,
  };

  static const _default = ComposerMode.code;

  static ComposerMode fromString(String? value) => switch (value) {
    'plan' => ComposerMode.plan,
    'ask' => ComposerMode.ask,
    _ => _default,
  };
}
