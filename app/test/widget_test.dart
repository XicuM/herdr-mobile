import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/models/session.dart';
import 'package:herdr_mobile/models/agent_status.dart';
import 'package:herdr_mobile/services/herdr_client.dart';
import 'package:herdr_mobile/ui/widgets/workspace_drawer.dart';
import 'package:herdr_mobile/changelog.dart';
import 'package:herdr_mobile/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:herdr_mobile/ui/screens/terminal_screen.dart';
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

    test('AgentStatus enum mapping works', () {
      expect(AgentStatus.fromString('blocked'), equals(AgentStatus.blocked));
      expect(AgentStatus.fromString('working'), equals(AgentStatus.working));
      expect(AgentStatus.fromString('done'), equals(AgentStatus.done));
      expect(AgentStatus.fromString('idle'), equals(AgentStatus.idle));
      expect(AgentStatus.fromString('random'), equals(AgentStatus.unknown));
    });

    testWidgets('WorkspaceDrawer long press shows workspace actions', (tester) async {
      final client = HerdrClientService();
      final snapshot = SessionSnapshot.fromJson({
        'version': '0.9.3',
        'protocol': 22,
        'workspaces': [
          {
            'workspace_id': 'w1',
            'number': 1,
            'label': 'my-workspace',
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
            'workspace_id': 'w1',
            'tab_id': 'w1:t1',
            'focused': true,
            'cwd': '/home/xicu',
            'agent_status': 'unknown',
          }
        ],
        'agents': [],
      });

      client.setSnapshotForTesting(snapshot);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            drawer: WorkspaceDrawer(client: client),
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => Scaffold.of(context).openDrawer(),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      // Open drawer
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Drawer is open and displays workspace
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('my-workspace'), findsOneWidget);

      // Long press workspace row
      await tester.longPress(find.text('my-workspace'));
      await tester.pumpAndSettle();

      // Bottom sheet displays workspace actions
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('New worktree'), findsOneWidget);
      expect(find.text('Open worktree'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
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

    testWidgets('WorkspaceDrawer does not show redundant machines section', (tester) async {
      final client = HerdrClientService();
      client.setMachines(['100.1.2.3:7788', '100.1.2.4:7788'], []);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            drawer: WorkspaceDrawer(client: client),
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => Scaffold.of(context).openDrawer(),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Drawer shows workspaces, but not a duplicate machines section
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('machines'), findsNothing);
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

    Future<HerdrClientService> openDrawer(WidgetTester tester) async {
      final client = HerdrClientService()
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          drawer: WorkspaceDrawer(client: client),
          body: Builder(
            builder: (context) =>
                ElevatedButton(onPressed: () => Scaffold.of(context).openDrawer(), child: const Text('Open')),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      return client;
    }

    testWidgets('Drawer lists workspaces but not tabs', (tester) async {
      final client = await openDrawer(tester);
      expect(find.text('api'), findsNothing);
      expect(find.text('db'), findsNothing);
      expect(find.text('backend'), findsOneWidget);
      expect(find.text('coder'), findsNothing); // agents have their own sheet
      await tester.tap(find.text('frontend').first);
      await tester.pumpAndSettle();
      expect(client.selectedPaneId, 'w2:p4');
    });

    testWidgets('The agents button lists waiting agents first, and tapping one shows its pane', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      expect(
          find.descendant(of: find.byType(Badge), matching: find.text('1')), findsOneWidget); // ui; coder is on screen
      expect(find.descendant(of: find.byTooltip('Agents'), matching: find.text('3')), findsOneWidget); // all agents

      await tester.tap(find.byTooltip('Agents'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // the Connecting spinner never settles
      Finder inSheet(String t) => find.descendant(of: find.byType(BottomSheet), matching: find.text(t));
      double y(Finder f) => tester.getTopLeft(f).dy;
      expect(y(inSheet('coder')), lessThan(y(inSheet('helper'))));
      expect(y(inSheet('ui')), lessThan(y(inSheet('helper'))));
      expect(inSheet('frontend · Tab 1'), findsOneWidget);

      await tester.tap(inSheet('ui'));
      await tester.pump();
      expect(client.selectedPaneId, 'w2:p4');
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
            for (var n = 0; n < 12; n++) {'pane_id': 'w1:p$n', 'workspace_id': 'w1', 'tab_id': 'w1:t$n', 'focused': n == 0}
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

    testWidgets('Long-pressing a tab renames it; dragging one turns the new-tab button into a bin', (tester) async {
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

      // Long-pressed and let go in place: rename.
      await tester.longPress(tab);
      await settle();
      expect(find.text('Rename tab'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle();
      expect(find.text('Rename tab'), findsNothing);

      // While dragged, the new-tab button is a bin; a tab that moved isn't renamed.
      expect(find.byTooltip('New tab'), findsOneWidget);
      final drag = await tester.startGesture(tester.getCenter(tab));
      await tester.pump(const Duration(seconds: 1));
      await drag.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(find.byTooltip('Close tab'), findsOneWidget);
      await drag.moveBy(const Offset(40, 0));
      await drag.up();
      await settle();
      expect(find.byTooltip('New tab'), findsOneWidget);
      expect(find.text('Rename tab'), findsNothing);
    });

    testWidgets('The top bar shows the workspace and its tabs; tapping a tab shows it', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));

      // The workspace and its tabs, like a browser's, each with its agents.
      Finder inBar(String t) => find.descendant(of: find.byType(AppBar), matching: find.text(t));
      expect(inBar('backend'), findsOneWidget);
      expect(inBar('backend-branch'), findsOneWidget);
      expect(inBar('api · helper · coder'), findsOneWidget);
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

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pump(const Duration(seconds: 1)); // the Connecting spinner never settles
      expect(find.text('Workspaces'), findsOneWidget);
    });

    test('Editing a machine renames it and moves it in place', () {
      final client = HerdrClientService()..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], ['10.0.0.1:7788=old']);
      client.updateMachine('10.0.0.1:7788', host: 'laptop', port: 9000, name: 'work');
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
        ..configure(host: '10.0.0.1', port: 7788, connect: false);
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

    testWidgets('The workspace drawer lists the machines to connect or disconnect each', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], ['10.0.0.1:7788=laptop'], ['10.0.0.2:7788'])
        ..configure(host: '10.0.0.1', port: 7788, connect: false);
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Machines'), findsOneWidget);
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(2));

      await tester.tap(find.byType(Switch).last); // connect the second, keep the first on screen
      await tester.pump();
      expect(client.isOff('10.0.0.2:7788'), isFalse);
      expect(client.machine, '10.0.0.1:7788');
    });

    test('Removing the machine on screen shows the next one without connecting it', () {
      SharedPreferences.setMockInitialValues({});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], [], ['10.0.0.2:7788'])
        ..configure(host: '10.0.0.1', port: 7788, connect: false);
      client.removeMachine('10.0.0.1:7788');
      expect(client.machine, '10.0.0.2:7788');
      expect(client.isOff('10.0.0.2:7788'), isTrue);
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

    testWidgets('AgentsHomeScreen displays machines, agents sorted by urgency, and opens terminal on tap',
        (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788'], [])
        ..configure(host: '10.0.0.1', port: 7788, connect: false);

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

      // Top bar title
      expect(find.text('Agents'), findsOneWidget);

      // Blocked agent appears and shows NEEDS INPUT badge
      expect(find.text('antigravity'), findsOneWidget);
      expect(find.text('NEEDS INPUT'), findsOneWidget);
      expect(find.text('claude'), findsOneWidget);

      // Tap on antigravity agent opens the terminal screen
      await tester.tap(find.text('antigravity'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(client.selectedPaneId, equals('w1:p2'));
      // Back button appears in TerminalScreen
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      // Tapping back returns to AgentsHomeScreen
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Agents'), findsOneWidget);
    });
  });
}
