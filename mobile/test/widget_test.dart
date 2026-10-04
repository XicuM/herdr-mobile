import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/models/session.dart';
import 'package:herdr_mobile/models/agent_status.dart';

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
  });
}
