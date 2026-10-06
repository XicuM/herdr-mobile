import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/models/session.dart';
import 'package:herdr_mobile/models/agent_status.dart';
import 'package:herdr_mobile/services/herdr_client.dart';
import 'package:herdr_mobile/ui/widgets/workspace_drawer.dart';
import 'package:herdr_mobile/changelog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:herdr_mobile/ui/screens/terminal_screen.dart';

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
      expect(snapshot.version, equals('0.9.3'));
      expect(snapshot.workspaces.length, equals(1));
      expect(snapshot.panes.length, equals(1));
      expect(snapshot.panes.first.id, equals('w1:p1'));
      expect(snapshot.agents.first.name, equals('indexer'));
      expect(snapshot.agents.first.status, equals('working'));
    });

    test('AgentStatus enum mapping works', () {
      expect(AgentStatusExtension.fromString('blocked'), equals(AgentStatus.blocked));
      expect(AgentStatusExtension.fromString('working'), equals(AgentStatus.working));
      expect(AgentStatusExtension.fromString('done'), equals(AgentStatus.done));
      expect(AgentStatusExtension.fromString('idle'), equals(AgentStatus.idle));
      expect(AgentStatusExtension.fromString('random'), equals(AgentStatus.unknown));
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
    SessionSnapshot twoWorkspaces({String focusedPane = 'w1:p1'}) {
      Map<String, dynamic> ws(String id, String label, int tabs, String active) => {
            'workspace_id': id, 'number': 1, 'label': label, 'focused': false, 'pane_count': 1,
            'tab_count': tabs, 'active_tab_id': active, 'agent_status': 'blocked', 'git_branch': '$label-branch',
          };
      Map<String, dynamic> tab(String id, String ws, int n, String label) => {
            'tab_id': id, 'workspace_id': ws, 'number': n, 'label': label, 'focused': false,
            'pane_count': 1, 'agent_status': 'blocked',
          };
      // Like herdr: only one pane in the whole session is focused.
      Map<String, dynamic> pane(String id, String ws, String tab, String status) => {
            'pane_id': id, 'workspace_id': ws, 'tab_id': tab, 'focused': id == focusedPane, 'cwd': '/',
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
            builder: (context) => ElevatedButton(onPressed: () => Scaffold.of(context).openDrawer(), child: const Text('Open')),
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
      expect(find.descendant(of: find.byType(Badge), matching: find.text('1')), findsOneWidget); // ui; coder is on screen
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

    testWidgets('Swiping up on the message bar lists the workspace\'s tabs and split panes, with new, rename and close buttons', (tester) async {
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

      Finder inSheet(String text) => find.descendant(of: find.byType(BottomSheet), matching: find.text(text));
      await tester.timedDrag(find.byType(TextField), const Offset(0, -150), const Duration(milliseconds: 200));
      await settle();
      expect(find.text('New tab'), findsOneWidget);
      expect(inSheet('api · coder'), findsOneWidget);
      expect(inSheet('db'), findsOneWidget); // no agent
      expect(inSheet('db'), findsOneWidget);
      expect(inSheet('helper'), findsOneWidget); // split pane of the current tab

      expect(find.byTooltip('Rename tab'), findsNWidgets(2));
      expect(find.byTooltip('Close tab'), findsNWidgets(2));

      await tester.tap(inSheet('db'));
      await settle();
      expect(client.selectedPaneId, 'w1:p3');
    });

    testWidgets('Title opens the drawer', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p1');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));

      // The workspace, with its branch underneath; no tab or agent names.
      Finder inBar(String t) => find.descendant(of: find.byType(AppBar), matching: find.text(t));
      expect(inBar('backend'), findsOneWidget);
      expect(inBar('backend-branch'), findsOneWidget);
      expect(inBar('coder'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(inBar('backend'));
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

    testWidgets('Swiping the message bar slides to the neighbouring tab', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces())
        ..selectPane('w1:p3'); // tab "db", the second of backend's two
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      Future<void> swipe(double dx) async {
        await tester.timedDrag(find.byType(TextField), Offset(dx, 0), const Duration(milliseconds: 200));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await swipe(300); // right: back to "api"
      expect(client.selectedPaneId, 'w1:p1');
      await swipe(300); // right again: nothing before the first tab
      expect(client.selectedPaneId, 'w1:p1');
      await swipe(-300); // left: forward to "db"
      expect(client.selectedPaneId, 'w1:p3');
    });

    testWidgets('Tabs sheet names the agent of a tab whose panes herdr does not focus', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['100.1.2.3:7788'], [])
        ..setSnapshotForTesting(twoWorkspaces(focusedPane: 'w1:p3'))
        ..selectPane('w1:p3');
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));
      await tester.timedDrag(find.byType(TextField), const Offset(0, -150), const Duration(milliseconds: 200));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final inSheet = find.descendant(of: find.byType(BottomSheet), matching: find.textContaining('api · '));
      expect(inSheet, findsOneWidget);
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
    });

    testWidgets('The machine chip opens a panel to connect or disconnect each machine', (tester) async {
      SharedPreferences.setMockInitialValues({'last_seen_changelog': changelog.first.$1});
      final client = HerdrClientService()
        ..setMachines(['10.0.0.1:7788', '10.0.0.2:7788'], ['10.0.0.1:7788=laptop'], ['10.0.0.2:7788'])
        ..configure(host: '10.0.0.1', port: 7788, connect: false);
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(client: client)));

      await tester.tap(find.widgetWithText(ActionChip, 'laptop'));
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
  });
}
