import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/views/plan_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlanOverlay', () {
    testWidgets('renders collapsed by default', (tester) async {
      final plan = Plan(
        explanation: 'Build the thing',
        steps: [
          PlanStep(step: 'A', status: 'completed'),
          PlanStep(step: 'B', status: 'in_progress'),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanOverlay(
              plan: plan,
              expanded: false,
              onToggleExpand: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(find.text('Build the thing'), findsOneWidget);
      expect(find.text('1 / 2 steps · 50%'), findsOneWidget);
      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsNothing);
    });

    testWidgets('renders steps when expanded', (tester) async {
      final plan = Plan(
        steps: [
          PlanStep(step: 'A', status: 'completed'),
          PlanStep(step: 'B', status: 'in_progress'),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanOverlay(
              plan: plan,
              expanded: true,
              onToggleExpand: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('is hidden when dismissed', (tester) async {
      final plan = Plan(steps: [PlanStep(step: 'A')]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanOverlay(
              plan: plan,
              dismissed: true,
              onToggleExpand: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(find.text('A'), findsNothing);
      expect(find.text('Plan'), findsNothing);
    });

    testWidgets('calls onToggleExpand and onDismiss', (tester) async {
      var toggled = false;
      var dismissed = false;
      final plan = Plan(steps: [PlanStep(step: 'A')]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanOverlay(
              plan: plan,
              onToggleExpand: () => toggled = true,
              onDismiss: () => dismissed = true,
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(toggled, isTrue);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(dismissed, isTrue);
    });

    testWidgets('renders CJK explanation and steps', (tester) async {
      final plan = Plan(
        explanation: '构建功能',
        steps: [
          PlanStep(step: '迁移数据库', status: 'completed'),
          PlanStep(step: '连接 API', status: 'in_progress'),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanOverlay(
              plan: plan,
              expanded: true,
              onToggleExpand: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(find.text('构建功能'), findsOneWidget);
      expect(find.text('迁移数据库'), findsOneWidget);
      expect(find.text('连接 API'), findsOneWidget);
    });
  });
}
