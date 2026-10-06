import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import '../../changelog.dart';
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/herdr_client.dart';
import '../../services/pty_channel.dart';
import '../widgets/agent_sheet.dart';
import '../widgets/workspace_drawer.dart';
import '../widgets/keyboard_accessory_bar.dart';
import '../widgets/machine_drawer.dart';
import 'settings_screen.dart';

/// Offered below the message history; picking one fills the message box.
const _quickReplies = ['yes', 'no', 'continue', '/clear', '/exit'];

class TerminalScreen extends StatefulWidget {
  final HerdrClientService client;

  const TerminalScreen({super.key, required this.client});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with SingleTickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _terminal = Terminal();
  final _controller = TerminalController();
  final _view = GlobalKey<TerminalViewState>();
  final _message = TextEditingController();
  PtyChannel? _ptyChannel;
  late final AppLifecycleListener _lifecycle;
  bool _ctrl = false;
  List<String> _history = []; // sent messages, newest first
  int _scrolledUp = 0; // lines scrolled back into herdr's history; 0 is live

  // Pinch-to-zoom and history scrolling, tracked from raw pointers so they don't fight the
  // terminal's own gestures.
  final _pointers = <int, Offset>{};
  double? _pinchDistance;
  double _pinchFont = 0;
  Offset _downAt = Offset.zero;
  Duration _downTime = Duration.zero;
  bool _dragging = false; // set once a one-finger drag counts as a scroll
  double _scrollRest = 0; // scrolled pixels not yet a whole line
  bool _pinched = false; // the rest of a gesture that pinched never scrolls

  // Swiping the bottom bar between agents: the terminal's horizontal offset, in screen widths.
  late final _slide = AnimationController.unbounded(vsync: this);
  Offset? _swipeFrom;
  Duration _swipeTime = Duration.zero;
  bool _swiping = false;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _send;
    _terminal.onResize = (cols, rows, _, __) => _ptyChannel?.sendResize(cols, rows);

    widget.client.onError = _showError;
    _controller.addListener(() => setState(() {})); // shows the Copy button while text is selected
    widget.client.addListener(_onClientUpdate);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // The app now keeps running in the background (for alerts), so the pane is attached only while shown.
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _connectTerminal());
    _connectTerminal();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showIntroOrChangelog());
    SharedPreferences.getInstance().then((p) => _history = p.getStringList('message_history') ?? []);
  }

  /// Welcome on first launch; afterwards, the changelog entries newer than the last one seen.
  Future<void> _showIntroOrChangelog() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getString('last_seen_changelog');
    final latest = changelog.first.$1;
    if (seen == latest || !mounted) return;
    await prefs.setString('last_seen_changelog', latest);
    final firstRun = seen == null && widget.client.machines.isEmpty;
    final entries = changelog.takeWhile((e) => e.$1 != seen).toList();
    if (!mounted) return;
    final addMachine = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(firstRun ? 'Welcome to Herdr Mobile' : "What's new"),
        content: SingleChildScrollView(
          child: firstRun
              ? const Text(
                  'Herdr Mobile is a remote control for Herdr, the terminal multiplexer for AI coding agents.\n\n'
                  '1. On each computer running Herdr, start herdr-bridge (deploy/start-bridge.sh). '
                  'It listens on port 7788 on the computer\'s Tailscale IP.\n'
                  '2. Make sure this phone is on the same Tailscale network.\n'
                  '3. Add each computer here as a machine, using its Tailscale IP or MagicDNS name.\n\n'
                  'The menu button at the top left lists workspaces and machines. The workspace\'s tabs sit under '
                  'the top bar; long-press one to rename or close it. Swipe the message bar sideways to go from '
                  'agent to agent. The circle right of the message box lists every agent. Type messages '
                  'in the box at the bottom, with autocorrect and voice; the history button brings back earlier '
                  'ones. Pinch or use the volume keys to change the font size.',
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (version, notes) in entries) ...[
                      Text(version, style: Theme.of(context).textTheme.titleSmall),
                      for (final n in notes) Text('• $n'),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),
        actions: [
          if (firstRun)
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add a machine'))
          else
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
    if (addMachine == true) _openSettings();
  }

  void _openSettings() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(client: widget.client)));
  }

  /// Volume keys zoom the terminal font while this screen is on top.
  bool _onHardwareKey(KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.audioVolumeUp && key != LogicalKeyboardKey.audioVolumeDown) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    if (event is! KeyUpEvent) {
      final client = widget.client;
      client.setFontSize(client.fontSize + (key == LogicalKeyboardKey.audioVolumeUp ? 1 : -1));
    }
    return true;
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Everything typed or tapped reaches the pane here, with an armed CTRL applied once. Typing while
  /// scrolled back returns to the live screen first, so you see what you type.
  void _send(String data) {
    _toLive();
    if (_ctrl) {
      final c = data.length == 1 ? data.codeUnitAt(0) : -1;
      if (c == 0x20 || (c >= 0x40 && c < 0x7f)) data = String.fromCharCode(c & 0x1f);
      setState(() => _ctrl = false);
    }
    _ptyChannel?.sendInput(data);
  }

  /// Special keys go through xterm so they follow the pane's cursor-key mode.
  void _key(TerminalKey key, {bool shift = false}) {
    final ctrl = _ctrl;
    _toLive();
    setState(() => _ctrl = false);
    _terminal.keyInput(key, shift: shift, ctrl: ctrl);
  }

  /// Sends the message box as one paste (so multi-line text doesn't submit line by line), then Enter.
  /// An empty box just sends Enter. A [quickReply] is sent in its place, leaving the box and history be.
  void _sendMessage([String? quickReply]) {
    final text = quickReply ?? _message.text;
    if (_ptyChannel == null || !widget.client.connected) {
      _showError('Not connected to terminal');
      return;
    }
    _toLive();
    final channel = _ptyChannel;
    if (text.isEmpty) {
      channel?.sendInput('\r');
    } else {
      channel?.sendInput(_terminal.bracketedPasteMode ? '\x1b[200~$text\x1b[201~' : text);
      // An Enter in the same read as the paste is taken as part of it (Claude Code), so send it apart.
      // Dropped if the pane was switched meanwhile: its channel is closed.
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_ptyChannel == channel) channel?.sendInput('\r');
      });
    }
    if (quickReply != null) return;
    _message.clear();
    if (text.trim().isEmpty) return;
    _history = [text, ..._history.where((h) => h != text)].take(30).toList();
    SharedPreferences.getInstance().then((p) => p.setStringList('message_history', _history));
  }

  /// Quick replies, sent as soon as picked, and earlier messages, which go in the message box to edit or send.
  void _showHistory() {
    void pick(String text) {
      _message.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      Navigator.pop(context);
    }

    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(top: 12),
                children: [
                  for (final h in _history)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.history, size: 18),
                      title: Text(h, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => pick(h),
                    ),
                ],
              ),
            ),
            // Pinned under the history, nearest the thumb.
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final r in _quickReplies)
                    ActionChip(
                      label: Text(r),
                      onPressed: () {
                        Navigator.pop(context);
                        _sendMessage(r);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Back to the bottom of the pane's history. Herdr's own scrollback takes a scroll's line count but
  /// stays pinned while new output arrives, so the way back may be longer than [_scrolledUp]; an app on
  /// the alternate screen (Claude Code) gets each scroll as one wheel tick whatever its count. So send
  /// a scroll per line counted, each long enough to reach the bottom (herdr caps it at a u16).
  void _toLive() {
    if (_scrolledUp == 0) return;
    for (var i = 0; i < _scrolledUp; i++) {
      _ptyChannel?.sendScroll(-65535);
    }
    setState(() => _scrolledUp = 0);
  }

  /// Raw pointers, so the swipe works over the message box too, whose own drags would win the arena.
  /// A drag that is mostly sideways moves the terminal with the finger.
  void _trackSwipe(PointerEvent e) {
    final width = MediaQuery.sizeOf(context).width;
    if (e is PointerDownEvent) {
      _swipeFrom = e.position;
      _swipeTime = e.timeStamp;
      _swiping = false;
      return;
    }
    final from = _swipeFrom;
    if (from == null) return;
    final d = e.position - from;
    if (e is PointerMoveEvent) {
      if (!_swiping && d.dx.abs() > kTouchSlop * 2 && d.dx.abs() > d.dy.abs() * 2) _swiping = true;
      if (_swiping) _slide.value = d.dx / width;
      return;
    }
    _swipeFrom = null;
    if (!_swiping) return;
    _swiping = false;
    final ms = (e.timeStamp - _swipeTime).inMilliseconds.clamp(1, 1 << 30);
    final flung = d.dx.abs() > 40 && d.dx.abs() / ms > 0.5;
    if (e is PointerUpEvent && (flung || d.dx.abs() > width / 3)) {
      _swipe(d.dx < 0 ? 1 : -1);
    } else {
      _slide.animateTo(0, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    }
  }

  void _tabActions(TabModel tab) {
    final client = widget.client;
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
              ListTile(title: Text(tab.displayName, style: Theme.of(sheetContext).textTheme.titleMedium)),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () => run(() async {
                  final name = await WorkspaceDrawer.prompt(context, 'Rename tab', 'Tab name', initial: tab.label);
                  if (name != null) client.renameTab(tab.id, name);
                }),
              ),
              ListTile(
                iconColor: error,
                textColor: error,
                leading: const Icon(Icons.close),
                title: const Text('Close'),
                onTap: () => run(() async {
                  final ok = await WorkspaceDrawer.confirm(context, 'Close tab?',
                      '"${tab.displayName}" and everything running in it will be closed.', 'Close');
                  if (ok) client.closeTab(tab.id);
                }),
              ),
            ],
          ),
        );
      },
    );
  }

  /// A tab's label, else its agents' names, else "Tab N".
  String _tabName(TabModel tab) {
    if (tab.label.isNotEmpty) return tab.label;
    final snapshot = widget.client.snapshot!;
    final panes = {
      for (final p in snapshot.panes)
        if (p.tabId == tab.id) p.id
    };
    final names = [
      for (final a in snapshot.agents)
        if (panes.contains(a.paneId)) a.name
    ];
    return names.isEmpty ? tab.displayName : names.join(' · ');
  }

  /// The workspace's tabs, and the current one's index in them.
  (List<TabModel>, int)? _tabs() {
    final snapshot = widget.client.snapshot;
    final pane = widget.client.selectedPane;
    if (pane == null) return null;
    final tabs = snapshot!.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
    return (tabs, tabs.indexWhere((t) => t.id == pane.tabId));
  }

  /// Where a sideways swipe goes: every agent in herdr's order (workspace, tab, pane), as labels and
  /// how to show each, with the current one's index. The pane on screen is among them even when it runs
  /// no agent, so a plain shell still has neighbours.
  (List<(String, VoidCallback)>, int)? _stops() {
    final client = widget.client;
    final snapshot = client.snapshot;
    final current = client.selectedPane;
    if (current == null) return null;
    final ws = [for (final w in snapshot!.workspaces) w.id];
    final tabs = [for (final t in snapshot.tabs) t.id];
    final names = {for (final a in snapshot.agents) a.paneId: a.name};
    final wsName = {for (final w in snapshot.workspaces) w.id: w.displayName};
    final order = snapshot.panes.indexOf;
    final panes = snapshot.panes.where((p) => names.containsKey(p.id) || p == current).toList()
      ..sort((a, b) => [
            ws.indexOf(a.workspaceId).compareTo(ws.indexOf(b.workspaceId)),
            tabs.indexOf(a.tabId).compareTo(tabs.indexOf(b.tabId)),
            order(a).compareTo(order(b)),
          ].firstWhere((c) => c != 0, orElse: () => 0));
    return (
      [
        for (final p in panes)
          (
            [if (p.workspaceId != current.workspaceId) wsName[p.workspaceId], names[p.id] ?? 'shell']
                .whereType<String>()
                .join(' · '),
            () => client.selectPane(p.id),
          ),
      ],
      panes.indexOf(current),
    );
  }

  /// Slides the terminal out, moves [step] agents (wrapping around past either end), and slides the new
  /// one in from the other side. With nowhere else to go it just springs back.
  Future<void> _swipe(int step) async {
    const duration = Duration(milliseconds: 160);
    final (stops, i) = _stops() ?? (<(String, VoidCallback)>[], -1);
    if (i < 0 || stops.length < 2) {
      await _slide.animateTo(0, duration: duration, curve: Curves.easeOut);
      return;
    }
    final next = (i + step) % stops.length;
    HapticFeedback.selectionClick();
    await _slide.animateTo(-step.toDouble(), duration: duration, curve: Curves.easeIn);
    stops[next].$2();
    _slide.value = step.toDouble();
    await _slide.animateTo(0, duration: duration * 1.5, curve: Curves.easeOutCubic);
  }

  void _copySelection() {
    Clipboard.setData(ClipboardData(text: _terminal.buffer.getText(_controller.selection)));
    _controller.clearSelection();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  /// Where the Copy button sits: just above the selection, or below it when that's off the top.
  double? _copyTop() {
    final selection = _controller.selection?.normalized;
    final render = _view.currentState?.renderTerminal;
    if (selection == null || render == null || !render.hasSize) return null;
    final above = render.getOffset(selection.begin).dy - 48;
    return above >= 0 ? above : render.getOffset(selection.end).dy + render.lineHeight + 8;
  }

  void _trackPointer(PointerEvent e) {
    if (e is PointerUpEvent || e is PointerCancelEvent) {
      _pointers.remove(e.pointer);
    } else {
      _pointers[e.pointer] = e.position;
    }
    if (e is PointerDownEvent && _pointers.length == 1) {
      _downAt = e.position;
      _downTime = e.timeStamp;
      _dragging = false;
      _pinched = false;
    }
    if (e is PointerMoveEvent && _pointers.length == 1 && !_pinched) return _scroll(e);
    if (_pointers.length != 2) {
      _pinchDistance = null;
      return;
    }
    final p = _pointers.values.toList();
    final distance = (p[0] - p[1]).distance;
    if (_pinchDistance == null) {
      _pinched = true;
      _pinchDistance = distance;
      _pinchFont = widget.client.fontSize;
      return;
    }
    widget.client.setFontSize((_pinchFont * distance / _pinchDistance!).roundToDouble());
  }

  /// Herdr holds the pane's history (see [PtyChannel.connect]), so dragging scrolls herdr's view a line
  /// per text row moved. A press held still past the long-press timeout is text selection instead, and
  /// so is any mouse drag: a mouse scrolls with its wheel ([_scrollSignal]).
  void _scroll(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.mouse) return;
    if (!_dragging) {
      if (e.timeStamp - _downTime >= kLongPressTimeout || (e.position.dy - _downAt.dy).abs() < kTouchSlop) return;
      _dragging = true;
      _scrollRest = 0;
      return;
    }
    _scrollBy(e.delta.dy);
  }

  /// A mouse wheel, or a desktop touchpad's two-finger pan, scrolls herdr's view like a drag does.
  void _scrollSignal(PointerEvent e) {
    if (e is PointerScrollEvent) _scrollBy(-e.scrollDelta.dy);
    if (e is PointerPanZoomUpdateEvent) _scrollBy(e.panDelta.dy);
  }

  /// Scrolls by [dy] pixels, positive toward older history.
  void _scrollBy(double dy) {
    final lineHeight = widget.client.fontSize * 1.1; // TerminalStyle height is 1.1
    _scrollRest += dy;
    final lines = _scrollRest ~/ lineHeight;
    if (lines == 0) return;
    _ptyChannel?.sendScroll(lines);
    _scrollRest -= lines * lineHeight;
    // Herdr stops at the bottom, so the count does too; it may overshoot the top, which only means the
    // way back to live scrolls further than needed. Capped, since the way back sends a scroll per line.
    setState(() => _scrolledUp = (_scrolledUp + lines).clamp(0, 1000));
  }

  void _onClientUpdate() {
    if (!mounted) return;
    setState(() {});
    _connectTerminal();
  }

  /// (Re)attaches when the selected pane or bridge address changes, or the app comes back on screen.
  void _connectTerminal() {
    final client = widget.client;
    final paneId = client.selectedPaneId;
    final pty = _ptyChannel;
    final state = WidgetsBinding.instance.lifecycleState;
    if (paneId == null ||
        client.isDisconnected ||
        (state != null && state != AppLifecycleState.resumed && state != AppLifecycleState.inactive)) {
      // Machine switched, disconnected, or app in background: detach
      pty?.dispose();
      _ptyChannel = null;
      return;
    }
    if (pty != null && pty.paneId == paneId && pty.host == client.host && pty.port == client.port) return;
    pty?.dispose();
    _ptyChannel = PtyChannel(
      host: client.host,
      port: client.port,
      paneId: paneId,
      terminal: _terminal,
      // Herdr shows a freshly attached pane live, also after the channel reconnects on its own.
      onAttach: () {
        if (_scrolledUp > 0) setState(() => _scrolledUp = 0);
      },
    )..connect();
  }

  @override
  void dispose() {
    _slide.dispose();
    _lifecycle.dispose();
    widget.client.removeListener(_onClientUpdate);
    widget.client.onError = null;
    _controller.dispose();
    _message.dispose();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _ptyChannel?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final scheme = Theme.of(context).colorScheme;
    final snapshot = client.snapshot;
    final pane = client.selectedPane;
    final workspace = snapshot?.workspaces.where((w) => w.id == pane?.workspaceId).firstOrNull;
    final connecting = client.machines.isNotEmpty && !client.connected && !client.isDisconnected;

    return Scaffold(
      key: _scaffoldKey,
      // The app bar's own menu button opens it: workspaces and machines.
      drawer: WorkspaceDrawer(client: client),
      appBar: AppBar(
        titleSpacing: 0,
        // The workspace, with its git branch underneath, like the drawer.
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              workspace?.displayName ?? 'Herdr',
              style: Theme.of(context).textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
            if (workspace?.gitBranch != null)
              Text(
                workspace!.gitBranch!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          // The machine on screen; tap for the drawer, whose foot lists all machines.
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              tooltip: 'Machines',
              visualDensity: VisualDensity.compact,
              side: BorderSide.none,
              backgroundColor: scheme.secondaryContainer,
              labelStyle: TextStyle(color: scheme.onSecondaryContainer),
              avatar: Center(
                child: Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, color: machineColor(context, client, client.machine)),
                ),
              ),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Text(
                  client.machines.isEmpty ? 'No machine' : client.nameOf(client.machine),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          ),
        ],
        // The workspace's tabs, as M3 scrollable tabs, each with its agent's status. Long-press one to
        // rename or close it. Unlabelled tabs are named after their agents.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Column(
            children: [
              SizedBox(
                height: 48,
                child: switch (_tabs()) {
                  (final tabs, final i) when i >= 0 => Row(
                      children: [
                        Expanded(
                          // Rebuilt when the tabs or the current one change, so it opens scrolled to the current one.
                          child: DefaultTabController(
                            key: ValueKey([for (final t in tabs) t.id, i].join(',')),
                            length: tabs.length,
                            initialIndex: i,
                            child: TabBar(
                              isScrollable: true,
                              tabAlignment: TabAlignment.start,
                              onTap: (j) => client.selectTab(tabs[j].id),
                              tabs: [
                                for (final t in tabs)
                                  GestureDetector(
                                    onLongPress: () => _tabActions(t),
                                    child: Tab(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          StatusDot(t.agentStatus),
                                          const SizedBox(width: 8),
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(maxWidth: 120),
                                            child: Text(_tabName(t), overflow: TextOverflow.ellipsis),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'New tab',
                          icon: const Icon(Icons.add),
                          onPressed: () => client.createTab(tabs[i].workspaceId),
                        ),
                      ],
                    ),
                  _ => null,
                },
              ),
              SizedBox(height: 4, child: connecting ? const LinearProgressIndicator() : null),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: client.machines.isEmpty
                  ? Center(
                      child: FilledButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.add),
                        label: const Text('Add a machine to get started'),
                      ),
                    )
                  // Switched off in the machine drawer: no terminal, just the way back.
                  : client.isDisconnected
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.link_off, size: 48, color: scheme.onSurfaceVariant),
                              const SizedBox(height: 12),
                              Text('Disconnected from ${client.nameOf(client.machine)}'),
                              const SizedBox(height: 16),
                              FilledButton(onPressed: client.connect, child: const Text('Connect')),
                            ],
                          ),
                        )
                      : Stack(
                          children: [
                            // Revealed beside the terminal while it slides: where the swipe leads.
                            if (_stops() case (final stops, final i) when i >= 0 && stops.length > 1)
                              Positioned.fill(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 24),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.chevron_left),
                                      Text(stops[(i - 1) % stops.length].$1,
                                          style: Theme.of(context).textTheme.labelLarge),
                                      const Spacer(),
                                      Text(stops[(i + 1) % stops.length].$1,
                                          style: Theme.of(context).textTheme.labelLarge),
                                      const Icon(Icons.chevron_right),
                                    ],
                                  ),
                                ),
                              ),
                            Positioned.fill(
                              child: AnimatedBuilder(
                                animation: _slide,
                                builder: (_, child) =>
                                    FractionalTranslation(translation: Offset(_slide.value, 0), child: child),
                                child: Listener(
                                  onPointerDown: _trackPointer,
                                  onPointerMove: _trackPointer,
                                  onPointerUp: _trackPointer,
                                  onPointerCancel: _trackPointer,
                                  onPointerSignal: _scrollSignal,
                                  onPointerPanZoomUpdate: _scrollSignal,
                                  child: TerminalView(
                                    _terminal,
                                    key: _view,
                                    controller: _controller,
                                    backgroundOpacity: 1.0,
                                    textStyle: TerminalStyle(
                                      fontSize: client.fontSize,
                                      fontFamily: 'MesloLGS Nerd Font Mono',
                                      height: 1.1,
                                    ),
                                    autofocus: true,
                                    simulateScroll: false,
                                  ),
                                ),
                              ),
                            ),
                            if (_copyTop() case final top?)
                              // Copy floats by the selection, like Android's own text toolbar.
                              Positioned(
                                top: top,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: FilledButton.tonalIcon(
                                    onPressed: _copySelection,
                                    icon: const Icon(Icons.content_copy, size: 18),
                                    label: const Text('Copy'),
                                  ),
                                ),
                              ),
                            if (_scrolledUp > 0)
                              // Back to live: a small round arrow, centred at the bottom.
                              Positioned(
                                bottom: 12,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: FloatingActionButton.small(
                                    tooltip: 'Back to live',
                                    onPressed: _toLive,
                                    child: const Icon(Icons.arrow_downward),
                                  ),
                                ),
                              ),
                          ],
                        ),
            ),
            // Swipe sideways here to move between agents in herdr's order. The keyboard
            // button swaps the message box for the control keys and back.
            if (!client.isDisconnected)
              Listener(
                onPointerDown: _trackSwipe,
                onPointerMove: _trackSwipe,
                onPointerUp: _trackSwipe,
                onPointerCancel: _trackSwipe,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 6),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: client.keyBar ? 'Message box' : 'Control keys',
                        isSelected: client.keyBar,
                        icon: const Icon(Icons.keyboard_outlined),
                        selectedIcon: const Icon(Icons.keyboard_hide_outlined),
                        onPressed: () => client.setKeyBar(!client.keyBar),
                      ),
                      Expanded(
                        child: client.keyBar
                            ? KeyboardAccessoryBar(
                                ctrl: _ctrl,
                                onCtrl: () => setState(() => _ctrl = !_ctrl),
                                onKey: _key,
                                onText: _send,
                              )
                            : TextField(
                                controller: _message,
                                minLines: 1,
                                maxLines: 4,
                                textCapitalization: TextCapitalization.sentences,
                                textInputAction: TextInputAction.send,
                                onEditingComplete: _sendMessage,
                                // An M3 filled text field, pill-shaped like a search bar.
                                decoration: InputDecoration(
                                  hintText: 'Message terminal…',
                                  filled: true,
                                  fillColor: scheme.surfaceContainerHigh,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    borderSide: BorderSide.none,
                                  ),
                                  prefixIcon: IconButton(
                                    tooltip: 'Quick replies and history',
                                    icon: const Icon(Icons.history),
                                    onPressed: _showHistory,
                                  ),
                                  // Enter/Send sits inside the pill, styled like the history button.
                                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                                    valueListenable: _message,
                                    builder: (context, val, _) => IconButton(
                                      tooltip: val.text.isEmpty ? 'Enter' : 'Send',
                                      icon: Icon(val.text.isEmpty ? Icons.keyboard_return : Icons.send),
                                      onPressed: _sendMessage,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      AgentsButton(client: client),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
