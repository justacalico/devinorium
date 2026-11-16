/// Removes `<proposed_plan>` and `<update_plan>` XML blocks (including their
/// `<step>` children) from text so the assistant message does not show raw
/// plan markup.
String stripPlanMarkup(String text) {
  return text
      .replaceAllMapped(_planBlockRe, (_) => '')
      .replaceAllMapped(_unterminatedPlanRe, (_) => '');
}

final _planBlockRe = RegExp(
  r'<proposed_plan\b[^>]*>(.*?)</proposed_plan>|<update_plan\b[^>]*>(.*?)</update_plan>',
  dotAll: true,
  multiLine: true,
);

// A plan block that is still streaming has no close tag yet; hide it rather
// than showing raw markup until the tag arrives.
final _unterminatedPlanRe = RegExp(
  r'<(?:proposed|update)_plan\b(?:[^>]*[^>/])?>[\s\S]*$',
);
