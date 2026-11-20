import 'dart:async';
import 'dart:ui' as ui;
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

// The desktop's synthesized Control keydown, as Omarchy's SUPER+C delivers it: no Control key was
// pressed, so the embedder makes the key event itself.
Future<void> sendSynthesizedControl(WidgetTester tester) async {
  // The deprecated key-data entry point is the only way to hand the framework a synthesized
  // event, as the engine's embedder does for a modifier the desktop put down.
  // ignore: deprecated_member_use
  ServicesBinding.instance.keyEventManager.handleKeyData(ui.KeyData(
    timeStamp: Duration.zero,
    type: ui.KeyEventType.down,
    logical: LogicalKeyboardKey.controlLeft.keyId,
    physical: PhysicalKeyboardKey.controlLeft.usbHidUsage,
    character: null,
    synthesized: true,
  ));
  await tester.pump();
}

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
          WorkspaceModel(id: 'w1', number: 1, label: 'frontend', agentStatus: 'idle'),
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

      // Workspace with multiple tabs shows workspace (tab)
      expect(snapshot.placeOf(snapshot.panes[0]), equals('frontend (ui)'));
      expect(snapshot.placeOf(snapshot.panes[1]), equals('frontend (tests)'));
      // Workspace without multiple tabs shows workspace label
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

    test('What is closed hides at once, comes back on Undo, and is closed otherwise', () async {
      SharedPreferences.setMockInitialValues({});
      const m = '100.1.2.3:7788';
      final client = HerdrClientService()
        ..setMachines([m], [])
        ..switchMachine(m)
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');

      // A tab: its panes and agents go with it, and the selection moves to the next tab.
      final undo = Completer<bool>();
      var closed = false;
      final done = client.closeUnlessUndone(['$m/w1:t1'], undo.future, () async => closed = true);
      expect(client.snapshot!.tabs.map((t) => t.id), isNot(contains('w1:t1')));
      expect(client.snapshot!.agents.map((a) => a.paneId), ['w2:p4']);
      expect(client.selectedPane?.tabId, 'w1:t2');
      undo.complete(true);
      await done;
      expect(closed, isFalse);
      expect(client.snapshot!.tabs.map((t) => t.id), contains('w1:t1'));

      // A workspace, not undone: closed, then shown as herdr has it.
      await client.closeUnlessUndone(['$m/w2'], Future.value(false), () async => closed = true);
      expect(closed, isTrue);
    });

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

    testWidgets('A tap on the terminal never shows the control keys nor the keyboard', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal.write('\r\n\r\nhello world');
      await tester.pump();
      final terminal = find.byType(TerminalView);
      final hello = tester.getTopLeft(terminal) + const Offset(10, 40);

      // Held down past the tap-down that xterm opens it on, and on to a long-press: no keyboard, and the
      // message box stays. (A test's keyboard takes no room, so it counts as put away, as by back.)
      final press = await tester.startGesture(hello);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pump(const Duration(milliseconds: 600));
      await press.up(timeStamp: const Duration(milliseconds: 800)); // a test's events are otherwise all at 0
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(terminal); // clears the long-press's selection, and only that
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.testTextInput.isVisible, isFalse);

      // A tap sends a click to the pane but leaves the message box alone, and never the keyboard.
      await tester.tap(terminal);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(client.keyBar, isFalse);
      expect(find.text('ESC'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);

      // The control keys come only from their button.
      await tester.tap(find.byTooltip('Control keys'));
      await tester.pump();
      expect(client.keyBar, isTrue);
      expect(find.text('ESC'), findsOneWidget);
      expect(find.text('CTRL'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      // Only the keyboard button beside the keys opens it.
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);

      // A double-tap selects nothing.
      await tester.tapAt(hello);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(hello);
      await tester.pump();
      expect(find.text('Copy'), findsNothing);

      // The message box button goes back to the box.
      await tester.tap(find.byTooltip('Message box'));
      await tester.pump();
      expect(client.keyBar, isFalse);
      expect(find.byType(TextField), findsOneWidget);
      await tester.pump(const Duration(seconds: 1)); // xterm's double-tap timer
    });

    testWidgets('Tapping an https link in the terminal opens it in the browser', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      String? openedUrl;
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1')
        ..onOpenUrl = (url) async => openedUrl = url;
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal.write('\r\n\r\nVisit https://herdr.dev for details');
      await tester.pump();
      final terminal = find.byType(TerminalView);
      // Row 2 has "Visit https://herdr.dev for details"
      final linkPos = tester.getTopLeft(terminal) + const Offset(120, 40);

      await tester.tapAt(linkPos);
      await tester.pump();
      expect(openedUrl, 'https://herdr.dev');
      await tester.pump(const Duration(seconds: 1)); // xterm's double-tap timer
    });

    testWidgets("A selection's handles adjust it, and Copy takes what they cover", (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal.write('hello brave new world');
      await tester.pump();

      // Long-press "hello" (the first cells) to select it, then drag its end handle on past "brave".
      final view = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
      final cell = view.cellSize;
      await tester.longPressAt(view.localToGlobal(Offset(cell.width * 2, cell.height / 2)));
      await tester.pump(const Duration(milliseconds: 500));
      final handles = find.byWidgetPredicate((w) => w is GestureDetector && w.onPanUpdate != null);
      expect(handles, findsNWidgets(2));
      await tester.drag(handles.last, Offset(cell.width * 6, 0));
      await tester.pump();
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, 'hello brave');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('A tab held and lifted shows its menu; held and dragged, none', (tester) async {
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

      final first = find.byType(ReorderableDelayedDragStartListener).first;
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(tester.getSize(first).width, 168);

      // Held and moved: a drag, no menu.
      final drag = await tester.startGesture(tester.getCenter(first));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await drag.moveBy(const Offset(60, 0));
      await tester.pump();
      await drag.up();
      await settle();
      expect(find.text('Close tab'), findsNothing);

      // Held still and lifted: the current (first) tab's menu, which can't move it further left nor open it again.
      await tester.longPress(first);
      await settle();
      expect(find.text('Move left'), findsNothing);
      expect(find.text('Open tab'), findsNothing);
      expect(find.text('Move right'), findsOneWidget);
      expect(find.text('Close tab'), findsOneWidget);
    });

    testWidgets('A tab dragged past the last one moves to the end', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));

      final drag = await tester.startGesture(tester.getCenter(find.byType(ReorderableDelayedDragStartListener).first));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await drag.up();
      // The drop settles into its slot before the move is made.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect([for (final t in client.snapshot!.tabs) t.id], ['w1:t2', 'w1:t1', 'w2:t1']);
    });

    testWidgets('The top bar shows the workspace and its tabs; tapping a tab shows it', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));

      // Top bar shows the workspace; under it the tabs with their summaries.
      Finder inBar(String t) => find.descendant(of: find.byType(AppBar), matching: find.text(t));
      expect(inBar('backend'), findsOneWidget);
      expect(inBar('coder'), findsOneWidget);
      expect(inBar('db'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(inBar('db'));
      expect(client.selectedPaneId, 'w1:p3');

      // The control keys' button swaps the message box for the control keys, and the message box button back.
      await tester.tap(find.byTooltip('Control keys'));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('ESC'), findsOneWidget);
      await tester.tap(find.byTooltip('Message box'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);

      // The header only names the workspace: its actions are in the workspaces panel.
      await tester.tap(inBar('backend'));
      await tester.tap(inBar('backend'), buttons: kSecondaryMouseButton);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // the Connecting spinner never settles
      expect(find.text('Rename'), findsNothing);
    });

    test('Editing a machine renames it and moves it in place', () {
      final client = HerdrClientService()..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], ['10.0.0.1:7788=old']);
      client.updateMachine('10.0.0.1:7788', to: 'laptop:9000', name: 'work');
      expect(client.machines, ['laptop:9000', '10.0.0.2:7788']);
      expect(client.nameOf('laptop:9000'), 'work');
      expect(client.nameOf('10.0.0.1:7788'), '10.0.0.1:7788');
    });

    testWidgets("The ☰ drawer lists the workspaces; tap one for its terminal, hold one for its actions",
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
      // Each machine's name carries its own +, in place of a FAB.
      expect(find.byTooltip('New workspace on 100.1.2.3:7788'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);

      expect(find.descendant(of: find.byType(WorkspaceList), matching: find.byIcon(Icons.more_vert)), findsNothing);
      await tester.longPress(find.descendant(of: find.byType(WorkspaceList), matching: find.text('backend')));
      await settle();
      expect(find.byType(TerminalScreen), findsNothing); // the hold isn't a tap
      for (final item in ['Rename', 'Close']) {
        expect(find.text(item), findsOneWidget);
      }
      await tester.tapAt(const Offset(10, 10)); // dismiss the menu
      await settle();

      await tester.tap(find.descendant(of: find.byType(WorkspaceList), matching: find.text('frontend')));
      await settle();
      expect(client.selectedPaneId, 'w2:p4');
      expect(find.byType(TerminalScreen), findsOneWidget);
    });

    testWidgets("The terminal's header opens the workspaces panel over it, switching pane in place",
        (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..switchMachine('100.1.2.3:7788')
        ..setSnapshotForTesting(twoWorkspaces())
        ..setConnectedForTesting('100.1.2.3:7788', true)
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1)); // the terminal's own stream never settles
      }

      // The workspace's name, with its branch under it, opens the panel; the terminal stays.
      await tester.tap(find.text('backend'));
      await settle();
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.byType(TerminalScreen), findsOneWidget);

      // Picking another workspace switches this terminal to it, closing only the panel.
      await tester.tap(find.descendant(of: find.byType(WorkspaceList), matching: find.text('frontend')));
      await settle();
      expect(client.selectedPaneId, 'w2:p4');
      expect(find.text('Workspaces'), findsNothing);
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

      // Opening the machines panel in landscape opens the machines drawer.
      await tester.tap(find.byTooltip('Machines'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MachineList), findsOneWidget);
      expect(find.byType(TerminalScreen), findsOneWidget);

      // Tapping outside the drawer closes it.
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MachineList), findsNothing);
      expect(find.byType(TerminalScreen), findsOneWidget);

      // Open it again to test machine detail navigation.
      await tester.tap(find.byTooltip('Machines'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MachineList), findsOneWidget);

      // In landscape, tapping a machine opens MachineScreen on the right side instead of full screen.
      await tester.tap(find.descendant(of: find.byType(MachineList), matching: find.text(m)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MachineScreen), findsOneWidget);
      expect(find.byType(TerminalScreen), findsNothing);

      // Closing the machine detail restores the terminal on the right.
      await tester.tap(find.descendant(of: find.byType(MachineScreen), matching: find.byTooltip('Close')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MachineScreen), findsNothing);
      expect(find.byType(TerminalScreen), findsOneWidget);

      // In landscape, opening Settings from the drawer opens SettingsScreen on the right side.
      await tester.tap(find.byTooltip('Workspaces'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Settings'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(TerminalScreen), findsNothing);

      // Closing Settings restores the terminal on the right.
      await tester.tap(find.descendant(of: find.byType(SettingsScreen), matching: find.byTooltip('Close')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byType(TerminalScreen), findsOneWidget);
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
      expect(find.text('Save'), findsOneWidget); // its page
      expect(find.text('Remove machine', skipOffstage: false), findsOneWidget);
      await tester.tap(find.byType(CloseButton));
      await settle();

      await tester.tap(find.byTooltip('Add machine'));
      await settle();
      expect(find.text('Add'), findsOneWidget);

      // A machine is its SSH target; the phone's key to authorize there is on the page.
      expect(find.text("This phone's key"), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'SSH target'), 'me@100.64.0.7');
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'pi');
      await tester.tap(find.text('Add'));
      await settle();
      expect(client.machines, contains('me@100.64.0.7'));
      expect(client.nameOf('me@100.64.0.7'), 'pi');
    });

    test('Moving a machine keeps those a bridge reaches under it', () {
      SharedPreferences.setMockInitialValues({});
      final client = HerdrClientService()
        ..setMachines(['a:7788', 'a:7788/m/x', 'a:7788/m/y', 'b:7788'], [], ['a:7788', 'b:7788']);
      client.moveMachine('b:7788', 0);
      expect(client.machines, ['b:7788', 'a:7788', 'a:7788/m/x', 'a:7788/m/y']);
      client.moveMachine('a:7788/m/y', 0);
      expect(client.machines, ['b:7788', 'a:7788', 'a:7788/m/y', 'a:7788/m/x']);
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

      // Disconnecting the bridge leaves other bridges unaffected
      client.disconnect(laptop);
      expect(client.isOff(laptop), isTrue);
      expect(client.isOff(other), isFalse);

      // A machine reached through a bridge remembers its own on/off switch state
      client.disconnect(sert);
      expect(client.isOff(sert), isTrue);
      client.connect(laptop);
      expect(client.isOff(laptop), isFalse);
      expect(client.isOff(sert), isTrue); // sert stays off when laptop connects because sert was individually turned off
      client.connect(sert);
      expect(client.isOff(sert), isFalse);

      // The machine on screen is remembered with its path.
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('hc_active'), sert);
      expect((HerdrClientService()..load(prefs)).machine, sert);

      client.removeMachine(laptop);
      expect(client.machines, [other]);
      expect(client.machine, other);
    });

    testWidgets('Adding an SSH machine through the UI calls addSshMachine', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = _RecordingClient()
        ..setMachines(['bridge1:7788', 'bridge2:7788'], [], [])
        ..configure('bridge1:7788', connect: false);

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showMachinePage(context, client),
              child: const Text('Open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Machines exist, so a new one can be dialed from the phone or added through one's herdr-core
      expect(find.text('From this phone'), findsOneWidget);
      expect(find.text('Through Herdr'), findsOneWidget);

      await tester.tap(find.text('Through Herdr'));
      await tester.pumpAndSettle();

      // Via dropdown is visible because there are 2 bridges
      expect(find.text('Via'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'SSH target'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'SSH target'), 'dev@remote');
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'myserver');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(client.addedBridge, 'bridge1:7788');
      expect(client.addedTarget, 'dev@remote');
      expect(client.addedName, 'myserver');
      // Dialog has closed
      expect(find.widgetWithText(TextField, 'SSH target'), findsNothing);
    });

    testWidgets('client.onError triggers a SnackBar in HerdrMobileApp', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = HerdrClientService();
      await tester.pumpWidget(HerdrMobileApp(client: client));
      client.onError?.call('Could not add machine: Network unreachable');
      await tester.pumpAndSettle();
      expect(find.text('Could not add machine: Network unreachable'), findsOneWidget);
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
      expect(alerts.first['title'], contains('finished'));
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

      // Swiping it right reveals Mute, and pressing Mute mutes it
      await tester.drag(find.text('antigravity-refactor'), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(find.text('antigravity-refactor'), findsOneWidget);
      expect(find.text('Mute'), findsOneWidget);
      await tester.tap(find.text('Mute'));
      await tester.pumpAndSettle();
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

      // Swiping it left reveals Close, and pressing Close closes it at once with an Undo snackbar.
      await tester.drag(find.text('antigravity-refactor'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('antigravity-refactor'), findsNothing);
      expect(find.text('Agent closed'), findsOneWidget);

      // Undo brings it back, the snackbar going with it.
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('antigravity-refactor'), findsOneWidget);
      expect(find.text('Agent closed'), findsNothing);

      // Picking both and closing the selection is undoable too, in one snackbar.
      await tester.longPress(find.text('claude-task'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('antigravity-refactor'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('claude-task'), findsNothing);
      expect(find.text('antigravity-refactor'), findsNothing);
      expect(find.text('Agents closed'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('claude-task'), findsOneWidget);
      expect(find.text('antigravity-refactor'), findsOneWidget);
      expect(find.text('Agents closed'), findsNothing);
    });

    testWidgets('Agent timestamps update when state changes and format correctly in AgentsHomeScreen', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..configure('10.0.0.1:7788', connect: false);

      SessionSnapshot snap(int? seq, String status) => SessionSnapshot.fromJson({
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

      // No status time yet: none shown
      client.setSnapshotForTesting(snap(null, 'working'));
      expect(client.changedAt('w1:p1'), isNull);

      await tester.pumpWidget(MaterialApp(
        home: HerdrMobileApp(client: client),
      ));
      await tester.pumpAndSettle();

      // herdr-core's status time is when it changed
      final at = DateTime.now().millisecondsSinceEpoch;
      client.setSnapshotForTesting(snap(at, 'blocked'));
      expect(client.changedAt('w1:p1'), DateTime.fromMillisecondsSinceEpoch(at));

      await tester.pumpAndSettle();
      expect(find.text('agent-task'), findsOneWidget);
      expect(find.text('ws1'), findsOneWidget);
      expect(find.text('Needs you'), findsOneWidget);
      // Status text is below the date in the trailing column and aligned with the subtitle at the bottom
      final dateFinder = find
          .text(AgentsHomeScreen.formatWhen(tester.element(find.byType(AgentsHomeScreen)), client.changedAt('w1:p1')!));
      expect(tester.getTopLeft(find.text('Needs you')).dy, greaterThan(tester.getTopLeft(dateFinder).dy));
      expect(tester.getBottomLeft(find.text('Needs you')).dy, closeTo(tester.getBottomLeft(find.text('ws1')).dy, 3.0));
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

      // Conversation screen (TerminalScreen) has a chip with machine name 'MacBook Pro'
      final chipFinder = find.byType(ActionChip);
      expect(chipFinder, findsOneWidget);
      expect(find.descendant(of: chipFinder, matching: find.text('MacBook Pro')), findsOneWidget);
      BoxDecoration dot() => tester
          .widget<Container>(find.descendant(of: chipFinder, matching: find.byType(Container)).first)
          .decoration as BoxDecoration;

      // Connecting shows a hollow dot
      expect(dot().color, isNull);
      expect(dot().border, isNotNull);

      // Connected status shows green dot
      client.setConnectedForTesting('10.0.0.1:7788', true);
      await settle();
      expect(dot().color, equals(Colors.green));

      // Tapping the chip opens the machine's page: its status, then Connection, Display and Remove
      await tester.tap(chipFinder);
      await settle();
      expect(find.text('Connection'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('AgentsHomeScreen displays workspace (tab_name) · machine in agent subtitle', (tester) async {
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

      // With multiple machines and multiple tabs: workspace (tab_name) · machine
      expect(find.text('herdr-mobile (feat-agents) · MacBook'), findsOneWidget);
    });

    testWidgets('Hide message bar option in settings hides the message bar in TerminalScreen',
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

      // Verify SettingsScreen has "Hide message bar" switch
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(client: client)));
      await tester.pumpAndSettle();

      final switchTile = find.widgetWithText(SwitchListTile, 'Hide message bar');
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

    test('AgentUsage and UsageLimit parse correctly from JSON', () {
      final json = {
        'version': '0.9.3',
        'protocol': 22,
        'workspaces': [],
        'tabs': [],
        'panes': [],
        'agents': [
          {
            'name': 'claude',
            'pane_id': 'w1:p1',
            'agent_status': 'working',
            'usage': {
              'tier_label': 'Team',
              'limits': [
                {'label': 'Session (5-hour)', 'percent': 0.52, 'resets_at': '2026-10-07T17:39:59Z'},
                {'label': 'Weekly (7-day)', 'percent': 0.47, 'resets_at': '2026-10-13T07:59:59Z'},
              ],
              'today_tokens': 105691105,
              'today_prompts': 645,
            }
          }
        ],
      };

      final snapshot = SessionSnapshot.fromJson(json);
      final agent = snapshot.agents.first;
      expect(agent.usage, isNotNull);
      expect(agent.usage!.tierLabel, equals('Team'));
      expect(agent.usage!.limits.length, equals(2));
      expect(agent.usage!.limits.first.label, equals('Session (5-hour)'));
      expect(agent.usage!.limits.first.percent, equals(0.52));
      expect(agent.usage!.highestPercent, equals(0.52));
      expect(agent.usage!.todayTokens, equals(105691105));
      expect(agent.usage!.todayPrompts, equals(645));
    });

    test('AgentUsage headline ignores secondary Claude/GPT tiers', () {
      final usage = AgentUsage.fromJson({
        'tier_label': 'Gemini 3.7 Flash',
        'limits': [
          {'label': 'Session (5-hour)', 'percent': 0.4, 'primary': true},
          {'label': 'Weekly (7-day)', 'percent': 0.3, 'primary': true},
          {'label': 'Claude Models Session', 'percent': 1.0, 'primary': false},
          {'label': 'GPT Models Weekly', 'percent': 1.0, 'primary': false},
        ],
      });
      expect(usage.limits.length, equals(4));
      expect(usage.highestPercent, equals(0.4));

      // Old bridges send no `primary` flag: infer it from the label.
      final legacy = AgentUsage.fromJson({
        'tier_label': 'Gemini 3.7 Flash',
        'limits': [
          {'label': 'Session (5-hour)', 'percent': 0.4},
          {'label': 'Claude Models Session', 'percent': 1.0},
        ],
      });
      expect(legacy.limits[0].isPrimary, isTrue);
      expect(legacy.limits[1].isPrimary, isFalse);
      expect(legacy.highestPercent, equals(0.4));
    });

    testWidgets('TerminalScreen message box has quota bolt button that opens usage sheet', (tester) async {
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'main', 'active_tab_id': 'w1:t1', 'agent_status': 'working'},
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'working'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'focused': true, 'agent_status': 'working', 'terminal_title': 'Task'},
        ],
        'agents': [
          {
            'name': 'claude',
            'pane_id': 'w1:p1',
            'agent_status': 'working',
            'usage': {
              'tier_label': 'Team Plan',
              'limits': [
                {'label': 'Session (5-hour)', 'percent': 0.85, 'resets_at': '2026-10-07T18:00:00Z'},
                {
                  'label': 'Weekly (7-day)',
                  'percent': 0.47,
                  'resets_at': DateTime.now().add(const Duration(days: 3, hours: 23, minutes: 15)).toIso8601String(),
                },
                {
                  'label': 'Monthly',
                  'percent': 0.10,
                  'resets_at': DateTime.now().add(const Duration(days: 4, minutes: 10)).toIso8601String(),
                },
              ],
              'today_tokens': 50000,
              'today_prompts': 10,
            }
          }
        ],
      });
      client.setSnapshotForTesting(snap);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));

      // The usage chip shows the remaining quota percentage
      final quotaFinder = find.text('15%');
      expect(quotaFinder, findsOneWidget);

      // Tap the quota chip to open the usage sheet
      await tester.tap(quotaFinder);
      await tester.pumpAndSettle();

      expect(find.text('claude'), findsOneWidget);
      expect(find.text('Team Plan'), findsOneWidget);
      expect(find.byType(AgentAvatar), findsWidgets);
      expect(find.text('Session (5-hour)'), findsOneWidget);
      expect(find.text('Weekly (7-day)'), findsOneWidget);
      expect(find.text('Resets in 3d 23h'), findsOneWidget);
      expect(find.text('Resets in 4d 0h'), findsOneWidget);
      expect(find.text('15% left'), findsOneWidget);
      expect(find.text('85% used'), findsOneWidget);
      expect(find.text('50.0k'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
    });

    testWidgets('The history button left of the message box opens recent messages', (tester) async {
      SharedPreferences.setMockInitialValues({
        'message_history': ['fix bug in layout', 'run tests'],
        'recent_commands': ['/help', '/clear'],
      });
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'main', 'active_tab_id': 'w1:t1', 'agent_status': 'idle'},
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
        ],
        'agents': [],
      });
      client.setSnapshotForTesting(snap);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('History and recent commands'));
      await tester.pumpAndSettle();

      expect(find.text('Recent messages'), findsOneWidget);
      expect(find.text('fix bug in layout'), findsOneWidget);
      expect(find.text('run tests'), findsOneWidget);
      expect(find.text('/help'), findsOneWidget);
      expect(find.text('/clear'), findsOneWidget);
      expect(
        find.ancestor(of: find.text('/help'), matching: find.byType(SingleChildScrollView)),
        findsOneWidget,
      );

      // Swiping to dismiss a history item removes it from recent messages
      expect(find.text('fix bug in layout'), findsOneWidget);
      await tester.drag(find.text('fix bug in layout'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('fix bug in layout'), findsNothing);
      expect(find.text('run tests'), findsOneWidget);

      // Tapping a command sends it
      await tester.tap(find.text('/help'));
      await tester.pumpAndSettle();
      TerminalScreen.clearDraftsForTesting();
    });

    testWidgets('History prioritizes workspace-specific commands and messages', (tester) async {
      SharedPreferences.setMockInitialValues({
        'message_history': ['global message'],
        'message_history_w1': ['workspace message'],
        'recent_commands': ['/global'],
        'recent_commands_w1': ['/workspace_cmd'],
      });
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'main', 'active_tab_id': 'w1:t1', 'agent_status': 'idle'},
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
        ],
        'agents': [],
      });
      client.setSnapshotForTesting(snap);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('History and recent commands'));
      await tester.pumpAndSettle();

      expect(find.text('workspace message'), findsOneWidget);
      expect(find.text('global message'), findsOneWidget);
      expect(find.text('/workspace_cmd'), findsOneWidget);
      expect(find.text('/global'), findsOneWidget);
      TerminalScreen.clearDraftsForTesting();
    });

    testWidgets('Arrow Up/Down in message TextField navigates history', (tester) async {
      SharedPreferences.setMockInitialValues({'message_history': ['first command', 'second command']});
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'main', 'active_tab_id': 'w1:t1', 'agent_status': 'idle'},
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
        ],
        'agents': [],
      });
      client.setSnapshotForTesting(snap);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));

      final textField = find.byType(TextField);
      await tester.tap(textField);
      await tester.pump();

      // Press Arrow Up to get first history entry
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(find.text('first command'), findsOneWidget);

      // Press Arrow Up to get second history entry
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(find.text('second command'), findsOneWidget);

      // Press Arrow Down to go back to first history entry
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.text('first command'), findsOneWidget);

      // Press Arrow Down to go back to empty draft
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.text('first command'), findsNothing);
    });

    testWidgets('Ctrl+V with an empty clipboard pastes nothing', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'main', 'active_tab_id': 'w1:t1', 'agent_status': 'idle'},
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
        ],
        'agents': [],
      });
      client.setSnapshotForTesting(snap);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      // No text clipboard and (in tests) no connection: the field's own paste finds nothing,
      // and the image path bails before touching the clipboard tools. No error shows.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '', isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('Ctrl+V with clipboard text pastes the text once', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'hello'};
        return null;
      });
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'main', 'active_tab_id': 'w1:t1', 'agent_status': 'idle'},
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
        ],
        'agents': [],
      });
      client.setSnapshotForTesting(snap);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      // Text wins: the field pastes it, and the image path stands down (no @-reference, no error).
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, 'hello');
      expect(find.text('@'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('Shift+Enter in message TextField inserts newline, Enter sends message', (tester) async {
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'main', 'active_tab_id': 'w1:t1', 'agent_status': 'idle'},
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
        ],
        'agents': [],
      });
      client.setSnapshotForTesting(snap);
      client.setConnectedForTesting(client.machine, true);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));

      final textField = find.byType(TextField);
      await tester.tap(textField);
      await tester.enterText(textField, 'line 1');
      await tester.pump();

      // Press ShiftLeft + Enter to insert a newline
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      var editableText = tester.widget<EditableText>(find.byType(EditableText));
      expect(editableText.controller.text, equals('line 1\n'));

      // Type line 2
      await tester.enterText(textField, 'line 1\nline 2');
      await tester.pump();

      // Press ShiftRight + Enter to insert another newline
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftRight);
      await tester.pump();

      // Press Enter alone to insert a newline in message bar
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      editableText = tester.widget<EditableText>(find.byType(EditableText));
      expect(editableText.controller.text, equals('line 1\nline 2\n\n'));

      // Tapping the send button sends the message
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(const Duration(milliseconds: 200));

      editableText = tester.widget<EditableText>(find.byType(EditableText));
      expect(editableText.controller.text, equals(''));
    });

    testWidgets('TerminalView Shift+Enter sends newline', (tester) async {
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'main', 'active_tab_id': 'w1:t1', 'agent_status': 'idle'},
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
        ],
        'agents': [],
      });
      client.setSnapshotForTesting(snap);
      client.setConnectedForTesting(client.machine, true);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));

      final terminalView = find.byType(TerminalView);
      await tester.tap(terminalView);
      await tester.pump(const Duration(milliseconds: 350));
      // A tap never brings up the keys nor the keyboard: open the keys from their button.
      await tester.tap(find.byTooltip('Control keys'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump(const Duration(milliseconds: 350));

      // What xterm itself would type: Shift+Enter is the screen's newline, never xterm's Enter (\r).
      final typed = <String>[];
      tester.widget<TerminalView>(terminalView).terminal.onOutput = typed.add;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 350));
      expect(typed, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(typed, ['\r']);
    });

    testWidgets('Ctrl+C copies the terminal selection, and only without one does xterm see it', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));
      // The terminal's focus, as its keyboard button gives it. A pointer-down would gate that away
      // ([_gateKeyboard]), so the selection is made through the controller instead of a press.
      tester.state<TerminalViewState>(find.byType(TerminalView)).requestKeyboard();
      await tester.pump();

      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      final typed = <String>[];
      view.terminal.write('hello brave new world');
      await tester.pump();
      view.terminal.onOutput = typed.add;
      final buffer = view.terminal.buffer;
      view.controller!.setSelection(
        buffer.createAnchorFromOffset(const CellOffset(0, 0)),
        buffer.createAnchorFromOffset(const CellOffset(5, 0)),
      );
      await tester.pump();
      expect(find.text('Copy'), findsOneWidget);

      // Omarchy's Super+C arrives as a synthesized Ctrl+C: a selection copies, as in VS Code.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(copied, 'hello');
      expect(typed, isEmpty);

      // With nothing selected it stays xterm's interrupt.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(typed, ['\x03']);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets("Omarchy's Super+C never interrupts the pane", (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));
      tester.state<TerminalViewState>(find.byType(TerminalView)).requestKeyboard();
      await tester.pump();

      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      final typed = <String>[];
      view.terminal.write('hello brave new world');
      await tester.pump();
      view.terminal.onOutput = typed.add;

      // Omarchy's Super+C arrives as a Ctrl+C whose Control key event the desktop synthesized,
      // since no Control key was pressed. With nothing selected that must stay a no-op rather
      // than reaching the pane as an interrupt.
      await sendSynthesizedControl(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC, character: 'c');
      await tester.pump();
      expect(typed, isEmpty);

      // With a selection it copies, like the real Ctrl+C.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      final buffer = view.terminal.buffer;
      view.controller!.setSelection(
        buffer.createAnchorFromOffset(const CellOffset(0, 0)),
        buffer.createAnchorFromOffset(const CellOffset(5, 0)),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC, character: 'c');
      await tester.pump();
      expect(copied, 'hello');
      expect(typed, isEmpty);

      // A real Ctrl+C, whose own Control key is pressed, still interrupts.
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC, character: 'c');
      await tester.pump();
      expect(typed, ['\x03']);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Send button is not made larger when multiline', (tester) async {
      TerminalScreen.clearDraftsForTesting();
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'focused_workspace_id': 'w1',
        'focused_tab_id': 'w1:t1',
        'focused_pane_id': 'w1:p1',
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'main', 'active_tab_id': 'w1:t1', 'agent_status': 'idle'},
        ],
        'tabs': [
          {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
        ],
        'panes': [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
        ],
        'agents': [],
      });
      client.setSnapshotForTesting(snap);
      client.selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.pump(const Duration(milliseconds: 300));

      final textFieldFinder = find.byType(TextField);
      final sendButtonFinder = find.byTooltip('Enter');

      final initialSendButtonSize = tester.getSize(sendButtonFinder);

      // Enter multi-line text to make the message pill larger
      await tester.enterText(textFieldFinder, 'Line 1\nLine 2\nLine 3');
      await tester.pump();

      final multilineTextFieldSize = tester.getSize(textFieldFinder);
      final multilineSendButtonSize = tester.getSize(find.byTooltip('Send'));

      // Message pill grew larger, but send button did not grow
      expect(multilineTextFieldSize.height, greaterThan(initialSendButtonSize.height));
      expect(multilineSendButtonSize.height, equals(initialSendButtonSize.height));
    });

    test("herdr-core's terminals and the Herdr app's layout make the snapshot", () {
      const root = 'me@laptop';
      final client = HerdrClientService()..setMachines([root, '$root/m/vps'], []);
      Map term(String address, {String? state, String? app, int turn = 0, String cwd = '/home/me/proj', String? title}) => {
            'address': address,
            'state': 'live',
            'cwd': cwd,
            'title': title,
            'turn': turn,
            'status_ms': 1000,
            'status': state == null ? null : {'app': app ?? 'claude-code', 'state': state},
          };
      client.resetForTesting(root, [
        term('t1', state: 'working', title: 'Fixing the parser'),
        term('t2'),
        term('t3', state: 'blocked', app: 'opencode'), // a sub-agent, in no tab
        {...term('t4', state: 'done'), 'state': 'finished'},
        term('vps/t1', state: 'error', app: 'codex'),
      ], {
        'spaces': [
          {
            'id': 'spc1',
            'name': '',
            'folder': '/home/me/proj',
            'tabs': [
              {
                'id': 'tb1',
                'name': '',
                'root': {
                  'type': 'row',
                  'children': [
                    {'type': 'block', 'id': 'p1', 'content': {'terminal': 't1'}},
                    {'type': 'block', 'id': 'p2', 'content': {'terminal': 't2'}},
                  ],
                },
              },
              {'id': 'tb2', 'name': 'logs', 'root': {'type': 'block', 'id': 'p4', 'content': {'terminal': 't4'}}},
            ],
          },
        ],
      });
      final s = client.snapshotOf(root)!;
      // An unnamed space is named after where its first terminal is, as the Herdr app does.
      expect(s.workspaces.single.displayName, 'proj');
      expect(s.workspaces.single.agentStatus, 'working'); // its tabs' most urgent agent
      expect(s.tabs.map((t) => t.displayName), ['Tab 1', 'logs']);
      expect(s.panes.map((p) => p.id), ['t1', 't2', 't3']); // finished t4 is gone
      expect(s.panes.firstWhere((p) => p.id == 't3').tabId, '');
      expect(s.panes.first.terminalTitle, 'Fixing the parser');
      expect({for (final a in s.agents) a.paneId: '${a.name} ${a.status}'}, {'t1': 'claude working', 't3': 'opencode blocked'});
      expect(client.changedAt('t1', root), DateTime.fromMillisecondsSinceEpoch(1000));
      // A machine the root's core reaches has its own terminals, by their local address; an error needs you.
      expect(client.snapshotOf('$root/m/vps')!.agents.single.paneId, 't1');
      expect(client.snapshotOf('$root/m/vps')!.agents.single.status, 'blocked');

      // Events keep it live.
      client.handleNotificationForTesting(root, {
        'method': 'event',
        'params': {'type': 'status', 'terminal': 't1', 'data': {'status': {'app': 'claude-code', 'state': 'done'}, 'reported': true}},
      });
      expect(client.snapshotOf(root)!.agentOf('t1')!.status, 'done');
      expect(client.changedAt('t1', root)!.isAfter(DateTime.fromMillisecondsSinceEpoch(1000)), isTrue);
      client.handleNotificationForTesting(root, {
        'method': 'event',
        'params': {'type': 'finished', 'terminal': 'vps/t1', 'data': {'reason': 'exited'}},
      });
      expect(client.snapshotOf('$root/m/vps')!.agents, isEmpty);
      client.handleNotificationForTesting(root, {
        'method': 'event',
        'params': {'type': 'created', 'terminal': 't9', 'data': term('t9', state: 'idle', app: 'pi')},
      });
      expect(client.snapshotOf(root)!.agentOf('t9')!.name, 'pi');
      client.handleNotificationForTesting(root, {'method': 'missed', 'params': {'seq': 9, 'terminals': [term('t1')]}});
      expect(client.snapshotOf(root)!.agents, isEmpty);
      expect(client.snapshotOf(root)!.panes.map((p) => p.id), ['t1']);
    });

    test("An agent's finished turn alerts once", () {
      const root = 'me@laptop';
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('herdr/android'), (c) async {
        calls.add(c);
        return null;
      });
      final client = HerdrClientService()
        ..setMachines([root], [])
        ..setAlerts(true, ask: false);
      Map term(int turn, String state) => {
            'address': 't1',
            'state': 'live',
            'cwd': '/w',
            'turn': turn,
            'status': {'app': 'claude-code', 'state': state},
          };
      client.resetForTesting(root, [term(3, 'working')]);
      for (final (turn, state) in [(4, 'idle'), (4, 'idle'), (4, 'working')]) {
        client.handleNotificationForTesting(root, {
          'method': 'event',
          'params': {'type': 'turn', 'terminal': 't1', 'data': {'turn': turn, 'state': state}},
        });
        client.handleNotificationForTesting(root, {
          'method': 'event',
          'params': {'type': 'status', 'terminal': 't1', 'data': {'status': {'app': 'claude-code', 'state': state}}},
        });
      }
      final alerts = calls.where((c) => c.method == 'alert').toList();
      expect(alerts.length, 1);
      expect(alerts.single.arguments['title'], 'Claude finished');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('herdr/android'), null);
    });

    test('HerdrClientService tab and workspace navigation and jumpToAttention', () {
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'ws1', 'active_tab_id': 't1', 'agent_status': 'idle'},
          {'workspace_id': 'w2', 'number': 2, 'label': 'ws2', 'active_tab_id': 't3', 'agent_status': 'blocked'},
        ],
        'tabs': [
          {'tab_id': 't1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
          {'tab_id': 't2', 'workspace_id': 'w1', 'number': 2, 'label': 'Tab 2', 'agent_status': 'idle'},
          {'tab_id': 't3', 'workspace_id': 'w2', 'number': 1, 'label': 'Tab 3', 'agent_status': 'blocked'},
        ],
        'panes': [
          {'pane_id': 'p1', 'workspace_id': 'w1', 'tab_id': 't1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
          {'pane_id': 'p2', 'workspace_id': 'w1', 'tab_id': 't2', 'focused': false, 'agent_status': 'idle', 'terminal_title': ''},
          {'pane_id': 'p3', 'workspace_id': 'w2', 'tab_id': 't3', 'focused': true, 'agent_status': 'blocked', 'terminal_title': ''},
        ],
        'agents': [
          {'pane_id': 'p1', 'name': 'agent1', 'status': 'idle'},
          {'pane_id': 'p3', 'name': 'agent3', 'status': 'blocked'},
        ],
      });
      client.setMachines(['127.0.0.1:7788'], []);
      client.setSnapshotForTesting(snap);
      client.selectPane('p1');

      // Tab navigation
      expect(client.selectedPaneId, 'p1');
      client.nextTab();
      expect(client.selectedPaneId, 'p2');
      client.previousTab();
      expect(client.selectedPaneId, 'p1');
      client.selectTabAt(1);
      expect(client.selectedPaneId, 'p2');

      // Workspace selection
      client.selectWorkspace('w2');
      expect(client.selectedPaneId, 'p3');
      client.selectWorkspace('w1');
      expect(client.selectedPaneId, 'p1');

      // Attention jump
      client.jumpToAttention();
      expect(client.selectedPaneId, 'p3');
    });

    test('HerdrClientService agentRows and stepAgent follow agent page order', () {
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'ws1', 'active_tab_id': 't1', 'agent_status': 'idle'},
        ],
        'tabs': [
          {'tab_id': 't1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
        ],
        'panes': [
          {'pane_id': 'p_done', 'workspace_id': 'w1', 'tab_id': 't1', 'focused': false, 'agent_status': 'done', 'terminal_title': ''},
          {'pane_id': 'p_blocked', 'workspace_id': 'w1', 'tab_id': 't1', 'focused': false, 'agent_status': 'blocked', 'terminal_title': ''},
          {'pane_id': 'p_working', 'workspace_id': 'w1', 'tab_id': 't1', 'focused': false, 'agent_status': 'working', 'terminal_title': ''},
        ],
        'agents': [
          {'pane_id': 'p_done', 'name': 'agent_done', 'status': 'done'},
          {'pane_id': 'p_blocked', 'name': 'agent_blocked', 'status': 'blocked'},
          {'pane_id': 'p_working', 'name': 'agent_working', 'status': 'working'},
        ],
      });
      client.setMachines(['127.0.0.1:7788'], []);
      client.setSnapshotForTesting(snap);

      // Order on agent page must be: blocked, working, done
      final rows = client.agentRows();
      expect(rows.map((r) => r.$3.paneId).toList(), ['p_blocked', 'p_working', 'p_done']);

      // Stepping forward (down the list)
      client.selectPane('p_blocked');
      client.stepAgent(1);
      expect(client.selectedPaneId, 'p_working');
      client.stepAgent(1);
      expect(client.selectedPaneId, 'p_done');
      client.stepAgent(1);
      expect(client.selectedPaneId, 'p_blocked');

      // Stepping backward (up the list)
      client.stepAgent(-1);
      expect(client.selectedPaneId, 'p_done');
      client.stepAgent(-1);
      expect(client.selectedPaneId, 'p_working');
      client.stepAgent(-1);
      expect(client.selectedPaneId, 'p_blocked');
    });

    testWidgets('TerminalScreen responds to Alt keybindings', (tester) async {
      final client = HerdrClientService();
      final snap = SessionSnapshot.fromJson({
        'workspaces': [
          {'workspace_id': 'w1', 'number': 1, 'label': 'ws1', 'active_tab_id': 't1', 'agent_status': 'idle'},
          {'workspace_id': 'w2', 'number': 2, 'label': 'ws2', 'active_tab_id': 't3', 'agent_status': 'blocked'},
        ],
        'tabs': [
          {'tab_id': 't1', 'workspace_id': 'w1', 'number': 1, 'label': 'Tab 1', 'agent_status': 'idle'},
          {'tab_id': 't2', 'workspace_id': 'w1', 'number': 2, 'label': 'Tab 2', 'agent_status': 'idle'},
          {'tab_id': 't3', 'workspace_id': 'w2', 'number': 1, 'label': 'Tab 3', 'agent_status': 'blocked'},
        ],
        'panes': [
          {'pane_id': 'p1', 'workspace_id': 'w1', 'tab_id': 't1', 'focused': true, 'agent_status': 'idle', 'terminal_title': ''},
          {'pane_id': 'p2', 'workspace_id': 'w1', 'tab_id': 't2', 'focused': false, 'agent_status': 'idle', 'terminal_title': ''},
          {'pane_id': 'p3', 'workspace_id': 'w2', 'tab_id': 't3', 'focused': true, 'agent_status': 'blocked', 'terminal_title': ''},
        ],
        'agents': [
          {'pane_id': 'p1', 'name': 'agent1', 'status': 'idle'},
          {'pane_id': 'p3', 'name': 'agent3', 'status': 'blocked'},
        ],
      });
      client.setMachines(['127.0.0.1:7788'], []);
      client.setSnapshotForTesting(snap);
      client.setConnectedForTesting('127.0.0.1:7788', true);
      client.selectPane('p1');

      var searchOpened = false;
      var drawerOpened = false;
      var machinesOpened = false;

      await tester.pumpWidget(MaterialApp(
        home: TerminalScreen(
          client: client,
          embedded: true,
          onOpenSearch: () => searchOpened = true,
          onOpenDrawer: () => drawerOpened = true,
          onOpenMachines: () => machinesOpened = true,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // Alt + Right -> next tab
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(client.selectedPaneId, 'p2');

      // Alt + Left -> previous tab
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(client.selectedPaneId, 'p1');

      // Alt + 2 -> tab 2
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(client.selectedPaneId, 'p2');

      // Alt + Down -> next agent (from a plain shell, the first one on the agents page)
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(client.selectedPaneId, 'p3');

      // Alt + Up -> previous agent, wrapping around to the last one
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(client.selectedPaneId, 'p1');

      // Alt + O -> jump to attention
      client.selectPane('p1');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(client.selectedPaneId, 'p3');

      // Alt + G -> search callback
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(searchOpened, isTrue);

      // Alt + B -> drawer callback
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(drawerOpened, isTrue);

      // Tapping the workspace's name (with its branch under it) opens it too.
      drawerOpened = false;
      await tester.tap(find.text('ws2'));
      await tester.pump();
      expect(drawerOpened, isTrue);

      // Alt + M -> machines callback
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(machinesOpened, isTrue);

      // Alt + I -> toggle message focus
      final textField = find.byType(TextField);
      expect(tester.widget<TextField>(textField).focusNode?.hasFocus, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(tester.widget<TextField>(textField).focusNode?.hasFocus, isTrue);

      // Alt + N and Alt + T -> create tab
      String? lastError;
      client.onError = (e) => lastError = e;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(lastError, contains('create tab'));

      lastError = null;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(lastError, contains('create tab'));
    });

    testWidgets('Tapping an agent notification opens TerminalScreen, but general notification does not', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      const m = '100.1.2.3:7788';
      final client = HerdrClientService()
        ..setMachines([m], [])
        ..switchMachine(m)
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');

      await tester.pumpWidget(MaterialApp(home: AgentsHomeScreen(client: client)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(TerminalScreen), findsNothing);

      // 1. General notification (empty pane or null): does not open terminal
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'herdr/android',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('open', {'machine': m, 'pane': ''})),
        (data) {},
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(TerminalScreen), findsNothing);

      // 2. Agent notification (has pane): opens terminal view for that agent
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'herdr/android',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('open', {'machine': m, 'pane': 'w2:p4'})),
        (data) {},
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(TerminalScreen), findsOneWidget);
      expect(client.selectedPaneId, 'w2:p4');
    });
  });
  testWidgets('Fast typing into the terminal sends each character once', (tester) async {
    // Voxtype types through wtype a character a millisecond, faster than the input method takes a reset,
    // so its text keeps growing: each update must send only what is new, and a correction backspaces.
    final terminal = Terminal();
    final out = StringBuffer();
    terminal.onOutput = out.write;
    final focus = FocusNode();
    await tester.pumpWidget(MaterialApp(home: TerminalView(terminal, focusNode: focus, autofocus: true)));
    await tester.pump();
    for (final text in ['p', 'pr', 'pro', 'prob', 'probl', 'proble', 'problem', 'problems', 'problem']) {
      tester.testTextInput.updateEditingValue(TextEditingValue(text: text));
    }
    expect(out.toString(), 'problems\x7f');
    focus.dispose();
  });
}

class _RecordingClient extends HerdrClientService {
  String? addedBridge;
  String? addedTarget;
  String? addedName;

  @override
  Future<bool> addSshMachine(String bridge, String target, String name) async {
    addedBridge = bridge;
    addedTarget = target;
    addedName = name;
    return true;
  }
}

