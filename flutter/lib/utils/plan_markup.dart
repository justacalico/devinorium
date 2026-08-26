/// Removes `<proposed_plan>` and `<update_plan>` XML blocks (including their
/// `<step>` children) from text so the assistant message does not show raw
/// plan markup.
String stripPlanMarkup(String text) {
  return text.replaceAllMapped(_planBlockRe, (_) => '');
}

final _planBlockRe = RegExp(
  r'<proposed_plan(?:\s+explanation="[^"]*")?\s*>(.*?)</proposed_plan>|<update_plan(?:\s+explanation="[^"]*")?\s*>(.*?)</update_plan>',
  dotAll: true,
  multiLine: true,
);
