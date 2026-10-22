import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/session.dart';
import '../../models/agent_status.dart';
import '../../services/herdr_client.dart';

/// What follows a workspace's branch, as in Herdr's sidebar: ↑ the commits to push in green, ↓ the commits to
/// pull in red (a linked worktree without an upstream counts against the main checkout); nothing when level.
List<InlineSpan> aheadBehind(WorkspaceModel ws) {
  InlineSpan count(IconData icon, int n, Color color) => TextSpan(children: [
        const TextSpan(text: ' '),
        WidgetSpan(alignment: PlaceholderAlignment.middle, child: Icon(icon, size: 12, color: color)),
        TextSpan(text: '$n', style: TextStyle(color: color)),
      ]);
  return [
    if ((ws.gitAhead ?? 0) > 0) count(Icons.north, ws.gitAhead!, Colors.green),
    if ((ws.gitBehind ?? 0) > 0) count(Icons.south, ws.gitBehind!, Colors.red),
  ];
}

/// The home screen's drawer, modelled on Herdr's sidebar: each connected machine's workspaces in herdr's order,
/// with linked worktrees nested, under its name and a + for a new one. Tap one to open its terminal ([open]);
/// hold it and lift for its actions (or right-click), hold it and drag to reorder it (with its worktrees).
/// herdr keeps the order, so the desktop follows.
class WorkspaceList extends StatelessWidget {
  final HerdrClientService client;
  final VoidCallback open;

  /// `machine/workspace` of the workspaces whose worktrees are hidden; static so it outlives the drawer.
  static final collapsed = ValueNotifier<Set<String>>({});

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

    // [drag] is its index to long-press and drag it by.
    Widget row(String m, WorkspaceModel ws, {double indent = 0, int? drag, Widget? trailing}) {
      void menu(Offset p) => at(m, () => showWorkspaceContextMenu(context, client, ws, p, onShow: open));
      final tile = HoldMenu(
        key: ValueKey('$m/${ws.id}'),
        onMenu: menu,
        child: ListTile(
          key: ValueKey('$m/${ws.id}-tile'),
          contentPadding: EdgeInsets.only(left: 16 + indent, right: 8),
          leading: StatusDot(ws.agentStatus, size: 10),
          minLeadingWidth: 10,
          trailing: trailing,
          // A linked worktree is named after its branch, so its ↑↓ follow its name.
          title: Text.rich(TextSpan(text: ws.displayName, children: ws.isLinkedWorktree ? aheadBehind(ws) : null),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: ws.isLinkedWorktree || ws.gitBranch == null
              ? null
              : Text.rich(TextSpan(text: ws.gitBranch, children: aheadBehind(ws)), maxLines: 1),
          onTap: () => at(m, () {
            client.selectWorkspace(ws.id);
            open();
          }),
        ),
      );
      return drag == null ? tile : ReorderableDelayedDragStartListener(key: tile.key, index: drag, child: tile);
    }

    return ValueListenableBuilder<Set<String>>(
        valueListenable: collapsed,
        builder: (context, hidden, _) => ListView(
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
                  _machine(m, row, at, hidden),
                ],
              ],
            ));
  }

  /// One machine's workspaces, one block per top-level workspace so it is dragged with its worktrees.
  Widget _machine(String m, Widget Function(String, WorkspaceModel, {double indent, int? drag, Widget? trailing}) row,
      void Function(String, VoidCallback) at, Set<String> hidden) {
    final blocks = client.snapshotOf(m)!.worktreeBlocks;
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
                  drag: blocks.length < 2 ? null : i,
                  trailing: block.length < 2
                      ? null
                      : IconButton(
                          tooltip: hidden.contains('$m/${block.first.id}') ? 'Show worktrees' : 'Hide worktrees',
                          icon: Icon(hidden.contains('$m/${block.first.id}') ? Icons.expand_more : Icons.expand_less),
                          onPressed: () => collapsed.value = {
                            for (final k in hidden)
                              if (k != '$m/${block.first.id}') k,
                            if (!hidden.contains('$m/${block.first.id}')) '$m/${block.first.id}',
                          },
                        )),
              // The worktrees reorder among themselves, staying under their workspace.
              if (!hidden.contains('$m/${block.first.id}'))
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
                      for (final (j, ws) in trees.indexed) row(m, ws, indent: 24, drag: trees.length < 2 ? null : j),
                    ],
                  );
                }),
            ],
          ),
      ],
    );
  }
}

/// A workspace's menu, from a hold or a right-click in the drawer or search ([HoldMenu]), as Herdr's sidebar has it:
/// Rename and Close; Close group for a repository's main workspace with its linked worktrees open (herdr closes
/// them together); New worktree and Open worktree for a git workspace that isn't a linked worktree; and Delete
/// worktree checkout for one that is. [onShow] runs once a new or opened worktree is selected, to show it.
Future<void> showWorkspaceContextMenu(
  BuildContext context,
  HerdrClientService client,
  WorkspaceModel ws,
  Offset at, {
  VoidCallback? onShow,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final m = client.machine;
  final group = [
    if (!ws.isLinkedWorktree && ws.repoKey != null)
      ...?client.snapshotOf(m)?.workspaces.where((w) => w.repoKey == ws.repoKey),
  ];
  final hasChildren = group.any((w) => w.isLinkedWorktree);
  final isGit = ws.repoKey != null || ws.gitBranch != null;
  PopupMenuItem<String> item(String value, IconData icon, String text, [Color? color]) => PopupMenuItem(
      value: value,
      child: ListTile(
          leading: Icon(icon, color: color), title: Text(text, style: color == null ? null : TextStyle(color: color))));
  final picked = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      item('rename', Icons.edit_outlined, 'Rename'),
      hasChildren ? item('group', Icons.close, 'Close group') : item('close', Icons.close, 'Close'),
      if (isGit && !ws.isLinkedWorktree) ...[
        item('new', Icons.add, 'New worktree'),
        item('open', Icons.call_split, 'Open worktree…'),
      ],
      if (ws.isLinkedWorktree) item('delete', Icons.delete_outline, 'Delete worktree checkout', scheme.error),
    ],
  );
  if (picked == null || !context.mounted) return;
  switch (picked) {
    case 'rename':
      final name = await prompt(context, 'Rename workspace', 'Workspace name', initial: ws.label);
      if (name != null) await client.renameWorkspace(ws.id, name, on: m);
    case 'close':
      closeWithUndo(context, client, 'Workspace closed', ['$m/${ws.id}'], () => client.deleteWorkspace(ws.id, on: m));
    case 'group':
      closeWithUndo(context, client, '${group.length} workspaces closed', [for (final w in group) '$m/${w.id}'],
          () => client.deleteWorkspace(ws.id, closeGroup: true, on: m));
    case 'new':
      final branch = await prompt(context, 'New worktree', 'Branch', hint: 'e.g. feat/my-feature');
      if (branch != null && await client.createWorktree(ws.id, branch, on: m) && context.mounted) {
        onShow?.call();
      }
    case 'open':
      _openWorktree(context, client, ws, m, onShow);
    case 'delete':
      _deleteCheckout(context, client, ws, m);
  }
}

/// Deletes [ws]'s linked worktree checkout (`git worktree remove`; its branch stays), asking first and closing
/// its workspace once it has gone, with no Undo: a checkout gone is gone. Since herdr says a checkout is dirty
/// only by refusing it, the one question warns of that and the removal is forced after it.
void _deleteCheckout(BuildContext context, HerdrClientService client, WorkspaceModel ws, String m) async {
  final navigator = Navigator.of(context, rootNavigator: true); // still there once this screen has gone
  final sure = await showDialog<bool>(
    context: navigator.context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete ${ws.displayName}?'),
      content: const Text('Its checkout is removed, and anything uncommitted in it is lost for good. '
          'Its branch is kept.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep')),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (sure != true) return;
  await client.deleteWorkspace(ws.id, removeWorktree: true, force: true, on: m);
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

/// The linked worktrees of [ws]'s repository (as `git worktree list` has them, less what herdr can't open),
/// to open one, or show it when it's open already.
void _openWorktree(BuildContext context, HerdrClientService client, WorkspaceModel ws, String m, VoidCallback? onShow) {
  // Hoisted, so a rebuild (e.g. a snapshot landing while the dialog is open) can't restart it
  // back into its spinner: a FutureBuilder with an inline future loads forever then.
  final worktrees = client.listWorktrees(ws.id, on: m);
  showDialog(
    context: context,
    builder: (dialogContext) => FutureBuilder<List<Map<String, dynamic>>?>(
      future: worktrees,
      builder: (_, result) {
        final list = [
          for (final wt in result.data ?? <Map<String, dynamic>>[])
            if (wt['is_bare'] != true && wt['is_prunable'] != true) wt
        ];
        return AlertDialog(
          title: const Text('Open worktree'),
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
          content: SizedBox(
            width: double.maxFinite,
            child: result.connectionState == ConnectionState.waiting
                ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
                : result.hasError || result.data == null
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24), child: Text('Could not load worktrees'))
                    : list.isEmpty
                        ? const Padding(padding: EdgeInsets.symmetric(horizontal: 24), child: Text('No worktrees yet'))
                        : ListView(
                            shrinkWrap: true,
                            children: [
                              for (final wt in list)
                                ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                                  leading: const Icon(Icons.call_split),
                                  title: Text(wt['branch']?.toString() ?? wt['label']?.toString() ?? 'detached'),
                                  subtitle: Text(wt['open_workspace_id'] != null ? 'Open' : wt['path'].toString(),
                                      overflow: TextOverflow.ellipsis),
                                  onTap: () async {
                                    Navigator.pop(dialogContext);
                                    final open = wt['open_workspace_id'];
                                    if (open is String) {
                                      if (client.machine != m) return;
                                      client.selectWorkspace(open);
                                    } else {
                                      if (!await client.openWorktree(ws.id, wt['path'].toString(), on: m)) return;
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
