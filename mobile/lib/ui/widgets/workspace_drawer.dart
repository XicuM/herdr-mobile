import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/herdr_client.dart';
import '../screens/settings_screen.dart';

const _mono = 'MesloLGS Nerd Font Mono';
const _dim = Color(0xFF7A7F8A);
const _text = Color(0xFFD8DEE9);
const _selected = Color(0xFF3A3D45);

/// Compact sidebar modelled on Herdr's own: workspaces, then agents.
class WorkspaceDrawer extends StatelessWidget {
  final HerdrClientService client;

  const WorkspaceDrawer({super.key, required this.client});

  /// Herdr-style status glyph: `·` no agent, `○` idle, `●` coloured otherwise.
  static Widget _glyph(String status) {
    final s = AgentStatusExtension.fromString(status);
    return SizedBox(
      width: 18,
      child: Text(
        s == AgentStatus.unknown ? '·' : (s == AgentStatus.idle ? '○' : '●'),
        style: TextStyle(fontFamily: _mono, fontSize: 13, color: s == AgentStatus.unknown ? _dim : s.color),
      ),
    );
  }

  static Widget _header(String title, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        child: Row(
          children: [
            Text(title,
                style: const TextStyle(fontFamily: _mono, fontSize: 13, color: _dim, fontWeight: FontWeight.bold)),
            const Spacer(),
            if (trailing != null) trailing,
          ],
        ),
      );

  Widget _row({
    String? tree,
    required String status,
    required List<InlineSpan> spans,
    String? subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? _selected : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (tree != null) Text(tree, style: const TextStyle(fontFamily: _mono, fontSize: 13, color: _dim)),
                _glyph(status),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: spans),
                    style: const TextStyle(fontFamily: _mono, fontSize: 13, color: _text),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: Text(
                  subtitle,
                  style: const TextStyle(fontFamily: _mono, fontSize: 12, color: _dim),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = client.snapshot;
    final selectedPane = snapshot?.panes.where((p) => p.id == client.selectedPaneId).firstOrNull;

    void select(String paneId) {
      client.selectPane(paneId);
      Navigator.pop(context);
    }

    void selectWorkspace(WorkspaceModel ws) {
      final panes = snapshot!.panes.where((p) => p.workspaceId == ws.id);
      final pane = panes.where((p) => p.tabId == ws.activeTabId && p.focused).firstOrNull ??
          panes.where((p) => p.tabId == ws.activeTabId).firstOrNull ??
          panes.firstOrNull;
      if (pane != null) select(pane.id);
    }

    // Herdr's order: each workspace, with its linked worktrees nested right after it.
    final workspaces = snapshot?.workspaces ?? <WorkspaceModel>[];
    final parentKeys = {
      for (final w in workspaces)
        if (!w.isLinkedWorktree && w.repoKey != null) w.repoKey
    };
    final rows = <(WorkspaceModel, String?)>[];
    for (final w in workspaces) {
      if (w.isLinkedWorktree && parentKeys.contains(w.repoKey)) continue;
      rows.add((w, null));
      if (w.isLinkedWorktree || w.repoKey == null) continue;
      final children = workspaces.where((c) => c.isLinkedWorktree && c.repoKey == w.repoKey).toList();
      for (final c in children) {
        rows.add((c, c == children.last ? '└─ ' : '├─ '));
      }
    }

    final paneById = {for (final p in snapshot?.panes ?? <PaneModel>[]) p.id: p};
    final tabNumber = {for (final t in snapshot?.tabs ?? <TabModel>[]) t.id: t.number};
    final wsLabel = {for (final w in workspaces) w.id: w.displayName};

    return Drawer(
      width: 260,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            if (client.machines.length > 1) ...[
              _header('machines'),
              for (final m in client.machines)
                InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    if (m != client.machine) client.switchMachine(m);
                  },
                  child: Container(
                    color: m == client.machine ? _selected : null,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Text(client.nameOf(m),
                        style: const TextStyle(fontFamily: _mono, fontSize: 13, color: _text),
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
              const Divider(color: Colors.white12, height: 20),
            ],
            _header(
              'workspaces',
              trailing: Text(
                client.connected ? '●' : '○',
                style: TextStyle(fontSize: 11, color: client.connected ? Colors.greenAccent : Colors.redAccent),
              ),
            ),
            if (snapshot == null)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 3),
                child: Text('connecting…', style: TextStyle(fontFamily: _mono, fontSize: 13, color: _dim)),
              ),
            for (final (ws, tree) in rows)
              _row(
                tree: tree,
                status: ws.agentStatus,
                spans: [
                  TextSpan(
                    text: ws.displayName,
                    style: TextStyle(fontWeight: tree == null ? FontWeight.bold : FontWeight.normal),
                  ),
                  if (ws.tabCount > 1) TextSpan(text: ' · ${ws.tabCount}', style: const TextStyle(color: _dim)),
                ],
                subtitle: tree == null ? ws.gitBranch : null,
                selected: ws.id == selectedPane?.workspaceId,
                onTap: () => selectWorkspace(ws),
              ),
            Row(
              children: [
                InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    client.createWorkspace();
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Text('new', style: TextStyle(fontFamily: _mono, fontSize: 13, color: _dim)),
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(client: client)));
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Text('settings', style: TextStyle(fontFamily: _mono, fontSize: 13, color: _dim)),
                  ),
                ),
              ],
            ),
            if (snapshot != null && snapshot.agents.isNotEmpty) ...[
              const Divider(color: Colors.white12, height: 20),
              _header('agents'),
              for (final agent in snapshot.agents)
                _row(
                  status: agent.status,
                  spans: [
                    TextSpan(
                      text: wsLabel[paneById[agent.paneId]?.workspaceId] ?? '?',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    TextSpan(
                      text: ' · ${tabNumber[paneById[agent.paneId]?.tabId] ?? '?'}',
                      style: const TextStyle(color: _dim),
                    ),
                  ],
                  subtitle: agent.name,
                  selected: agent.paneId == client.selectedPaneId,
                  onTap: () => select(agent.paneId),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
