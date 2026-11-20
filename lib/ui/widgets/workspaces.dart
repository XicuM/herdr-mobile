import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/session.dart';
import '../../models/agent_status.dart';
import '../../services/herdr_client.dart';

/// The home screen's drawer, modelled on Herdr's sidebar: each connected machine's spaces in the Herdr app's
/// order, under its name and a + for a new one. Tap one to open its terminal ([open]); hold it and lift for
/// its actions (or right-click), hold it and drag to reorder it. The app keeps the order, so the desktop follows.
class WorkspaceList extends StatelessWidget {
  final HerdrClientService client;
  final VoidCallback open;

  /// Whether the current workspace is marked: not when no terminal is showing.
  final bool showCurrent;

  const WorkspaceList({super.key, required this.client, required this.open, this.showCurrent = true});

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

    final currentWsId = client.selectedPane?.workspaceId ?? client.snapshot?.workspaces.firstOrNull?.id;
    final currentMachine = client.machine;

    // [drag] is its index to long-press and drag it by.
    Widget row(String m, WorkspaceModel ws, {int? drag}) {
      void menu(Offset p) => at(m, () => showWorkspaceContextMenu(context, client, ws, p, onShow: open));
      final isCurrent = showCurrent && m == currentMachine && ws.id == currentWsId;
      final tile = HoldMenu(
        key: ValueKey('$m/${ws.id}'),
        onMenu: menu,
        child: ListTile(
          key: ValueKey('$m/${ws.id}-tile'),
          autofocus: isCurrent,
          selected: isCurrent,
          contentPadding: const EdgeInsets.only(left: 16, right: 8),
          leading: StatusDot(ws.agentStatus, size: 10),
          minLeadingWidth: 10,
          title: Text(ws.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
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
          // The machine's name, with its + for a new workspace there.
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
                Focus(
                  skipTraversal: true,
                  child: IconButton(
                    tooltip: 'New workspace on ${client.nameOf(m)}',
                    color: scheme.primary,
                    icon: const Icon(Icons.add),
                    onPressed: () => at(m, client.createWorkspace),
                  ),
                ),
              ],
            ),
          ),
          Builder(builder: (context) {
            final spaces = client.snapshotOf(m)!.workspaces;
            // Indices as ReorderableListView gives them: [to] counts in the order before the move.
            void move(int from, int to) {
              if (to > from) to--;
              if (to == from) return;
              final rest = [...spaces]..removeAt(from);
              at(m, () => client.moveWorkspaces([spaces[from].id], to < rest.length ? rest[to].id : null));
            }

            return ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorder: move,
              children: [
                for (final (i, ws) in spaces.indexed) row(m, ws, drag: spaces.length < 2 ? null : i),
              ],
            );
          }),
        ],
      ],
    );
  }
}

/// The workspaces panel, as the home screen's ☰ and the terminal's header open it: the workspaces above,
/// Settings at the foot. [open] runs once one is picked, to show it; [onSettings] opens Settings.
class WorkspacesDrawer extends StatelessWidget {
  final HerdrClientService client;
  final VoidCallback open;
  final VoidCallback onSettings;

  final bool showCurrent;

  const WorkspacesDrawer(
      {super.key,
      required this.client,
      required this.open,
      required this.onSettings,
      this.showCurrent = true});

  @override
  Widget build(BuildContext context) => Drawer(
        child: SafeArea(
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.arrowDown):
                  DirectionalFocusIntent(TraversalDirection.down),
              SingleActivator(LogicalKeyboardKey.arrowUp):
                  DirectionalFocusIntent(TraversalDirection.up),
              SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
                  DirectionalFocusIntent(TraversalDirection.down),
              SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
                  DirectionalFocusIntent(TraversalDirection.up),
            },
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text('Workspaces',
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                  Expanded(
                      child: WorkspaceList(
                          client: client,
                          open: open,
                          showCurrent: showCurrent)),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('Settings'),
                    onTap: onSettings,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// A workspace's menu, from a hold or a right-click in the drawer or search ([HoldMenu]): Rename and Close,
/// done by the Herdr app on that machine.
Future<void> showWorkspaceContextMenu(
  BuildContext context,
  HerdrClientService client,
  WorkspaceModel ws,
  Offset at, {
  VoidCallback? onShow,
}) async {
  final m = client.machine;
  PopupMenuItem<String> item(String value, IconData icon, String text) =>
      PopupMenuItem(value: value, child: ListTile(leading: Icon(icon), title: Text(text)));
  final picked = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      item('rename', Icons.edit_outlined, 'Rename'),
      item('close', Icons.close, 'Close'),
    ],
  );
  if (picked == null || !context.mounted) return;
  switch (picked) {
    case 'rename':
      final name = await prompt(context, 'Rename workspace', 'Workspace name', initial: ws.label);
      if (name != null) await client.renameWorkspace(ws.id, name, on: m);
    case 'close':
      closeWithUndo(context, client, 'Workspace closed', ['$m/${ws.id}'], () => client.deleteWorkspace(ws.id, on: m));
  }
}

OverlayEntry? _activeUndoEntry;
Completer<bool>? _activeUndoCompleter;

/// Shows [message] and an Undo action in a snackbar just above the bar whose key is [above] (the message bar),
/// or at the bottom of the screen when there is none, as Gmail's undo bars do, for four seconds or until
/// another replaces it.
Future<bool> _showUndoSnackBar(
    BuildContext context, String message, GlobalKey? above) {
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
      final bar = above?.currentContext?.findRenderObject() as RenderBox?;
      final overlayBox = overlay.context.findRenderObject() as RenderBox?;
      // Without a message bar, keep clear of the keyboard and the system's own bar.
      final systemInset = MediaQuery.paddingOf(ctx).bottom;
      final keyboard = MediaQuery.viewInsetsOf(ctx).bottom;
      var bottom = 16.0 + (keyboard > systemInset ? keyboard : systemInset);
      if (bar != null &&
          bar.attached &&
          overlayBox != null &&
          overlayBox.attached) {
        bottom = overlayBox.size.height -
            bar.localToGlobal(Offset.zero, ancestor: overlayBox).dy +
            8;
      }
      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(left: 12, right: 12, bottom: bottom),
          // M3's widest snackbar, centred on a tablet.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              tween: Tween(begin: 0, end: 1),
              builder: (_, t, child) => Opacity(
                  opacity: t,
                  child: Transform.translate(
                      offset: Offset(0, (1 - t) * 16), child: child)),
              child: Material(
                // M3's snackbar roles, as Gmail's: near white in a dark theme, charcoal in a light one.
                color: scheme.inverseSurface,
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(message,
                            style: TextStyle(
                                color: scheme.onInverseSurface, fontSize: 14)),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.inversePrimary,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => dismiss(true),
                        child: const Text('Undo',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
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
/// snackbar saying [message] goes without Undo, or another replaces it. [above] is the bar it sits over,
/// when the screen has one.
void closeWithUndo(BuildContext context, HerdrClientService client,
    String message, List<String> keys, Future<void> Function() close,
    {GlobalKey? above}) {
  final undone = _showUndoSnackBar(context, message, above);
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

  void _triggerMenu(BuildContext ctx) {
    final box = ctx.findRenderObject() as RenderBox?;
    final at = box != null
        ? box.localToGlobal(box.size.center(Offset.zero))
        : Offset.zero;
    widget.onMenu(at);
  }

  // Once a drag lifts the row, a reorderable list builds a placeholder in its place, disposing this; the
  // release still reaches the listener it pressed, so the timer is left to run rather than cancelled then.
  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.space) {
            _triggerMenu(context);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Listener(
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
            if (_down != null && (e.position - _down!).distance > kTouchSlop)
              _reset();
          },
          onPointerUp: (e) {
            if (_held) widget.onMenu(e.position);
            _reset();
          },
          onPointerCancel: (_) => _reset(),
          child: GestureDetector(
              onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition),
              child: widget.child),
        ),
      );
}

/// The trimmed text entered, or null when cancelled or empty.
Future<String?> prompt(BuildContext context, String title, String label,
    {String initial = '', String? hint}) async {
  final controller = TextEditingController(text: initial);
  final text = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(dialogContext, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('OK')),
      ],
    ),
  );
  final trimmed = text?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

