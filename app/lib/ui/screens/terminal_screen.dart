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
import '../widgets/tab_sheet.dart';
import 'settings_screen.dart';

/// Offered above the message history; picking one fills the message box.
const _quickReplies = ['yes', 'no', 'continue', '/clear'];

class TerminalScreen extends StatefulWidget {
  final HerdrClientService client;

  const TerminalScreen({super.key, required this.client});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with SingleTickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _terminal = Terminal(maxLines: 10000);
  final _controller = TerminalController();
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

  // Swiping the bottom bar between tabs: the terminal's horizontal offset, in screen widths.
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
    _controller.addListener(() => setState(() {})); // shows the copy button while text is selected
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
                  'Tap the title (or ☰) to pick a workspace or agent. The tabs button next to the message box '
                  'lists, opens and creates tabs; swipe the message bar to go to the next or previous tab. Switch '
                  'machines from the menu at the top right. Type messages in the box at the bottom, with '
                  'autocorrect and voice; the history button brings back earlier ones. Pinch or use the volume '
                  'keys to change the font size.',
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
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add a machine'))
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
  /// An empty box just sends Enter.
  void _sendMessage() {
    final text = _message.text;
    if (_ptyChannel == null || !widget.client.connected) {
      _showError('Not connected to terminal');
      return;
    }
    _toLive();
    if (text.isNotEmpty) _ptyChannel?.sendInput(_terminal.bracketedPasteMode ? '\x1b[200~$text\x1b[201~' : text);
    _ptyChannel?.sendInput('\r');
    _message.clear();
    if (text.trim().isEmpty) return;
    _history = [text, ..._history.where((h) => h != text)].take(30).toList();
    SharedPreferences.getInstance().then((p) => p.setStringList('message_history', _history));
  }

  /// Quick replies and earlier messages; picking one puts it in the message box to edit or send.
  void _showHistory() {
    void pick(String text) {
      _message.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      Navigator.pop(context);
    }

    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                children: [for (final r in _quickReplies) ActionChip(label: Text(r), onPressed: () => pick(r))],
              ),
            ),
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
    );
  }

  /// Back to the bottom of the pane's history.
  void _toLive() {
    if (_scrolledUp == 0) return;
    _ptyChannel?.sendScroll(-_scrolledUp);
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
    if (!_swiping) {
      if (e is PointerUpEvent && d.dy < -48 && d.dy.abs() > d.dx.abs() * 2) showTabSheet(context, widget.client);
      return;
    }
    _swiping = false;
    final ms = (e.timeStamp - _swipeTime).inMilliseconds.clamp(1, 1 << 30);
    final flung = d.dx.abs() > 40 && d.dx.abs() / ms > 0.5;
    if (e is PointerUpEvent && (flung || d.dx.abs() > width / 3)) {
      _swipeTab(d.dx < 0 ? 1 : -1);
    } else {
      _slide.animateTo(0, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    }
  }

  /// The workspace's tabs, and the current one's index in them.
  (List<TabModel>, int)? _tabs() {
    final snapshot = widget.client.snapshot;
    final pane = snapshot?.panes.where((p) => p.id == widget.client.selectedPaneId).firstOrNull;
    if (pane == null) return null;
    final tabs = snapshot!.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
    return (tabs, tabs.indexWhere((t) => t.id == pane.tabId));
  }

  /// Slides the terminal out, switches [step] tabs (past the last one opens a new tab), and slides the
  /// new one in from the other side. Before the first tab it just springs back.
  Future<void> _swipeTab(int step) async {
    const duration = Duration(milliseconds: 160);
    final client = widget.client;
    final (tabs, i) = _tabs() ?? (<TabModel>[], -1);
    final next = i + step;
    if (i < 0 || next < 0) {
      await _slide.animateTo(0, duration: duration, curve: Curves.easeOut);
      return;
    }
    HapticFeedback.selectionClick();
    await _slide.animateTo(-step.toDouble(), duration: duration, curve: Curves.easeIn);
    if (next < tabs.length) {
      client.selectTab(tabs[next].id);
    } else {
      await client.createTab(tabs[i].workspaceId);
    }
    _slide.value = step.toDouble();
    await _slide.animateTo(0, duration: duration * 1.5, curve: Curves.easeOutCubic);
  }

  void _copySelection() {
    Clipboard.setData(ClipboardData(text: _terminal.buffer.getText(_controller.selection)));
    _controller.clearSelection();
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
    // way back to live scrolls further than needed.
    setState(() => _scrolledUp = (_scrolledUp + lines).clamp(0, 1 << 30));
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
    _scrolledUp = 0; // herdr shows a freshly attached pane live
    _ptyChannel = PtyChannel(
      host: client.host,
      port: client.port,
      paneId: paneId,
      terminal: _terminal,
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
    final pane = snapshot?.panes.where((p) => p.id == client.selectedPaneId).firstOrNull;
    final agent = snapshot?.agents.where((a) => a.paneId == client.selectedPaneId).firstOrNull;
    final status = AgentStatusExtension.fromString(agent?.status ?? pane?.agentStatus);
    final workspace = snapshot?.workspaces.where((w) => w.id == pane?.workspaceId).firstOrNull;
    final connecting = client.machines.isNotEmpty && !client.connected && !client.isDisconnected;

    return Scaffold(
      key: _scaffoldKey,
      drawer: WorkspaceDrawer(client: client),
      endDrawer: MachineDrawer(client: client),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 12,
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _scaffoldKey.currentState?.openDrawer(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (pane != null)
                  Tooltip(
                    message: agent == null ? status.label : '${agent.name}: ${status.label}',
                    child: Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: StatusDot(agent?.status ?? pane.agentStatus, size: 10),
                    ),
                  ),
                // Like the drawer: the workspace, with its git branch underneath.
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        workspace?.displayName ?? 'Herdr Mobile',
                        style: Theme.of(context).textTheme.titleMedium,
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
                ),
              ],
            ),
          ),
        ),
        actions: [
          // The machine on screen; tap for all machines and their connections.
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              tooltip: 'Machines',
              visualDensity: VisualDensity.compact,
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
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            ),
          ),
        ],
        bottom: connecting
            ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (client.machines.isNotEmpty && client.isDisconnected)
              MaterialBanner(
                leading: const Icon(Icons.link_off),
                content: Text('Disconnected from ${client.nameOf(client.machine)}'),
                actions: [TextButton(onPressed: client.connect, child: const Text('Connect'))],
              ),
            Expanded(
              child: client.machines.isEmpty
                  ? Center(
                      child: FilledButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.add),
                        label: const Text('Add a machine to get started'),
                      ),
                    )
                  : Stack(
                      children: [
                        // Revealed beside the terminal while it slides: where the swipe leads.
                        if (_tabs() case (final tabs, final i) when i >= 0)
                          Positioned.fill(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: Row(
                                children: [
                                  if (i > 0) ...[
                                    const Icon(Icons.chevron_left),
                                    Text(tabLabel(tabs[i - 1]), style: Theme.of(context).textTheme.labelLarge),
                                  ],
                                  const Spacer(),
                                  if (i + 1 < tabs.length)
                                    Text(tabLabel(tabs[i + 1]), style: Theme.of(context).textTheme.labelLarge)
                                  else ...[
                                    const Icon(Icons.add),
                                    Text(' New tab', style: Theme.of(context).textTheme.labelLarge),
                                  ],
                                  if (i + 1 < tabs.length) const Icon(Icons.chevron_right),
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
                        if (_scrolledUp > 0)
                          // Back to live: a small round arrow, centred at the bottom.
                          Positioned(
                            bottom: 12,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: FloatingActionButton.small(
                                tooltip: 'Back to live',
                                backgroundColor: scheme.primary,
                                foregroundColor: scheme.onPrimary,
                                shape: const CircleBorder(),
                                onPressed: _toLive,
                                child: const Icon(Icons.arrow_downward),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            // The workspace's tabs as page dots in their agents' colors, the current one long. Tap (or
            // swipe up on the message bar) for the tab sheet.
            if (_tabs() case (final tabs, final i) when i >= 0)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showTabSheet(context, client),
                child: SizedBox(
                  height: 14,
                  child: tabs.length > 8
                      ? Center(child: Text('${i + 1}/${tabs.length}', style: Theme.of(context).textTheme.labelSmall))
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (final (j, t) in tabs.indexed)
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                margin: const EdgeInsets.symmetric(horizontal: 3),
                                width: j == i ? 16 : 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(3),
                                  color: AgentStatusExtension.fromString(t.agentStatus).color,
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            if (client.keyBar)
              KeyboardAccessoryBar(
                ctrl: _ctrl,
                onCtrl: () => setState(() => _ctrl = !_ctrl),
                onKey: _key,
                onText: _send,
              ),
            // Swipe sideways here to change tabs (past the last one opens a new tab), up for all tabs.
            Listener(
              onPointerDown: _trackSwipe,
              onPointerMove: _trackSwipe,
              onPointerUp: _trackSwipe,
              onPointerCancel: _trackSwipe,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 8, 6),
                child: Row(
                  children: [
                    AgentsButton(client: client),
                    Expanded(
                      child: TextField(
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
                          // Copy (when there's a selection) and the Enter/Send circle sit inside the pill.
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_controller.selection != null)
                                IconButton(
                                  tooltip: 'Copy selection',
                                  icon: const Icon(Icons.content_copy),
                                  onPressed: _copySelection,
                                ),
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: _message,
                                  // A plain Enter icon when empty, a primary Send circle with text.
                                  builder: (context, val, _) => val.text.isEmpty
                                      ? IconButton(
                                          tooltip: 'Enter',
                                          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                          icon: const Icon(Icons.keyboard_return),
                                          onPressed: _sendMessage,
                                        )
                                      : IconButton.filled(
                                          tooltip: 'Send',
                                          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                          icon: const Icon(Icons.arrow_upward),
                                          onPressed: _sendMessage,
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
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
