import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/session.dart';
import '../../models/agent_status.dart';
import '../../services/herdr_client.dart';

/// The home screen's drawer, modelled on Herdr's sidebar: each connected machine's workspaces in herdr's order,
/// with linked worktrees nested, under its name and a + for a new one. Tap one to open its terminal ([open]);
/// hold it and lift for its actions and Move up/down (or right-click), hold it and drag to reorder it (with its
/// worktrees). herdr keeps the order, so the desktop follows.
class WorkspaceList extends StatelessWidget {
  final HerdrClientService client;
  final VoidCallback open;

  const WorkspaceList({super.key, required this.client, required this.open});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = [
      for (final m in client.machines)
        if (!client.isOff(m) && client.isConnected(m) && client.errorOf(m) == null && client.snapshotOf(m) != null) m
    ];
    // Requests go to the active machine, so each acts on its row's machine first.
    void at(String m, VoidCallback action) {
      if (client.machine != m) client.switchMachine(m);
      action();
    }

    // [up] and [down] move it, when it can go that way; [drag] is its index to long-press and drag it by.
    Widget row(String m, WorkspaceModel ws, {double indent = 0, VoidCallback? up, VoidCallback? down, int? drag}) {
      void menu(Offset p) =>
          at(m, () => showWorkspaceContextMenu(context, client, ws, p, onShow: open, onUp: up, onDown: down));
      final tile = HoldMenu(
          key: ValueKey('$m/${ws.id}'),
          onMenu: menu,
          child: ListTile(
            key: ValueKey('$m/${ws.id}-tile'),
            contentPadding: EdgeInsets.only(left: 16 + indent, right: 8),
            leading: StatusDot(ws.agentStatus, size: 10),
            minLeadingWidth: 10,
            title: Text(ws.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: ws.isLinkedWorktree || ws.gitBranch == null ? null : Text(ws.gitBranch!, maxLines: 1),
            onTap: () => at(m, () {
              client.selectWorkspace(ws.id);
              open();
            }),
          ),
        );
      return drag == null ? tile : ReorderableDelayedDragStartListener(key: tile.key, index: drag, child: tile);
    }

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
  Widget _machine(String m,
      Widget Function(String, WorkspaceModel, {double indent, VoidCallback? up, VoidCallback? down, int? drag}) row,
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
    // Indices as ReorderableListView gives them: [to] counts in the order before the move.
    void moveBlock(int from, int to) {
      if (to > from) to--;
      if (to == from) return;
      final rest = [...blocks];
      final moved = rest.removeAt(from);
      at(m, () => client.moveWorkspaces([for (final w in moved) w.id], to < rest.length ? rest[to].first.id : null));
    }

    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: moveBlock,
      children: [
        for (final (i, block) in blocks.indexed)
          Column(
            key: ValueKey('$m/${block.first.id}'),
            children: [
              row(m, block.first,
                  up: i > 0 ? () => moveBlock(i, i - 1) : null,
                  down: i + 1 < blocks.length ? () => moveBlock(i, i + 2) : null,
                  drag: blocks.length < 2 ? null : i),
              // The worktrees reorder among themselves, staying under their workspace.
              Builder(builder: (context) {
                final trees = block.sublist(1);
                void moveTree(int from, int to) {
                  if (to > from) to--;
                  if (to == from) return;
                  final rest = [...trees];
                  final moved = rest.removeAt(from);
                  final after = i + 1 < blocks.length ? blocks[i + 1].first.id : null;
                  at(m, () => client.moveWorkspaces([moved.id], to < rest.length ? rest[to].id : after));
                }

                return ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorder: moveTree,
                  children: [
                    for (final (j, ws) in trees.indexed)
                      row(m, ws,
                          indent: 24,
                          up: j > 0 ? () => moveTree(j, j - 1) : null,
                          down: j + 1 < trees.length ? () => moveTree(j, j + 2) : null,
                          drag: trees.length < 2 ? null : j),
                  ],
                );
              }),
            ],
          ),
      ],
    );
  }
}
 
/// A workspace's menu, from a right-click or a hold in the drawer or search ([HoldMenu]): Move up and down (given [onUp], [onDown]), Rename,
/// New worktree, Open worktree, Delete.
Future<void> showWorkspaceContextMenu(
  BuildContext context,
  HerdrClientService client,
  WorkspaceModel ws,
  Offset at, {
  VoidCallback? onShow,
  VoidCallback? onDelete,
  VoidCallback? onUp,
  VoidCallback? onDown,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final picked = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      if (onUp != null)
        const PopupMenuItem(value: 'up', child: ListTile(leading: Icon(Icons.arrow_upward), title: Text('Move up'))),
      if (onDown != null)
        const PopupMenuItem(
            value: 'down', child: ListTile(leading: Icon(Icons.arrow_downward), title: Text('Move down'))),
      const PopupMenuItem(
        value: 'rename',
        child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename')),
      ),
      if (ws.repoKey != null || ws.gitBranch != null) ...[
        const PopupMenuItem(
          value: 'new_worktree',
          child: ListTile(leading: Icon(Icons.call_split), title: Text('New worktree')),
        ),
        const PopupMenuItem(
          value: 'open_worktree',
          child: ListTile(leading: Icon(Icons.folder_open_outlined), title: Text('Open worktree')),
        ),
      ],
      PopupMenuItem(
        value: 'delete',
        child: ListTile(
          leading: Icon(Icons.delete_outline, color: scheme.error),
          title: Text('Delete', style: TextStyle(color: scheme.error)),
        ),
      ),
    ],
  );
  if (picked == null || !context.mounted) return;
  switch (picked) {
    case 'up':
      onUp?.call();
    case 'down':
      onDown?.call();
    case 'rename':
      final name = await prompt(context, 'Rename workspace', 'Workspace name',
          initial: ws.label.isNotEmpty ? ws.label : ws.displayName);
      if (name != null) client.renameWorkspace(ws.id, name);
    case 'new_worktree':
      final branch = await prompt(context, 'New worktree', 'Branch name', hint: 'e.g. feat/my-feature');
      if (branch == null) return;
      await client.createWorktree(ws.id, branch);
      onShow?.call();
    case 'open_worktree':
      _openWorktree(context, client, ws, onShow);
    case 'delete':
      _delete(context, client, ws);
      onDelete?.call();
  }
}

/// The workspace's actions, on the active machine: from the terminal's top bar, as a chat's header opens
/// its info. [onShow] runs once a new or opened worktree is selected,
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
              title: Text(
                title,
                style: Theme.of(sheetContext).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: (branch != null && branch.isNotEmpty)
                  ? Text(
                      branch,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          Theme.of(sheetContext).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
            if (ws.repoKey != null || ws.gitBranch != null) ...[
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
            ],
            ListTile(
              iconColor: error,
              textColor: error,
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () => run(() {
                _delete(context, client, ws);
                onDelete?.call();
              }),
            ),
          ],
        ),
      );
    },
  );
}

/// Deletes [ws], on the active machine, unless undone; a linked worktree's checkout goes too.
void _delete(BuildContext context, HerdrClientService client, WorkspaceModel ws) {
  final m = client.machine;
  closeWithUndo(context, client, 'Workspace deleted', ['$m/${ws.id}'],
      () => client.deleteWorkspace(ws.id, removeWorktree: ws.isLinkedWorktree, force: ws.isLinkedWorktree, on: m));
}

OverlayEntry? _activeUndoEntry;
Completer<bool>? _activeUndoCompleter;

/// Shows a floating stadium pill at the top of the screen with [message] and an Undo action.
Future<bool> _showTopUndoPill(BuildContext context, String message) {
  _activeUndoCompleter?.complete(false);
  _activeUndoEntry?.remove();
  _activeUndoEntry = null;

  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return Future.value(false);

  final completer = Completer<bool>();
  _activeUndoCompleter = completer;

  late OverlayEntry entry;
  Timer? timer;

  void dismiss([bool undo = false]) {
    timer?.cancel();
    if (_activeUndoCompleter == completer && !completer.isCompleted) {
      completer.complete(undo);
    }
    if (_activeUndoEntry == entry) {
      entry.remove();
      _activeUndoEntry = null;
      _activeUndoCompleter = null;
    }
  }

  entry = OverlayEntry(
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 10, left: 16, right: 16),
            child: Material(
              color: scheme.surfaceContainerHighest,
              elevation: 4,
              shape: const StadiumBorder(),
              child: Padding(
                padding: const EdgeInsets.only(left: 18, right: 8, top: 4, bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message,
                      style: TextStyle(color: scheme.onSurface, fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: scheme.primary,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: () => dismiss(true),
                      child: const Text('Undo', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  _activeUndoEntry = entry;
  overlay.insert(entry);
  timer = Timer(const Duration(seconds: 4), () => dismiss(false));

  return completer.future;
}

/// Hides what [keys] name (`machine/id` of panes, tabs or workspaces) at once and runs [close] once the
/// top pill saying [message] goes without Undo, or another replaces it.
void closeWithUndo(
    BuildContext context, HerdrClientService client, String message, List<String> keys, Future<void> Function() close) {
  final undone = _showTopUndoPill(context, message);
  client.closeUnlessUndone(keys, undone, close);
}

/// Calls [onMenu] at a right-click, and where a press held still past a long-press lifts: as with a launcher's
/// icons, held and lifted is the item's menu, held and moved drags it ([ReorderableDelayedDragStartListener],
/// [LongPressDraggable]), which both start on the same hold. A tick marks the hold.
class HoldMenu extends StatefulWidget {
  final void Function(Offset at) onMenu;
  final Widget child;

  const HoldMenu({super.key, required this.onMenu, required this.child});

  @override
  State<HoldMenu> createState() => _HoldMenuState();
}

class _HoldMenuState extends State<HoldMenu> {
  Offset? _down; // where the press began, until it moves away or ends
  bool _held = false;
  Timer? _hold;

  void _reset() {
    _hold?.cancel();
    _down = null;
    _held = false;
  }

  // Once a drag lifts the row, a reorderable list builds a placeholder in its place, disposing this; the
  // release still reaches the listener it pressed, so the timer is left to run rather than cancelled then.
  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (e) {
          if (e.buttons != kPrimaryButton) return;
          _reset();
          _down = e.position;
          _hold = Timer(kLongPressTimeout, () {
            _held = true;
            HapticFeedback.selectionClick();
          });
        },
        onPointerMove: (e) {
          if (_down != null && (e.position - _down!).distance > kTouchSlop) _reset();
        },
        onPointerUp: (e) {
          if (_held) widget.onMenu(e.position);
          _reset();
        },
        onPointerCancel: (_) => _reset(),
        child: GestureDetector(onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition), child: widget.child),
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
