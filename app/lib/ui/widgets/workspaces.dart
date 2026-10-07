import 'package:flutter/material.dart';
import '../../models/session.dart';
import '../../models/agent_status.dart';
import '../../services/herdr_client.dart';

/// The home screen's drawer, modelled on Herdr's sidebar: each connected machine's workspaces in herdr's order,
/// with linked worktrees nested, under its name and a + for a new one. Tap one to open its terminal ([open]);
/// long-press it for its actions; drag its handle to reorder it (with its worktrees), which the desktop follows.
class WorkspaceList extends StatelessWidget {
  final HerdrClientService client;
  final VoidCallback open;

  const WorkspaceList({super.key, required this.client, required this.open});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = [
      for (final m in client.machines)
        if (!client.isOff(m) && client.snapshotOf(m) != null) m
    ];
    // Requests go to the active machine, so each acts on its row's machine first.
    void at(String m, VoidCallback action) {
      if (client.machine != m) client.switchMachine(m);
      action();
    }

    Widget row(String m, WorkspaceModel ws, {double indent = 0, Widget? handle}) => GestureDetector(
          key: ValueKey('$m/${ws.id}'),
          onSecondaryTapUp: (d) => at(m, () => showWorkspaceActions(context, client, ws, onShow: open)),
          child: ListTile(
            key: ValueKey('$m/${ws.id}-tile'),
            contentPadding: EdgeInsets.only(left: 16 + indent, right: 8),
            leading: StatusDot(ws.agentStatus, size: 10),
            minLeadingWidth: 10,
            title: ws.isLinkedWorktree
                ? Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'worktree',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(child: Text(ws.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  )
                : Text(ws.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: ws.isLinkedWorktree || ws.gitBranch == null ? null : Text(ws.gitBranch!, maxLines: 1),
            trailing: handle,
            onTap: () => at(m, () {
              client.selectWorkspace(ws.id);
              open();
            }),
            onLongPress: () => at(m, () => showWorkspaceActions(context, client, ws, onShow: open)),
          ),
        );

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        for (final m in on) ...[
          // The machine's name, with its + for a new workspace there, opened once herdr has made it.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(client.nameOf(m),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary)),
                ),
                IconButton(
                  tooltip: 'New workspace on ${client.nameOf(m)}',
                  color: scheme.primary,
                  icon: const Icon(Icons.add),
                  onPressed: () => at(m, () async {
                    final before = client.selectedPaneId;
                    await client.createWorkspace();
                    if (client.selectedPaneId != before) open();
                  }),
                ),
              ],
            ),
          ),
          _machine(m, row, at),
        ],
      ],
    );
  }

  /// One machine's workspaces, one block per top-level workspace so it is dragged with its worktrees.
  Widget _machine(String m, Widget Function(String, WorkspaceModel, {double indent, Widget? handle}) row,
      void Function(String, VoidCallback) at) {
    final workspaces = client.snapshotOf(m)!.workspaces;
    final parentKeys = {
      for (final w in workspaces)
        if (!w.isLinkedWorktree && w.repoKey != null) w.repoKey
    };
    final blocks = <List<WorkspaceModel>>[];
    for (final w in workspaces) {
      if (w.isLinkedWorktree && parentKeys.contains(w.repoKey)) continue;
      blocks.add([
        w,
        if (!w.isLinkedWorktree && w.repoKey != null)
          ...workspaces.where((c) => c.isLinkedWorktree && c.repoKey == w.repoKey),
      ]);
    }
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: (from, to) {
        if (to > from) to--;
        if (to == from) return;
        final moved = blocks.removeAt(from);
        at(
            m,
            () =>
                client.moveWorkspaces([for (final w in moved) w.id], to < blocks.length ? blocks[to].first.id : null));
      },
      children: [
        for (final (i, block) in blocks.indexed)
          Column(
            key: ValueKey('$m/${block.first.id}'),
            children: [
              row(m, block.first,
                  handle: blocks.length < 2
                      ? null
                      : ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle))),
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
                  at(m, () => client.moveWorkspaces([moved.id], to < trees.length ? trees[to].id : after));
                },
                children: [
                  for (final (j, ws) in block.skip(1).indexed)
                    row(m, ws,
                        indent: 24,
                        handle: block.length < 3
                            ? null
                            : ReorderableDragStartListener(index: j, child: const Icon(Icons.drag_handle))),
                ],
              ),
            ],
          ),
      ],
    );
  }
}

/// The workspace's actions, on the active machine: from the terminal's top bar, as a chat's header opens
/// its info, or a long-press in the drawer or search. [onShow] runs once a new or opened worktree is selected,
/// to show it; [onDelete] once the workspace is deleted, to leave its terminal.
void showWorkspaceActions(BuildContext context, HerdrClientService client, WorkspaceModel ws,
    {VoidCallback? onShow, VoidCallback? onDelete}) {
  final theme = Theme.of(context);
  final error = theme.colorScheme.error;
  final scheme = theme.colorScheme;
  showModalBottomSheet(
    context: context,
    builder: (sheetContext) {
      void run(VoidCallback action) {
        Navigator.pop(sheetContext);
        action();
      }

      final snapshot = client.snapshotOf(client.machine) ?? client.snapshot;
      final isWorktree = ws.isLinkedWorktree;
      final mainRepo = isWorktree
          ? snapshot?.workspaces.where((w) => !w.isLinkedWorktree && w.repoKey == ws.repoKey).firstOrNull
          : null;
      final title = (isWorktree ? mainRepo?.displayName : ws.displayName) ?? ws.displayName;
      final branch = isWorktree
          ? (ws.gitBranch?.replaceFirst('worktree/', '') ?? ws.displayName)
          : ws.gitBranch;

      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isWorktree) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'worktree',
                        style: Theme.of(sheetContext).textTheme.labelSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(title,
                        style: Theme.of(sheetContext).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              subtitle: branch != null && branch.isNotEmpty
                  ? Text(
                      branch,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    )
                  : null,
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
                if (branch == null) return;
                await client.createWorktree(ws.id, branch);
                onShow?.call();
              }),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Open worktree'),
              onTap: () => run(() => _openWorktree(context, client, ws, onShow)),
            ),
            ListTile(
              iconColor: error,
              textColor: error,
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              // Straight away, like closing a tab. A linked worktree's checkout goes too.
              onTap: () => run(() {
                client.deleteWorkspace(ws.id, removeWorktree: ws.isLinkedWorktree);
                onDelete?.call();
              }),
            ),
          ],
        ),
      );
    },
  );
}

/// The trimmed text entered, or null when cancelled or empty.
Future<String?> prompt(BuildContext context, String title, String label, {String initial = '', String? hint}) async {
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

void _openWorktree(BuildContext context, HerdrClientService client, WorkspaceModel ws, VoidCallback? onShow) {
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
                              onTap: () async {
                                Navigator.pop(dialogContext);
                                final open = wt['open_workspace_id'];
                                if (open is String) {
                                  client.selectWorkspace(open);
                                } else {
                                  await client.openWorktree(ws.id,
                                      branch: wt['branch']?.toString(), path: wt['path']?.toString());
                                }
                                onShow?.call();
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
