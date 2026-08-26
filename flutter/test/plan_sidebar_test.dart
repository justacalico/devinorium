import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/views/plan_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlanSidebar', () {
    testWidgets('renders empty plan placeholder when plan is null', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: PlanSidebar())),
      );
      expect(find.text('No plan yet'), findsOneWidget);
    });

    testWidgets('renders explanation, progress and steps', (tester) async {
      final plan = Plan(
        explanation: 'Build the thing',
        steps: [
          PlanStep(step: 'Step A', status: 'completed'),
          PlanStep(step: 'Step B', status: 'in_progress'),
          PlanStep(step: 'Step C', status: 'pending'),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlanSidebar(plan: plan)),
        ),
      );
      expect(find.text('Plan'), findsOneWidget);
      expect(find.text('Build the thing'), findsOneWidget);
      expect(find.text('Step A'), findsOneWidget);
      expect(find.text('Step B'), findsOneWidget);
      expect(find.text('Step C'), findsOneWidget);
      expect(find.text('33%'), findsOneWidget);
    });

    testWidgets('calls onClose when close button is pressed', (tester) async {
      var closed = false;
      final plan = Plan(
        steps: [PlanStep(step: 'Only step', status: 'pending')],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanSidebar(plan: plan, onClose: () => closed = true),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(closed, isTrue);
    });
  });
}
