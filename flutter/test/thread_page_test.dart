import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/model_picker.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _buildWithState(AppState state) => MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ThreadPage(),
      ),
    );

void main() {
  testWidgets('Model picker and permission dropdown are disabled without a thread',
      (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      models: [
        ModelInfo(
          id: 'm1',
          label: 'Model 1',
          costTier: 'free',
          family: 'test',
        ),
      ],
    );
    state.setSelectedModel('m1');
    state.setSelectedPermission('normal');

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final modelPicker = find.byType(ModelPicker);
    final dropdown = find.byType(DropdownButton<String>);

    expect(modelPicker, findsOneWidget);
    expect(dropdown, findsOneWidget);

    final button = tester.widget<DropdownButton<String>>(dropdown);
    expect(button.onChanged, isNull);

    await tester.tap(modelPicker);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('Model picker and permission dropdown are disabled while sending',
      (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      models: [
        ModelInfo(
          id: 'm1',
          label: 'Model 1',
          costTier: 'free',
          family: 'test',
        ),
      ],
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: const [],
      ),
      sending: true,
    );
    state.setSelectedModel('m1');
    state.setSelectedPermission('normal');

    await tester.pumpWidget(_buildWithState(state));
    await tester.pump();

    final modelPicker = find.byType(ModelPicker);
    final dropdown = find.byType(DropdownButton<String>);

    expect(modelPicker, findsOneWidget);
    expect(dropdown, findsOneWidget);

    final button = tester.widget<DropdownButton<String>>(dropdown);
    expect(button.onChanged, isNull);

    await tester.tap(modelPicker);
    await tester.pump();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('Model picker and permission dropdown are enabled with an active thread',
      (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      models: [
        ModelInfo(
          id: 'm1',
          label: 'Model 1',
          costTier: 'free',
          family: 'test',
        ),
      ],
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: const [],
      ),
    );
    state.setSelectedModel('m1');
    state.setSelectedPermission('normal');

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final modelPicker = find.byType(ModelPicker);
    final dropdown = find.byType(DropdownButton<String>);

    expect(modelPicker, findsOneWidget);
    expect(dropdown, findsOneWidget);

    final button = tester.widget<DropdownButton<String>>(dropdown);
    expect(button.onChanged, isNotNull);

    await tester.tap(modelPicker);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
  });
}
