import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/app_scope.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/tasks/task_actions.dart';
import 'package:syncnotes/tasks/task_models.dart';
import 'package:syncnotes/ui/back_handler.dart';

import 'fake_channel.dart';

void main() {
  setUpAll(registerBuiltinTypes);

  Future<void> pumpApp(WidgetTester tester, {Size size = const Size(400, 860)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    SharedPreferences.setMockInitialValues({'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-task'});
    final settings = await Settings.load();
    await tester.pumpWidget(SyncNotesApp(settings: settings, store: MemoryStore(), channelFactory: (_) => FakeChannel()));
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  AppServices services(WidgetTester tester) => AppScope.of(tester.element(find.byKey(const Key('homeTitle'))));

  Future<void> openTasks(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('menuButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebarTasks')));
    await tester.pumpAndSettle();
  }

  testWidgets('create menu includes 任务', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    expect(find.text('任务'), findsOneWidget);
  });

  testWidgets('sidebar opens dashboard; creating a task shows it; back returns level by level', (tester) async {
    await pumpApp(tester);
    await openTasks(tester);
    expect(find.byKey(const Key('taskDashboard')), findsOneWidget);
    expect(find.text('还没有任务'), findsOneWidget);
    expect(find.byKey(const Key('taskOverviewRing')), findsOneWidget);

    await tester.tap(find.byKey(const Key('newTaskButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('taskEditor')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('taskTitleField')), '写发布说明');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('taskTitleField')), findsOneWidget);

    await back(tester);
    expect(find.byKey(const Key('taskDashboard')), findsOneWidget);
    expect(find.text('写发布说明'), findsWidgets);
    expect(find.text(BackToExit.message), findsNothing);

    await back(tester);
    expect(find.byKey(const Key('homeTitle')), findsOneWidget);
    expect(find.byKey(const Key('taskDashboard')), findsNothing);
    expect(find.text(BackToExit.message), findsNothing);

    await back(tester);
    expect(find.text(BackToExit.message), findsOneWidget);
  });

  testWidgets('overdue card opens the overdue list; complete toggle marks the task done', (tester) async {
    await pumpApp(tester);
    final sync = services(tester).sync;
    final due = DateTime(2020, 1, 1).millisecondsSinceEpoch;
    final block = saveTask(
      sync,
      null,
      title: '过期的作业',
      data: TaskData(dueAt: due, allDay: true, priority: TaskPriority.urgent),
    )!;
    await tester.pumpAndSettle();
    await openTasks(tester);
    expect(find.text('过期的作业'), findsWidgets);

    await tester.tap(find.byKey(const Key('stats-overdue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('taskView-overdue')), findsOneWidget);
    expect(find.text('过期的作业'), findsWidgets);

    await tester.tap(find.byKey(Key('taskComplete-${block.id}')));
    await tester.pumpAndSettle();
    expect(taskDataOf(sync.byId(block.id)!).status, TaskStatus.done);
  });
}
