import 'package:devinorium_frontend/utils/plan_markup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stripPlanMarkup', () {
    test('removes update_plan blocks', () {
      const text = r'''
Before
<update_plan explanation="Build"><step status="completed">A</step></update_plan>
After
''';
      expect(stripPlanMarkup(text), 'Before\n\nAfter\n');
    });

    test('removes proposed_plan blocks', () {
      const text = r'<proposed_plan explanation="Plan"><step>X</step></proposed_plan>';
      expect(stripPlanMarkup(text), '');
    });

    test('removes multiple plan blocks', () {
      const text = 'a <update_plan><step>A</step></update_plan> b '
          '<proposed_plan><step>B</step></proposed_plan> c';
      expect(stripPlanMarkup(text), 'a  b  c');
    });

    test('preserves unrelated angle brackets', () {
      const text = 'Use `<` and `>` for comparisons.';
      expect(stripPlanMarkup(text), text);
    });

    test('matches opening and closing tag pairs', () {
      const text = r'<proposed_plan><step>A</step></proposed_plan>'
          r'<update_plan><step>B</step></update_plan>';
      expect(stripPlanMarkup(text), '');
    });

    test('handles explanation attributes with special characters', () {
      const text = r'<update_plan explanation="a > b"><step>A</step></update_plan>';
      expect(stripPlanMarkup(text), '');
    });
  });
}
