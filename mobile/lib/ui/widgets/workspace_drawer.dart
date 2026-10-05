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
    VoidCallback? onLongPress,
  }) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
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
                onLongPress: () => _showWorkspaceActions(context, ws),
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

  void _showWorkspaceActions(BuildContext context, WorkspaceModel ws) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2127),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ws.displayName,
                    style: const TextStyle(fontFamily: _mono, fontSize: 15, fontWeight: FontWeight.bold, color: _text),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (ws.gitBranch != null)
                    Text(
                      ws.gitBranch!,
                      style: const TextStyle(fontFamily: _mono, fontSize: 12, color: _dim),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: _text, size: 20),
              title: const Text('Rename', style: TextStyle(fontFamily: _mono, fontSize: 13, color: _text)),
              onTap: () {
                Navigator.pop(sheetContext);
                _showRenameDialog(context, ws);
              },
            ),
            ListTile(
              leading: const Icon(Icons.call_split, color: _text, size: 20),
              title: const Text('New worktree', style: TextStyle(fontFamily: _mono, fontSize: 13, color: _text)),
              onTap: () {
                Navigator.pop(sheetContext);
                _showNewWorktreeDialog(context, ws);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined, color: _text, size: 20),
              title: const Text('Open worktree', style: TextStyle(fontFamily: _mono, fontSize: 13, color: _text)),
              onTap: () {
                Navigator.pop(sheetContext);
                _showOpenWorktreeDialog(context, ws);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
              title: const Text('Delete', style: TextStyle(fontFamily: _mono, fontSize: 13, color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(sheetContext);
                _showDeleteDialog(context, ws);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, WorkspaceModel ws) {
    final controller = TextEditingController(text: ws.label.isNotEmpty ? ws.label : ws.displayName);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename Workspace', style: TextStyle(fontFamily: _mono, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontFamily: _mono, fontSize: 13, color: _text),
          decoration: const InputDecoration(
            labelText: 'Workspace name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (val) {
            final trimmed = val.trim();
            if (trimmed.isNotEmpty) {
              client.renameWorkspace(ws.id, trimmed);
            }
            Navigator.pop(dialogContext);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(fontFamily: _mono, color: _dim)),
          ),
          TextButton(
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isNotEmpty) {
                client.renameWorkspace(ws.id, trimmed);
              }
              Navigator.pop(dialogContext);
            },
            child: const Text('Rename', style: TextStyle(fontFamily: _mono)),
          ),
        ],
      ),
    );
  }

  void _showNewWorktreeDialog(BuildContext context, WorkspaceModel ws) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New Worktree', style: TextStyle(fontFamily: _mono, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontFamily: _mono, fontSize: 13, color: _text),
          decoration: const InputDecoration(
            labelText: 'Branch name',
            hintText: 'e.g. feat/my-feature',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (val) {
            final trimmed = val.trim();
            if (trimmed.isNotEmpty) {
              client.createWorktree(ws.id, trimmed);
              Navigator.pop(dialogContext);
              Navigator.pop(context);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(fontFamily: _mono, color: _dim)),
          ),
          TextButton(
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isNotEmpty) {
                client.createWorktree(ws.id, trimmed);
                Navigator.pop(dialogContext);
                Navigator.pop(context);
              }
            },
            child: const Text('Create', style: TextStyle(fontFamily: _mono)),
          ),
        ],
      ),
    );
  }

  void _showOpenWorktreeDialog(BuildContext context, WorkspaceModel ws) {
    showDialog(
      context: context,
      builder: (dialogContext) => FutureBuilder<List<Map<String, dynamic>>>(
        future: client.listWorktrees(ws.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const AlertDialog(
              title: Text('Worktrees', style: TextStyle(fontFamily: _mono, fontSize: 16)),
              content: SizedBox(
                height: 100,
                child: Center(child: CircularProgressIndicator()),
              ),
            );
          }
          final list = snapshot.data ?? [];
          if (list.isEmpty) {
            return AlertDialog(
              title: const Text('Worktrees', style: TextStyle(fontFamily: _mono, fontSize: 16)),
              content: const Text('No worktrees found for this repository.',
                  style: TextStyle(fontFamily: _mono, fontSize: 13, color: _dim)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('OK', style: TextStyle(fontFamily: _mono)),
                ),
              ],
            );
          }
          return AlertDialog(
            title: const Text('Open Worktree', style: TextStyle(fontFamily: _mono, fontSize: 16)),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                itemBuilder: (context, index) {
                  final wt = list[index];
                  final branch = wt['branch']?.toString() ?? wt['label']?.toString() ?? 'unknown';
                  final openWsId = wt['open_workspace_id'];
                  final isOpen = openWsId != null;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.call_split, size: 18, color: _dim),
                    title: Text(
                      branch,
                      style: TextStyle(
                        fontFamily: _mono,
                        fontSize: 13,
                        color: isOpen ? Colors.white70 : _text,
                        fontWeight: isOpen ? FontWeight.normal : FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      isOpen ? 'already open' : (wt['path']?.toString() ?? ''),
                      style: const TextStyle(fontFamily: _mono, fontSize: 11, color: _dim),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: isOpen ? const Icon(Icons.check, size: 16, color: Colors.greenAccent) : null,
                    onTap: () {
                      Navigator.pop(dialogContext);
                      Navigator.pop(context);
                      if (isOpen) {
                        final targetWs = client.snapshot?.workspaces.where((w) => w.id == openWsId).firstOrNull;
                        if (targetWs != null) {
                          final panes = client.snapshot!.panes.where((p) => p.workspaceId == targetWs.id);
                          final pane = panes.where((p) => p.tabId == targetWs.activeTabId && p.focused).firstOrNull ??
                              panes.where((p) => p.tabId == targetWs.activeTabId).firstOrNull ??
                              panes.firstOrNull;
                          if (pane != null) client.selectPane(pane.id);
                        }
                      } else {
                        client.openWorktree(
                          ws.id,
                          branch: wt['branch']?.toString(),
                          path: wt['path']?.toString(),
                        );
                      }
                    },
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel', style: TextStyle(fontFamily: _mono, color: _dim)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, WorkspaceModel ws) {
    final isLinked = ws.isLinkedWorktree;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isLinked ? 'Delete Worktree' : 'Delete Workspace',
            style: const TextStyle(fontFamily: _mono, fontSize: 16)),
        content: Text(
          isLinked
              ? 'Delete worktree "${ws.displayName}"?\nThis will remove the worktree checkout.'
              : 'Close workspace "${ws.displayName}"?',
          style: const TextStyle(fontFamily: _mono, fontSize: 13, color: _text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(fontFamily: _mono, color: _dim)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              client.deleteWorkspace(ws.id, removeWorktree: isLinked);
            },
            child: const Text('Delete', style: TextStyle(fontFamily: _mono, color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
