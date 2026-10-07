import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/models/session.dart';
import 'package:herdr_mobile/models/agent_status.dart';
import 'package:herdr_mobile/services/herdr_client.dart';
import 'package:herdr_mobile/ui/screens/agents_home_screen.dart';
import 'package:herdr_mobile/changelog.dart';
import 'package:herdr_mobile/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:herdr_mobile/ui/screens/settings_screen.dart';
import 'package:herdr_mobile/ui/screens/terminal_screen.dart';
import 'package:herdr_mobile/ui/widgets/agent_avatar.dart';
import 'package:herdr_mobile/ui/widgets/machines.dart';
import 'package:herdr_mobile/ui/widgets/workspaces.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('Herdr Mobile Models Test', () {
    test('SessionSnapshot parses correctly from JSON', () {
      final json = {
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {
            'workspace_id': 'w1',
            'number': 1,
            'label': '~',
            'focused': true,
            'pane_count': 1,
            'tab_count': 1,
            'active_tab_id': 'w1:t1',
            'agent_status': 'unknown',
          }
        ],
        'tabs': [
          {
            'tab_id': 'w1:t1',
            'workspace_id': 'w1',
            'number': 1,
            'label': '1',
            'focused': true,
            'pane_count': 1,
            'agent_status': 'unknown',
          }
        ],
        'panes': [
          {
            'pane_id': 'w1:p1',
            'terminal_id': 'term_1',
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'focused': true,
            'cwd': '/home/xicu',
            'terminal_title': 'xicu@raspi: ~',
            'agent_status': 'working',
          }
        ],
        'agents': [
          {
            'name': 'indexer',
            'pane_id': 'w1:p1',
            'agent_status': 'working',
          }
        ],
      };

      final snapshot = SessionSnapshot.fromJson(json);
      expect(snapshot.workspaces.length, equals(1));
      expect(snapshot.panes.length, equals(1));
      expect(snapshot.panes.first.id, equals('w1:p1'));
      expect(snapshot.agents.first.name, equals('indexer'));
      expect(snapshot.agents.first.status, equals('working'));
    });

    test('SessionSnapshot placeOf formats branch/workspace and tabs with parentheses', () {
      final snapshot = SessionSnapshot(
        workspaces: [
          WorkspaceModel(id: 'w1', number: 1, label: 'frontend', gitBranch: 'feature-x', agentStatus: 'idle'),
          WorkspaceModel(id: 'w2', number: 2, label: 'backend', agentStatus: 'idle'),
        ],
        tabs: [
          TabModel(id: 't1', workspaceId: 'w1', number: 1, label: 'ui', agentStatus: 'idle'),
          TabModel(id: 't2', workspaceId: 'w1', number: 2, label: 'tests', agentStatus: 'idle'),
          TabModel(id: 't3', workspaceId: 'w2', number: 1, label: 'api', agentStatus: 'idle'),
        ],
        panes: [
          PaneModel(id: 'p1', workspaceId: 'w1', tabId: 't1', focused: true, terminalTitle: '', agentStatus: 'idle'),
          PaneModel(id: 'p2', workspaceId: 'w1', tabId: 't2', focused: false, terminalTitle: '', agentStatus: 'idle'),
          PaneModel(id: 'p3', workspaceId: 'w2', tabId: 't3', focused: true, terminalTitle: '', agentStatus: 'idle'),
        ],
        agents: [],
      );

      // Workspace with branch and multiple tabs shows branch (tab)
      expect(snapshot.placeOf(snapshot.panes[0]), equals('feature-x (ui)'));
      expect(snapshot.placeOf(snapshot.panes[1]), equals('feature-x (tests)'));
      // Workspace without branch shows workspace label
      expect(snapshot.placeOf(snapshot.panes[2]), equals('backend'));
    });

    test('AgentStatus enum mapping works', () {
      expect(AgentStatus.fromString('blocked'), equals(AgentStatus.blocked));
      expect(AgentStatus.fromString('working'), equals(AgentStatus.working));
      expect(AgentStatus.fromString('done'), equals(AgentStatus.done));
      expect(AgentStatus.done.label, equals('Done'));
      expect(AgentStatus.fromString('idle'), equals(AgentStatus.idle));
      expect(AgentStatus.fromString('random'), equals(AgentStatus.unknown));
    });

    test('HerdrClientService disconnect and connect state', () {
      SharedPreferences.setMockInitialValues({});
      final client = HerdrClientService();
      client.setMachines(['100.1.2.3:7788', '100.1.2.4:7788'], []);
      expect(client.isDisconnected, isFalse);

      client.disconnect();
      expect(client.isDisconnected, isTrue);
      expect(client.connected, isFalse);

      client.connect();
      expect(client.isDisconnected, isFalse);
    });

    // backend: tab "api" split into p1 (coder, blocked) and p2 (helper, working), tab "db" (p3, blocked).
    // frontend: one tab (p4, ui, blocked).
    SessionSnapshot twoWorkspaces() {
      Map<String, dynamic> ws(String id, String label, int tabs, String active) => {
            'workspace_id': id,
            'number': 1,
            'label': label,
            'focused': false,
            'pane_count': 1,
            'tab_count': tabs,
            'active_tab_id': active,
            'agent_status': 'blocked',
            'git_branch': '$label-branch',
          };
      Map<String, dynamic> tab(String id, String ws, int n, String label) => {
            'tab_id': id,
            'workspace_id': ws,
            'number': n,
            'label': label,
            'focused': false,
            'pane_count': 1,
            'agent_status': 'blocked',
          };
      // Like herdr: only one pane in the whole session is focused.
      Map<String, dynamic> pane(String id, String ws, String tab, String status) => {
            'pane_id': id,
            'workspace_id': ws,
            'tab_id': tab,
            'focused': id == 'w1:p1',
            'cwd': '/',
            'agent_status': status,
          };
      return SessionSnapshot.fromJson({
        'workspaces': [ws('w1', 'backend', 2, 'w1:t1'), ws('w2', 'frontend', 1, 'w2:t1')],
        'tabs': [tab('w1:t1', 'w1', 1, 'api'), tab('w1:t2', 'w1', 2, 'db'), tab('w2:t1', 'w2', 1, '')],
        'panes': [
          pane('w1:p1', 'w1', 'w1:t1', 'blocked'),
          pane('w1:p2', 'w1', 'w1:t1', 'working'),
          pane('w1:p3', 'w1', 'w1:t2', 'blocked'),
          pane('w2:p4', 'w2', 'w2:t1', 'blocked'),
        ],
        'agents': [
          {'name': 'helper', 'pane_id': 'w1:p2', 'status': 'working'},
          {'name': 'coder', 'pane_id': 'w1:p1', 'status': 'blocked'},
          {'name': 'ui', 'pane_id': 'w2:p4', 'status': 'blocked'},
        ],
      });
    }

    testWidgets('Tabs that overflow the top bar are reached by sliding the strip', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(SessionSnapshot.fromJson({
          'workspaces': [
            {'workspace_id': 'w1', 'label': 'backend', 'active_tab_id': 'w1:t0'}
          ],
          'tabs': [
            for (var n = 0; n < 12; n++) {'tab_id': 'w1:t$n', 'workspace_id': 'w1', 'number': n + 1, 'label': 'tab$n'}
          ],
          'panes': [
            for (var n = 0; n < 12; n++)
              {'pane_id': 'w1:p$n', 'workspace_id': 'w1', 'tab_id': 'w1:t$n', 'focused': n == 0}
          ],
        }))
        ..selectPane('w1:p0');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(seconds: 1));

      final last = find.text('tab11').hitTestable();
      expect(last, findsNothing); // off the edge
      await tester.drag(find.text('tab1'), const Offset(-2000, 0));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(last);
      await tester.pump();
      expect(client.selectedPane?.tabId, 'w1:t11');
    });

    testWidgets('Dragging a tab turns the new-tab button into a bin', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));

      // The Connecting spinner never settles, so step past each animation instead.
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }

      final tab = find.descendant(of: find.byType(AppBar), matching: find.text('db'));

      // While dragged, the new-tab button turns into a bin and the dragged tab slot maintains 168dp width.
      expect(find.byTooltip('New tab'), findsOneWidget);
      final drag = await tester.startGesture(tester.getCenter(tab));
      await tester.pump(const Duration(seconds: 1));
      await drag.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(find.byTooltip('Close tab'), findsOneWidget);
      expect(tester.getSize(find.byType(LongPressDraggable<String>).first).width, 168);
      await drag.moveBy(const Offset(40, 0));
      await drag.up();
      await settle();
      expect(find.byTooltip('New tab'), findsOneWidget);
    });

    testWidgets('The top bar shows the workspace and its tabs; tapping a tab shows it', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));

      // Top bar shows workspace and branch; under it the tabs with their summaries.
      Finder inBar(String t) => find.descendant(of: find.byType(AppBar), matching: find.text(t));
      expect(inBar('backend'), findsOneWidget);
      expect(inBar('backend-branch'), findsOneWidget);
      expect(inBar('coder'), findsOneWidget);
      expect(inBar('db'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(inBar('db'));
      expect(client.selectedPaneId, 'w1:p3');

      // The keyboard button swaps the message box for the control keys, and back.
      await tester.tap(find.byTooltip('Control keys'));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('ESC'), findsOneWidget);
      await tester.tap(find.byTooltip('Message box'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);

      // On Linux, tapping the header does not open the workspace menu; right-clicking opens the context menu.
      if (Platform.isLinux) {
        await tester.tap(inBar('backend'));
        await tester.pump();
        expect(find.text('Rename'), findsNothing);

        await tester.tap(inBar('backend'), buttons: kSecondaryMouseButton);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1)); // the Connecting spinner never settles
        expect(find.text('Rename'), findsOneWidget);
        expect(find.text('New worktree'), findsOneWidget);
        expect(find.text('Open worktree'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
      } else {
        await tester.tap(inBar('backend'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1)); // the Connecting spinner never settles
        expect(find.text('Rename'), findsOneWidget);
        expect(find.text('New worktree'), findsOneWidget);
        expect(find.text('Open worktree'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
      }
    });

    test('Editing a machine renames it and moves it in place', () {
      final client = HerdrClientService()..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], ['10.0.0.1:7788=old']);
      client.updateMachine('10.0.0.1:7788', to: 'laptop:9000', name: 'work');
      expect(client.machines, ['laptop:9000', '10.0.0.2:7788']);
      expect(client.nameOf('laptop:9000'), 'work');
      expect(client.nameOf('10.0.0.1:7788'), '10.0.0.1:7788');
    });

    test('An empty git branch counts as none', () {
      expect(WorkspaceModel.fromJson({'git_branch': ''}).gitBranch, isNull);
      expect(WorkspaceModel.fromJson({'git_branch': 'main'}).gitBranch, 'main');
    });

    testWidgets('Swiping the message bar slides to the next agent in herdr\'s order', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..switchMachine('100.1.2.3:7788')
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p3'); // tab "db", the second of backend's two, with no agent
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      Future<void> swipe(Finder on, double dx) async {
        await tester.timedDrag(on, Offset(dx, 0), const Duration(milliseconds: 200));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      final bottom = find.byType(TextField);
      // Agents go in herdr's order (coder, helper, ui), not the snapshot's; a shell is left behind.
      await swipe(bottom, -300); // left: on to the next workspace's agent
      expect(client.selectedPaneId, 'w2:p4');
      await swipe(bottom, -300); // left again: past the last agent, round to the first
      expect(client.selectedPaneId, 'w1:p1');
      await swipe(bottom, 300); // and back round
      expect(client.selectedPaneId, 'w2:p4');
      await swipe(bottom, 300);
      expect(client.selectedPaneId, 'w1:p2');
    });

    testWidgets('Swiping past a machine\'s last agent goes on to the next machine\'s', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      const a = '10.0.0.1:7788', b = '10.0.0.2:7788';
      final client = HerdrClientService()
        ..setMachines([a, b], [])
        ..setSnapshotForTesting(twoWorkspaces(), b)
        ..switchMachine(a)
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w2:p4'); // a's last agent
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.timedDrag(find.byType(TextField), const Offset(-300, 0), const Duration(milliseconds: 200));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(client.machine, b);
      expect(client.selectedPaneId, 'w1:p1');
    });

    testWidgets('The ☰ drawer lists the workspaces; tap one for its terminal, long-press for its actions',
        (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..switchMachine('100.1.2.3:7788')
        ..setSnapshotForTesting(twoWorkspaces())
        ..setConnectedForTesting('100.1.2.3:7788', true) // the drawer shows connected machines only
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: AgentsHomeScreen(client: client)));
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1)); // the Connecting spinner never settles
      }

      await tester.tap(find.byTooltip('Workspaces')); // the ☰
      await settle();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('backend'), findsOneWidget);
      expect(find.text('backend-branch'), findsOneWidget);
      // Each machine's name carries its own +, in place of a FAB.
      expect(find.byTooltip('New workspace on 100.1.2.3:7788'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);

      await tester.longPress(find.descendant(of: find.byType(WorkspaceList), matching: find.text('backend')));
      await settle();
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('New worktree'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
      await settle();

      await tester.tap(find.descendant(of: find.byType(WorkspaceList), matching: find.text('frontend')));
      await settle();
      expect(client.selectedPaneId, 'w2:p4');
      expect(find.byType(TerminalScreen), findsOneWidget);
    });

    testWidgets('A landscape tablet shows the terminal beside the agents, and rotating moves it', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      const m = '100.1.2.3:7788';
      final client = HerdrClientService()
        ..setMachines([m], [])
        ..switchMachine(m)
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      Future<void> resize(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pump();
        // A pushed or popped screen takes a frame offstage, then its transition.
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }

      addTearDown(tester.view.reset);
      await resize(const Size(1280, 800));
      await tester.pumpWidget(MaterialApp(home: AgentsHomeScreen(client: client)));
      await resize(const Size(1280, 800));
      // Beside the list, without a screen of its own (so no back button).
      expect(find.byType(TerminalScreen), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);

      // Tapping an agent shows it there instead of pushing.
      await tester.tap(find.byKey(const ValueKey('$m/w2:p4')));
      await resize(const Size(1280, 800));
      expect(client.selectedPaneId, 'w2:p4');
      expect(find.byType(TerminalScreen), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);

      // A phone in landscape is wide but short: one pane, so the terminal gets its own screen.
      await resize(const Size(900, 412));
      expect(find.byType(TerminalScreen), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);

      // Wide again: its screen goes, and it's back beside the list.
      await resize(const Size(1280, 800));
      expect(find.byType(TerminalScreen), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('Search finds agents, workspaces, tabs and machines, a section each', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..switchMachine('100.1.2.3:7788')
        ..setSnapshotForTesting(twoWorkspaces())
        ..setConnectedForTesting('100.1.2.3:7788', true) // the drawer shows connected machines only
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: AgentsHomeScreen(client: client)));
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1)); // the Connecting spinner never settles
      }

      await tester.tap(find.byType(TextField));
      await settle();
      expect(find.byType(BackButton), findsOneWidget); // in place of the ☰

      // An agent by its name, with the tab it's in; then a workspace, with its agents.
      await tester.enterText(find.byType(TextField), 'coder');
      await settle();
      expect(find.text('Agents'), findsOneWidget);
      expect(find.textContaining('api'), findsOneWidget);
      expect(find.text('Workspaces'), findsNothing);
      await tester.enterText(find.byType(TextField), 'front');
      await settle();
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Agents'), findsOneWidget); // ui, in frontend

      // A plain shell's tab, which the agent list doesn't show; tapping it opens its terminal.
      await tester.enterText(find.byType(TextField), 'db');
      await settle();
      expect(find.text('Tabs'), findsOneWidget);
      expect(find.text('Agents'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'db'));
      await settle();
      expect(client.selectedPaneId, 'w1:p3');
      expect(find.byType(TerminalScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(TerminalScreen))).pop();
      await settle();

      // Still searching once back; back again closes it.
      expect(find.text('Tabs'), findsOneWidget);
      // A machine's name finds everything on it too, so its own row comes last.
      await tester.enterText(find.byType(TextField), '100.1');
      await settle();
      await tester.scrollUntilVisible(find.byType(Switch), 200,
          scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first);
      expect(find.byType(Switch), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'zzz');
      await settle();
      expect(find.text('No results'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle();
      expect(find.byTooltip('Workspaces'), findsOneWidget);
      expect(find.text('zzz'), findsNothing);
    });

    testWidgets('Each pane keeps its own unsent message, also once its terminal is left', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..switchMachine('100.1.2.3:7788')
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      String box() => tester.widget<TextField>(find.byType(TextField)).controller!.text;

      await tester.enterText(find.byType(TextField), 'half a thought');
      client.selectPane('w1:p2');
      await tester.pump();
      expect(box(), '');
      client.selectPane('w1:p1');
      await tester.pump();
      expect(box(), 'half a thought');

      // A new terminal screen, as after going back to the list, finds it too.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      expect(box(), 'half a thought');
    });

    testWidgets('A long-press selects, and the Copy button by the selection copies it', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      final client = HerdrClientService()..setMachines(['100.1.2.3:7788'], []);
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal.write('\r\n\r\nhello world');
      await tester.pump();
      await tester.longPressAt(tester.getTopLeft(find.byType(TerminalView)) + const Offset(10, 40));
      await tester.pump();
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, 'hello');
      expect(find.text('Copy'), findsNothing);
    });

    test('Machines connect and disconnect independently of the one on screen', () {
      SharedPreferences.setMockInitialValues({});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], [], ['10.0.0.2:7788'])
        ..configure('10.0.0.1:7788', connect: false);
      expect(client.isOff('10.0.0.1:7788'), isFalse);
      expect(client.isOff('10.0.0.2:7788'), isTrue);

      client.connect('10.0.0.2:7788');
      client.disconnect('10.0.0.1:7788');
      expect(client.machine, '10.0.0.1:7788'); // still the one on screen
      expect(client.isOff('10.0.0.1:7788'), isTrue);
      expect(client.isOff('10.0.0.2:7788'), isFalse);

      // Each machine keeps its own snapshot and selected pane.
      client.setSnapshotForTesting(twoWorkspaces(), '10.0.0.2:7788');
      expect(client.snapshot, isNull);
      client.switchMachine('10.0.0.2:7788');
      expect(client.snapshot, isNotNull);
      expect(client.selectedPaneId, 'w1:p1');
      expect(client.isOff('10.0.0.1:7788'), isTrue); // switching doesn't touch the others

      // Switching to a disconnected machine shows it disconnected, without its stale snapshot.
      client.setSnapshotForTesting(twoWorkspaces(), '10.0.0.1:7788');
      client.switchMachine('10.0.0.1:7788');
      expect(client.isOff('10.0.0.1:7788'), isTrue);
      expect(client.snapshot, isNull);
    });

    testWidgets('The machines panel switches each on or off; tap one to edit it, + to add one', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], ['10.0.0.1:7788=laptop'], ['10.0.0.2:7788'])
        ..configure('10.0.0.1:7788', connect: false);
      await tester.pumpWidget(MaterialApp(home: AgentsHomeScreen(client: client)));
      // The Connecting spinner never settles, so step past each animation instead.
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.byTooltip('New workspace'), findsNothing); // the agents have no +
      await tester.tap(find.byTooltip('Machines'));
      await settle();
      expect(find.descendant(of: find.byType(MachineList), matching: find.text('laptop')), findsOneWidget);
      expect(find.text('10.0.0.1:7788'), findsOneWidget); // its address under its name, no status text
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.byType(Switch), findsNWidgets(2));

      await tester.tap(find.byType(Switch).last); // connect the second, keep the first on screen
      await tester.pump();
      expect(client.isOff('10.0.0.2:7788'), isFalse);
      expect(client.machine, '10.0.0.1:7788');

      await tester.tap(find.descendant(of: find.byType(MachineList), matching: find.text('laptop')));
      await settle();
      expect(find.text('Edit machine'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle();

      await tester.tap(find.byTooltip('Add machine'));
      await settle();
      expect(find.text('Add & connect'), findsOneWidget);
    });

    test('Removing the machine on screen shows the next one without connecting it', () {
      SharedPreferences.setMockInitialValues({});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], [], ['10.0.0.2:7788'])
        ..configure('10.0.0.1:7788', connect: false);
      client.removeMachine('10.0.0.1:7788');
      expect(client.machine, '10.0.0.2:7788');
      expect(client.isOff('10.0.0.2:7788'), isTrue);
    });

    test('A bridge\'s switch and removal take the machines it reaches with it', () async {
      SharedPreferences.setMockInitialValues({});
      const laptop = '10.0.0.1:7788', sert = '10.0.0.1:7788/m/abc', other = '10.0.0.2:7788';
      final client = HerdrClientService()
        ..setMachines([laptop, sert, other], ['$sert=sert'])
        ..switchMachine(sert);
      expect(HerdrClientService.parentOf(sert), laptop);
      expect(HerdrClientService.parentOf(laptop), isNull);

      // Muting on the reached machine survives its bridge's own snapshot, where that pane doesn't exist.
      client.setMuted('w1:p1', true);
      client.setSnapshotForTesting(SessionSnapshot.fromJson({'panes': []}), laptop);
      expect(client.isMuted('w1:p1'), isTrue);

      client.disconnect(laptop);
      expect(client.isOff(sert), isTrue);
      expect(client.isOff(other), isFalse);
      client.connect(laptop);
      expect(client.isOff(sert), isFalse);

      // The machine on screen is remembered with its path.
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('herdr_path'), '/m/abc');
      expect((HerdrClientService()..load(prefs)).machine, sert);

      client.removeMachine(laptop);
      expect(client.machines, [other]);
      expect(client.machine, other);
    });

    testWidgets('A finished agent alerts once, even when an older snapshot lands in between', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final alerts = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('herdr/android'),
          (call) async {
        if (call.method == 'alert') alerts.add(call.arguments);
        return null;
      });
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..setAlertDesktop(false)
        ..setAlertSound(false)
        ..setAlerts(true, ask: false);
      SessionSnapshot snap(int seq) => SessionSnapshot.fromJson({
            'panes': [
              {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'agent_status': 'idle'},
              {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'agent_status': 'idle'},
            ],
            'agents': [
              {'name': 'coder', 'pane_id': 'w1:p2', 'status': 'idle', 'completion_seq': seq},
            ],
          });
      for (final seq in [1, 2, 1, 2]) {
        client.setSnapshotForTesting(snap(seq));
      }
      expect(alerts, hasLength(1));
    });

    testWidgets('A new agent in a closed pane\'s reused id still alerts when it finishes', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final alerts = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('herdr/android'),
          (call) async {
        if (call.method == 'alert') alerts.add(call.arguments);
        return null;
      });
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..setAlertDesktop(false)
        ..setAlertSound(false)
        ..setAlerts(true, ask: false);
      SessionSnapshot snap(int? seq) => SessionSnapshot.fromJson({
            'panes': [
              {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'agent_status': 'idle'},
              if (seq != null) {'pane_id': 'w1:p2', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'agent_status': 'idle'},
            ],
            'agents': [
              if (seq != null) {'name': 'coder', 'pane_id': 'w1:p2', 'status': 'idle', 'completion_seq': seq},
            ],
          });
      // The old agent finishes five times, its pane closes, and a new one in the same id finishes once.
      for (final seq in [4, 5, null, 0, 1]) {
        client.setSnapshotForTesting(snap(seq));
      }
      expect(alerts, hasLength(2));
    });

    test('Notification icons warm up, cache bytes and produce Linux icon paths', () async {
      await warmAgentIcons();
      final claudeBytes = agentIconBytes('claude');
      expect(claudeBytes, isNotNull);
      expect(claudeBytes!.lengthInBytes, greaterThan(0));

      final agyBytes = agentIconBytes('antigravity');
      expect(agyBytes, isNotNull);
      expect(agyBytes!.lengthInBytes, greaterThan(0));

      final path = agentIconPath('claude');
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);

      final unknown = agentIconBytes('unknown-agent-name');
      expect(unknown, isNull);
    });

    test('Alert sounds warm up and cache herdr sound files on Linux', () async {
      await warmAlertSounds();
      final doneFile = File('${Directory.systemTemp.path}/herdr_done.mp3');
      final blockedFile = File('${Directory.systemTemp.path}/herdr_blocked.mp3');
      expect(doneFile.existsSync(), isTrue);
      expect(blockedFile.existsSync(), isTrue);
    });

    testWidgets('Agent alert includes agent icon in notification payload', (tester) async {
      await warmAgentIcons();
      SharedPreferences.setMockInitialValues({});
      final alerts = <Map<dynamic, dynamic>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('herdr/android'),
          (call) async {
        if (call.method == 'alert') alerts.add(Map<dynamic, dynamic>.from(call.arguments as Map));
        return null;
      });
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..setAlertDesktop(false)
        ..setAlertSound(false)
        ..setAlerts(true, ask: false);
      client.setSnapshotForTesting(SessionSnapshot.fromJson({
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'agent_status': 'working'},
        ],
        'agents': [
          {'name': 'claude', 'pane_id': 'w1:p1', 'status': 'working', 'completion_seq': 1},
        ],
      }));
      client.setSnapshotForTesting(SessionSnapshot.fromJson({
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'agent_status': 'idle'},
        ],
        'agents': [
          {'name': 'claude', 'pane_id': 'w1:p1', 'status': 'idle', 'completion_seq': 2},
        ],
      }));
      expect(alerts, hasLength(1));
      expect(alerts.first['title'], contains('Finished'));
      expect(alerts.first['icon'], isNotNull);
      expect((alerts.first['icon'] as Uint8List).lengthInBytes, greaterThan(0));
    });





    testWidgets('AgentsHomeScreen displays machines, agents sorted by urgency, and opens terminal on tap',
        (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..configure('10.0.0.1:7788', connect: false);

      final snapshot = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'workspaces': [
          {
            'workspace_id': 'w1',
            'number': 1,
            'label': 'cohort-soc',
            'focused': true,
            'pane_count': 2,
            'tab_count': 1,
            'active_tab_id': 'w1:t1',
            'agent_status': 'blocked',
          }
        ],
        'tabs': [
          {
            'tab_id': 'w1:t1',
            'workspace_id': 'w1',
            'number': 1,
            'label': 'main',
            'focused': true,
            'pane_count': 2,
            'agent_status': 'blocked',
          }
        ],
        'panes': [
          {
            'pane_id': 'w1:p1',
            'terminal_id': 'term_1',
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'focused': false,
            'terminal_title': 'claude-task',
            'agent_status': 'working',
          },
          {
            'pane_id': 'w1:p2',
            'terminal_id': 'term_2',
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'focused': true,
            'terminal_title': 'antigravity-refactor',
            'agent_status': 'blocked',
          },
        ],
        'agents': [
          {
            'name': 'claude',
            'pane_id': 'w1:p1',
            'status': 'working',
          },
          {
            'name': 'antigravity',
            'pane_id': 'w1:p2',
            'status': 'blocked',
          },
        ],
      });

      client.setSnapshotForTesting(snapshot);

      await tester.pumpWidget(MaterialApp(
        home: HerdrMobileApp(client: client),
      ));
      await tester.pumpAndSettle();

      // No machine is connected in a test, so the top bar says so, like WhatsApp's.
      expect(find.text('Connecting…'), findsOneWidget);

      // Most urgent first; each row is titled by its terminal's summary, with its workspace under it
      // and status text below the date in the trailing column.
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('antigravity-refactor'), lessThan(y('claude-task')));
      expect(find.text('cohort-soc'), findsNWidgets(2));
      expect(find.text('Needs you'), findsOneWidget);
      expect(find.text('Working…'), findsOneWidget);
      // The first snapshot's agents changed before the app saw them: no time.
      expect(client.changedAt('w1:p2'), isNull);

      // Tap on antigravity agent opens the terminal screen
      await tester.tap(find.text('antigravity-refactor'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(client.selectedPaneId, equals('w1:p2'));
      // Back button appears in TerminalScreen
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      // Tapping back returns to AgentsHomeScreen
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Connecting…'), findsOneWidget);

      // Swiping it right mutes it, and it stays
      await tester.drag(find.text('antigravity-refactor'), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(find.text('antigravity-refactor'), findsOneWidget);
      expect(client.isMuted('w1:p2', '10.0.0.1:7788'), isTrue);
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);

      // Long-press selects; then a tap adds another, and the top bar mutes both.
      await tester.longPress(find.text('claude-task'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('antigravity-refactor'));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(client.isMuted('w1:p1'), isTrue);
      expect(client.isMuted('w1:p2'), isTrue);
      expect(find.text('Connecting…'), findsOneWidget); // the selection is over

      // Swiping it left hides it at once, and Undo brings it back without closing it.
      await tester.drag(find.text('antigravity-refactor'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('antigravity-refactor'), findsNothing);
      expect(find.text('Agent closed'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('antigravity-refactor'), findsOneWidget);
    });

    testWidgets('Agent timestamps update when state changes and format correctly in AgentsHomeScreen', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..configure('10.0.0.1:7788', connect: false);

      SessionSnapshot snap(int seq, String status) => SessionSnapshot.fromJson({
            'workspaces': [
              {'workspace_id': 'w1', 'label': 'ws1', 'active_tab_id': 'w1:t1'}
            ],
            'tabs': [
              {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'main'}
            ],
            'panes': [
              {
                'pane_id': 'w1:p1',
                'workspace_id': 'w1',
                'tab_id': 'w1:t1',
                'terminal_title': 'agent-task',
                'agent_status': status,
              }
            ],
            'agents': [
              {
                'name': 'claude',
                'pane_id': 'w1:p1',
                'status': status,
                'state_change_seq': seq,
              }
            ],
          });

      // Initial snapshot: no timestamp yet
      client.setSnapshotForTesting(snap(1, 'working'));
      expect(client.changedAt('w1:p1'), isNull);

      await tester.pumpWidget(MaterialApp(
        home: HerdrMobileApp(client: client),
      ));
      await tester.pumpAndSettle();

      // Second snapshot with state change: timestamp is recorded
      client.setSnapshotForTesting(snap(2, 'blocked'));
      expect(client.changedAt('w1:p1'), isNotNull);

      await tester.pumpAndSettle();
      expect(find.text('agent-task'), findsOneWidget);
      expect(find.text('ws1'), findsOneWidget);
      expect(find.text('Needs you'), findsOneWidget);
      // Status text is below the date in the trailing column
      final dateFinder = find
          .text(AgentsHomeScreen.formatWhen(tester.element(find.byType(AgentsHomeScreen)), client.changedAt('w1:p1')!));
      expect(tester.getTopLeft(find.text('Needs you')).dy, greaterThan(tester.getTopLeft(dateFinder).dy));
    });

    test('Viewing a done agent (idle, same seq) keeps when it changed', () {
      final client = HerdrClientService()..configure('10.0.0.1:7788', connect: false);
      SessionSnapshot snap(int seq, String status) => SessionSnapshot.fromJson({
            'panes': [
              {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'agent_status': status}
            ],
            'agents': [
              {'agent': 'claude', 'pane_id': 'w1:p1', 'status': status, 'state_change_seq': seq}
            ],
          });
      client.setSnapshotForTesting(snap(1, 'working'));
      client.setSnapshotForTesting(snap(2, 'done'));
      final at = client.changedAt('w1:p1');
      expect(at, isNotNull);
      client.setSnapshotForTesting(snap(2, 'idle'));
      expect(client.changedAt('w1:p1'), at);
    });

    test('Agent titles lose their agent tags, and the agent is named by its program', () {
      String title(String t) => PaneModel.fromJson({'terminal_title_stripped': t, 'cwd': '/src/my-repo'}).terminalTitle;
      expect(title('OC | Fix scroll'), 'Fix scroll');
      expect(title('Tab sizes - grok'), 'Tab sizes');
      expect(title('Claude Code'), '');
      expect(title('my-repo'), '');
      expect(title('xicu@host:~/src/my-repo'), 'xicu@host:~/src/my-repo');
      expect(AgentModel.fromJson({'agent': 'opencode', 'name': 'scrollprobe', 'pane_id': 'p'}).name, 'opencode');
    });

    testWidgets('Agent avatar shows status ring and no StatusDot on AgentsHomeScreen', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..configure('10.0.0.1:7788', connect: false);

      final snap = SessionSnapshot.fromJson({
        'workspaces': [
          {'workspace_id': 'w1', 'label': 'ws1', 'active_tab_id': 'w1:t1'}
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'main'}
        ],
        'panes': [
          {
            'pane_id': 'w1:p1',
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'terminal_title': 'agent-task',
            'agent_status': 'working',
          }
        ],
        'agents': [
          {
            'name': 'claude',
            'pane_id': 'w1:p1',
            'status': 'working',
          }
        ],
      });

      client.setSnapshotForTesting(snap);
      await tester.pumpWidget(MaterialApp(home: HerdrMobileApp(client: client)));
      await tester.pumpAndSettle();

      final avatarFinder = find.byType(AgentAvatar);
      expect(avatarFinder, findsOneWidget);
      final avatar = tester.widget<AgentAvatar>(avatarFinder);
      expect(avatar.status, 'working');
      // No trailing status dot in the list tile
      expect(find.descendant(of: find.byType(ListTile), matching: find.byType(StatusDot)), findsNothing);
    });

    testWidgets('Draft status is shown when draft message exists on the message terminal and clears when removed',
        (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      TerminalScreen.clearDraftsForTesting();
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..configure('10.0.0.1:7788', connect: false);

      final snap = SessionSnapshot.fromJson({
        'workspaces': [
          {'workspace_id': 'w1', 'label': 'ws1', 'active_tab_id': 'w1:t1'}
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'main'}
        ],
        'panes': [
          {
            'pane_id': 'w1:p1',
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'terminal_title': 'agent-task',
            'agent_status': 'working',
          }
        ],
        'agents': [
          {
            'name': 'claude',
            'pane_id': 'w1:p1',
            'status': 'working',
          }
        ],
      });

      client.setSnapshotForTesting(snap);
      await tester.pumpWidget(MaterialApp(home: HerdrMobileApp(client: client)));
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }

      await settle();

      expect(find.text('Working…'), findsOneWidget);
      expect(find.text('Draft'), findsNothing);

      // Open terminal and type a message into the message box
      await tester.tap(find.widgetWithText(ListTile, 'agent-task'));
      await settle();

      final messageBox = find.descendant(of: find.byType(TerminalScreen), matching: find.byType(TextField));
      await tester.enterText(messageBox, 'Unsent draft text');
      await settle();

      // Navigate back to home screen
      await tester.tap(find.byIcon(Icons.arrow_back));
      await settle();
      await settle();

      // "Draft" is shown with draftColor in place of "Working…"
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('Working…'), findsNothing);
      final draftText = tester.widget<Text>(find.text('Draft'));
      expect(draftText.style?.color, equals(AgentStatus.draftColor));

      // Reopen terminal, clear text, and navigate back
      await tester.tap(find.widgetWithText(ListTile, 'agent-task'));
      await settle();

      final messageBox2 = find.descendant(of: find.byType(TerminalScreen), matching: find.byType(TextField));
      await tester.enterText(messageBox2, '');
      await settle();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await settle();
      await settle();

      expect(find.text('Draft'), findsNothing);
      expect(find.text('Working…'), findsOneWidget);
    });

    testWidgets('AgentsHomeScreen top bar has computer icon; TerminalScreen top bar has machine chip with status dot',
        (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], ['10.0.0.1:7788=MacBook Pro'])
        ..configure('10.0.0.1:7788', connect: false);

      final snap = SessionSnapshot.fromJson({
        'workspaces': [
          {'workspace_id': 'w1', 'label': 'ws1', 'active_tab_id': 'w1:t1', 'git_branch': 'feat-test'}
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'main'}
        ],
        'panes': [
          {
            'pane_id': 'w1:p1',
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'terminal_title': 'agent-task',
            'agent_status': 'working',
          }
        ],
        'agents': [
          {
            'name': 'claude',
            'pane_id': 'w1:p1',
            'status': 'working',
          }
        ],
      });
      client.setSnapshotForTesting(snap);

      await tester.pumpWidget(MaterialApp(home: AgentsHomeScreen(client: client)));
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await settle();

      // Main screen (AgentsHomeScreen) has computer icon button and no ActionChip
      expect(find.byType(ActionChip), findsNothing);
      final computerBtnFinder = find.byTooltip('Machines');
      expect(computerBtnFinder, findsOneWidget);

      // Open conversation / terminal screen
      await tester.tap(find.text('agent-task'));
      await settle();

      // Conversation screen (TerminalScreen) has Chip with machine name 'MacBook Pro'
      final chipFinder = find.byType(Chip);
      expect(chipFinder, findsOneWidget);
      expect(find.descendant(of: chipFinder, matching: find.text('MacBook Pro')), findsOneWidget);

      // Connecting status shows orange dot
      final dotContainer =
          tester.widget<Container>(find.descendant(of: chipFinder, matching: find.byType(Container)).first);
      final decoration = dotContainer.decoration as BoxDecoration;
      expect(decoration.color, equals(Colors.orange));

      // Connected status shows green dot
      client.setConnectedForTesting('10.0.0.1:7788', true);
      await settle();
      final dotContainerConnected =
          tester.widget<Container>(find.descendant(of: chipFinder, matching: find.byType(Container)).first);
      final decorationConnected = dotContainerConnected.decoration as BoxDecoration;
      expect(decorationConnected.color, equals(Colors.green));

      // Tapping the chip does not open edit machine dialog
      await tester.tap(chipFinder);
      await settle();
      expect(find.text('Edit machine'), findsNothing);
    });

    testWidgets('AgentsHomeScreen displays branch_name (tab_name) · machine in agent subtitle', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], ['10.0.0.1:7788=MacBook', '10.0.0.2:7788=Server'])
        ..configure('10.0.0.1:7788', connect: false);

      final snap1 = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'workspaces': [
          {
            'workspace_id': 'w1',
            'number': 1,
            'label': 'herdr-mobile',
            'git_branch': 'feat-home',
            'pane_count': 2,
            'tab_count': 2,
            'active_tab_id': 'w1:t1',
            'agent_status': 'working',
          }
        ],
        'tabs': [
          {
            'tab_id': 'w1:t1',
            'workspace_id': 'w1',
            'number': 1,
            'label': 'feat-agents',
            'agent_status': 'working',
          },
          {
            'tab_id': 'w1:t2',
            'workspace_id': 'w1',
            'number': 2,
            'label': 'bugfix',
            'agent_status': 'idle',
          }
        ],
        'panes': [
          {
            'pane_id': 'w1:p1',
            'terminal_id': 'term_1',
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'focused': true,
            'terminal_title': 'agent-task',
            'agent_status': 'working',
          }
        ],
        'agents': [
          {
            'name': 'claude',
            'pane_id': 'w1:p1',
            'status': 'working',
          }
        ],
      });
      client.setSnapshotForTesting(snap1, '10.0.0.1:7788');

      await tester.pumpWidget(MaterialApp(home: AgentsHomeScreen(client: client)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // With multiple machines and multiple tabs: branch_name (tab_name) · machine
      expect(find.text('feat-home (feat-agents) · MacBook'), findsOneWidget);
    });

    testWidgets('Hide message terminal option in settings panel hides the message terminal in TerminalScreen',
        (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..configure('10.0.0.1:7788', connect: false);

      final snap = SessionSnapshot.fromJson({
        'workspaces': [
          {'workspace_id': 'w1', 'label': 'ws1', 'active_tab_id': 'w1:t1'}
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'main'}
        ],
        'panes': [
          {
            'pane_id': 'w1:p1',
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'terminal_title': 'agent-task',
            'agent_status': 'working',
          }
        ],
        'agents': [
          {
            'name': 'claude',
            'pane_id': 'w1:p1',
            'status': 'working',
          }
        ],
      });
      client.setSnapshotForTesting(snap);

      // Verify SettingsScreen has "Hide message terminal" switch
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(client: client)));
      await tester.pumpAndSettle();

      final switchTile = find.widgetWithText(SwitchListTile, 'Hide message terminal');
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(switchTile, findsOneWidget);
      expect(client.hideMessageTerminal, isFalse);

      // Toggle switch to hide message terminal
      await tester.tap(switchTile);
      await tester.pumpAndSettle();
      expect(client.hideMessageTerminal, isTrue);

      // In TerminalScreen, the message terminal (TextField) should not be rendered
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Control keys'), findsNothing);

      // Toggle back in client
      client.setHideMessageTerminal(false);
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byTooltip('Control keys'), findsOneWidget);
    });

    testWidgets('SettingsScreen displays notification options when alerts are enabled', (tester) async {
      final client = HerdrClientService();
      client.setAlerts(true);

      await tester.pumpWidget(MaterialApp(home: SettingsScreen(client: client)));
      await tester.pumpAndSettle();

      expect(find.text('Agent alerts'), findsOneWidget);
      expect(find.text('Needs you'), findsOneWidget);
      expect(find.text('Finished'), findsOneWidget);

      // Verify toggling options updates client state
      expect(client.alertBlocked, isTrue);
      await tester.tap(find.widgetWithText(SwitchListTile, 'Needs you'));
      await tester.pumpAndSettle();
      expect(client.alertBlocked, isFalse);

      if (Platform.isLinux) {
        await tester.scrollUntilVisible(find.widgetWithText(SwitchListTile, 'Sound'), 100);
        await tester.pumpAndSettle();
        expect(client.alertSound, isTrue);
        await tester.tap(find.widgetWithText(SwitchListTile, 'Sound'));
        await tester.pumpAndSettle();
        expect(client.alertSound, isFalse);

        expect(client.alertDesktop, isTrue);
        await tester.scrollUntilVisible(find.widgetWithText(SwitchListTile, 'Desktop notifications'), 100);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(SwitchListTile, 'Desktop notifications'));
        await tester.pumpAndSettle();
        expect(client.alertDesktop, isFalse);
      }

      // Verify Muted agents section
      await tester.scrollUntilVisible(find.text('Muted agents'), 100);
      await tester.pumpAndSettle();
      expect(find.text('Muted agents'), findsOneWidget);
      expect(find.text('None'), findsOneWidget);

      // Mute a pane and verify count and bottom sheet
      client.setMuted('p1', true, '127.0.0.1:7788');
      await tester.pumpAndSettle();
      expect(find.text('1 muted'), findsOneWidget);

      await tester.tap(find.text('Muted agents'));
      await tester.pumpAndSettle();
      expect(find.text('Unmute all'), findsOneWidget);

      await tester.tap(find.text('Unmute all'));
      await tester.pumpAndSettle();
      expect(client.muted, isEmpty);
    });

    testWidgets('In a worktree, top bar shows main repo name on top and worktree chip before branch on bottom',
        (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..configure('10.0.0.1:7788', connect: false);

      final snap = SessionSnapshot.fromJson({
        'workspaces': [
          {
            'workspace_id': 'w1',
            'number': 1,
            'label': 'herdr-mobile',
            'active_tab_id': 'w1:t1',
            'git_branch': 'main',
            'worktree': {
              'repo_key': 'repo-1',
              'is_linked_worktree': false,
            },
          },
          {
            'workspace_id': 'w2',
            'number': 2,
            'label': 'worktree-feat-login',
            'active_tab_id': 'w2:t1',
            'git_branch': 'feat-login',
            'worktree': {
              'repo_key': 'repo-1',
              'is_linked_worktree': true,
            },
          },
        ],
        'tabs': [
          {
            'tab_id': 'w2:t1',
            'workspace_id': 'w2',
            'number': 1,
            'label': 'main',
          },
        ],
        'panes': [
          {
            'pane_id': 'w2:p1',
            'workspace_id': 'w2',
            'tab_id': 'w2:t1',
            'terminal_title': 'login-feature',
            'agent_status': 'working',
          },
        ],
        'agents': [
          {
            'name': 'claude',
            'pane_id': 'w2:p1',
            'status': 'working',
          },
        ],
      });

      client.setSnapshotForTesting(snap);
      client.selectPane('w2:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));

      // Terminal AppBar should show main repo name 'herdr-mobile' on top and 'worktree' chip before branch 'feat-login' on bottom
      final appBarFinder = find.byType(AppBar);
      final chipInBar = find.descendant(of: appBarFinder, matching: find.text('worktree'));
      final repoInBar = find.descendant(of: appBarFinder, matching: find.text('herdr-mobile'));
      final branchInBar = find.descendant(of: appBarFinder, matching: find.text('feat-login'));

      expect(chipInBar, findsOneWidget);
      expect(repoInBar, findsOneWidget);
      expect(branchInBar, findsOneWidget);

      // Chip is vertically below the repo name
      expect(tester.getTopLeft(chipInBar).dy, greaterThan(tester.getTopLeft(repoInBar).dy));
      // Chip is horizontally before the branch name on the bottom line
      expect(tester.getTopLeft(chipInBar).dx, lessThan(tester.getTopLeft(branchInBar).dx));
      // Branch is vertically below the repo name
      expect(tester.getTopLeft(branchInBar).dy, greaterThan(tester.getTopLeft(repoInBar).dy));

      // showWorkspaceActions shows the chip before branch
      showWorkspaceActions(tester.element(appBarFinder), client, snap.workspaces[1]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final sheetHeader = find.byType(ListTile).first;
      final chipInSheet = find.descendant(of: sheetHeader, matching: find.text('worktree'));
      final repoInSheet = find.descendant(of: sheetHeader, matching: find.text('herdr-mobile'));
      final branchInSheet = find.descendant(of: sheetHeader, matching: find.text('feat-login'));

      expect(chipInSheet, findsOneWidget);
      expect(repoInSheet, findsOneWidget);
      expect(branchInSheet, findsOneWidget);
      expect(tester.getTopLeft(chipInSheet).dy, greaterThan(tester.getTopLeft(repoInSheet).dy));
      expect(tester.getTopLeft(chipInSheet).dx, lessThan(tester.getTopLeft(branchInSheet).dx));
    });

    testWidgets('Ctrl + and Ctrl - change terminal zoom on Linux/desktop', (tester) async {
      final client = HerdrClientService();
      client.setFontSize(14);
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {
            'workspace_id': 'w1',
            'number': 1,
            'label': 'main',
            'focused': true,
            'pane_count': 1,
            'tab_count': 1,
            'active_tab_id': 'w1:t1',
            'agent_status': 'unknown',
          }
        ],
        'tabs': [
          {
            'tab_id': 'w1:t1',
            'workspace_id': 'w1',
            'number': 1,
            'label': 'tab1',
            'focused': true,
            'pane_count': 1,
            'agent_status': 'unknown',
          }
        ],
        'panes': [
          {
            'pane_id': 'w1:p1',
            'terminal_id': 'term_1',
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'focused': true,
            'terminal_title': 'agent',
            'agent_status': 'working',
          }
        ],
        'agents': [
          {
            'name': 'coder',
            'pane_id': 'w1:p1',
            'status': 'working',
          }
        ],
      });
      client.setSnapshotForTesting(snap);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));

      expect(client.fontSize, equals(14.0));

      // Press Ctrl + (equal key) to zoom in
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(client.fontSize, equals(15.0));

      // Press Ctrl + (numpadAdd key) to zoom in
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(client.fontSize, equals(16.0));

      // Press Ctrl - to zoom out
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(client.fontSize, equals(15.0));

      // Press Ctrl 0 to reset zoom to 14
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(client.fontSize, equals(14.0));

      // Pressing minus without Ctrl should not change font size
      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await tester.pump();
      expect(client.fontSize, equals(14.0));
    });
  });
}
