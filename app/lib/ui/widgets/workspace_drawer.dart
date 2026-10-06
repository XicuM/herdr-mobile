import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/herdr_client.dart';
import '../screens/settings_screen.dart';
import 'machine_drawer.dart';

/// A Material 3 navigation drawer modelled on Herdr's sidebar: workspaces, with linked worktrees
/// nested. Long-press a workspace for its actions; drag its handle to reorder it (with its worktrees).
/// The machines take the lower half, each half scrolling on its own, with Settings at the foot. Tabs live in the top bar, agents in [showAgentSheet].
class WorkspaceDrawer extends StatelessWidget {
  final HerdrClientService client;

  const WorkspaceDrawer({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final snapshot = client.snapshot;
    final selectedPane = client.selectedPane;

    void go(VoidCallback select) {
      select();
      Navigator.pop(context);
    }

    Widget row({
      Key? key,
      double indent = 0,
      required String status,
      required String title,
      String? subtitle,
      required bool selected,
      required VoidCallback onTap,
      VoidCallback? onLongPress,
      Widget? trailing,
    }) =>
        Padding(
          key: key,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListTile(
            contentPadding: EdgeInsets.only(left: 16 + indent, right: 16),
            visualDensity: VisualDensity.compact,
            selected: selected,
            leading: StatusDot(status),
            minLeadingWidth: 8,
            title: Text(title, overflow: TextOverflow.ellipsis),
            subtitle: subtitle == null ? null : Text(subtitle, overflow: TextOverflow.ellipsis),
            trailing: trailing,
            onTap: onTap,
            onLongPress: onLongPress,
          ),
        );

    // Herdr's order: each workspace, with its linked worktrees nested right after it.
    final workspaces = snapshot?.workspaces ?? <WorkspaceModel>[];
    final parentKeys = {
      for (final w in workspaces)
        if (!w.isLinkedWorktree && w.repoKey != null) w.repoKey
    };
    // One block per top-level workspace, so it is dragged together with its worktrees.
    final blocks = <List<WorkspaceModel>>[];
    for (final w in workspaces) {
      if (w.isLinkedWorktree && parentKeys.contains(w.repoKey)) continue;
      blocks.add([
        w,
        if (!w.isLinkedWorktree && w.repoKey != null)
          ...workspaces.where((c) => c.isLinkedWorktree && c.repoKey == w.repoKey),
      ]);
    }

    // M3 drawer destinations: pills, the selected one in secondaryContainer. Only here and in the agent
    // sheet; other lists keep M3's plain rows.
    return ListTileTheme.merge(
      shape: const StadiumBorder(),
      selectedColor: scheme.onSecondaryContainer,
      selectedTileColor: scheme.secondaryContainer,
      child: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 16, 16, 10),
                      child: Text('Workspaces', style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                    if (snapshot == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Text(client.machines.isEmpty
                            ? 'No machines yet'
                            : client.isDisconnected
                                ? 'Disconnected'
                                : 'Connecting…'),
                      ),
                    ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      onReorder: (from, to) {
                        if (to > from) to--;
                        if (to == from) return;
                        final moved = blocks.removeAt(from);
                        client.moveWorkspaces(
                            [for (final w in moved) w.id], to < blocks.length ? blocks[to].first.id : null);
                      },
                      children: [
                        for (final (i, block) in blocks.indexed)
                          Column(
                            key: ValueKey(block.first.id),
                            children: [
                              row(
                                status: block.first.agentStatus,
                                title: block.first.displayName,
                                subtitle: block.first.gitBranch,
                                selected: block.first.id == selectedPane?.workspaceId,
                                onTap: () => go(() => client.selectWorkspace(block.first.id)),
                                onLongPress: () => _workspaceActions(context, block.first),
                                trailing: blocks.length < 2
                                    ? null
                                    : ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                              ),
                              // The worktrees reorder among themselves, staying under their workspace.
                              ReorderableListView(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                buildDefaultDragHandles: false,
                                onReorder: (from, to) {
                                  final trees = block.sublist(1);
                                  if (to > from) to--;
                                  if (to == from) return;
                                  final moved = trees.removeAt(from);
                                  final after = i + 1 < blocks.length ? blocks[i + 1].first.id : null;
                                  client.moveWorkspaces([moved.id], to < trees.length ? trees[to].id : after);
                                },
                                children: [
                                  for (final (j, ws) in block.skip(1).indexed)
                                    row(
                                      key: ValueKey(ws.id),
                                      indent: 24,
                                      status: ws.agentStatus,
                                      title: ws.displayName,
                                      selected: ws.id == selectedPane?.workspaceId,
                                      onTap: () => go(() => client.selectWorkspace(ws.id)),
                                      onLongPress: () => _workspaceActions(context, ws),
                                      trailing: block.length < 3
                                          ? null
                                          : ReorderableDragStartListener(
                                              index: j, child: const Icon(Icons.drag_handle)),
                                    ),
                                ],
                              ),
                            ],
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.add),
                        label: const Text('New workspace'),
                        onPressed: () => go(client.createWorkspace),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: SingleChildScrollView(child: MachineList(client: client))),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Settings'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(client: client)));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _workspaceActions(BuildContext context, WorkspaceModel ws) {
    final error = Theme.of(context).colorScheme.error;
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        void run(VoidCallback action) {
          Navigator.pop(sheetContext);
          action();
        }

        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(ws.displayName, style: Theme.of(sheetContext).textTheme.titleMedium),
                subtitle: ws.gitBranch == null ? null : Text(ws.gitBranch!),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () => run(() async {
                  final name = await prompt(context, 'Rename workspace', 'Workspace name',
                      initial: ws.label.isNotEmpty ? ws.label : ws.displayName);
                  if (name != null) client.renameWorkspace(ws.id, name);
                }),
              ),
              ListTile(
                leading: const Icon(Icons.call_split),
                title: const Text('New worktree'),
                onTap: () => run(() async {
                  final branch = await prompt(context, 'New worktree', 'Branch name', hint: 'e.g. feat/my-feature');
                  if (branch == null || !context.mounted) return;
                  Navigator.pop(context);
                  client.createWorktree(ws.id, branch);
                }),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('Open worktree'),
                onTap: () => run(() => _openWorktree(context, ws)),
              ),
              ListTile(
                iconColor: error,
                textColor: error,
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                onTap: () => run(() async {
                  final linked = ws.isLinkedWorktree;
                  final ok = await confirm(
                    context,
                    linked ? 'Delete worktree?' : 'Close workspace?',
                    linked
                        ? '"${ws.displayName}" and its worktree checkout will be removed.'
                        : '"${ws.displayName}" and everything running in it will be closed.',
                    linked ? 'Delete' : 'Close',
                  );
                  if (ok) client.deleteWorkspace(ws.id, removeWorktree: linked);
                }),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The trimmed text entered, or null when cancelled or empty.
  static Future<String?> prompt(BuildContext context, String title, String label,
      {String initial = '', String? hint}) async {
    final controller = TextEditingController(text: initial);
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('OK')),
        ],
      ),
    );
    final trimmed = text?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  static Future<bool> confirm(BuildContext context, String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _openWorktree(BuildContext context, WorkspaceModel ws) {
    showDialog(
      context: context,
      builder: (dialogContext) => FutureBuilder<List<Map<String, dynamic>>>(
        future: client.listWorktrees(ws.id),
        builder: (_, result) {
          final list = result.data ?? [];
          return AlertDialog(
            title: const Text('Open worktree'),
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
            content: result.connectionState == ConnectionState.waiting
                ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
                : list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Text('No worktrees found for this repository.'),
                      )
                    : SizedBox(
                        width: double.maxFinite,
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final wt in list)
                              ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                                leading: const Icon(Icons.call_split),
                                title: Text(wt['branch']?.toString() ?? wt['label']?.toString() ?? 'unknown'),
                                subtitle: Text(
                                  wt['open_workspace_id'] != null ? 'Already open' : (wt['path']?.toString() ?? ''),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () {
                                  Navigator.pop(dialogContext);
                                  Navigator.pop(context);
                                  final open = wt['open_workspace_id'];
                                  if (open is String) {
                                    client.selectWorkspace(open);
                                  } else {
                                    client.openWorktree(ws.id,
                                        branch: wt['branch']?.toString(), path: wt['path']?.toString());
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
            actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel'))],
          );
        },
      ),
    );
  }
}
