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
import '../widgets/workspace_drawer.dart';
import '../widgets/keyboard_accessory_bar.dart';
import '../widgets/agent_status_badge.dart';
import 'settings_screen.dart';

class TerminalScreen extends StatefulWidget {
  final HerdrClientService client;

  const TerminalScreen({super.key, required this.client});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _terminal = Terminal(maxLines: 10000);
  final _controller = TerminalController();
  final _compose = TextEditingController();
  PtyChannel? _ptyChannel;
  bool _ctrl = false;
  bool _alt = false;

  // Pinch-to-zoom and history scrolling, tracked from raw pointers so they don't fight the
  // terminal's own gestures.
  final _pointers = <int, Offset>{};
  double? _pinchDistance;
  double _pinchFont = 0;
  Offset _downAt = Offset.zero;
  Duration _downTime = Duration.zero;
  double? _dragY; // set once a one-finger drag counts as a scroll
  bool _pinched = false; // the rest of a gesture that pinched never scrolls

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _send;
    _terminal.onResize = (cols, rows, _, __) => _ptyChannel?.sendResize(cols, rows);

    widget.client.onError = _showError;
    widget.client.addListener(_onClientUpdate);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    _connectTerminal();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showIntroOrChangelog());
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
    const body = TextStyle(color: Colors.white70, height: 1.4);
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
                  'Switch machines from the menu at the top right. Open the drawer (☰) to pick a '
                  'workspace or agent. Tap ✎ in the key bar to type a message with autocorrect and voice. '
                  'Pinch or use the volume keys to change the font size.',
                  style: body,
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (version, notes) in entries) ...[
                      Text(version, style: const TextStyle(fontWeight: FontWeight.bold)),
                      for (final n in notes) Text('• $n', style: body),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),
        actions: [
          if (firstRun)
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add a machine'))
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

  /// Everything typed or tapped reaches the pane here, with an armed CTRL/ALT applied once.
  void _send(String data) {
    if (_ctrl || _alt) {
      final c = data.length == 1 ? data.codeUnitAt(0) : -1;
      if (_ctrl && (c == 0x20 || (c >= 0x40 && c < 0x7f))) data = String.fromCharCode(c & 0x1f);
      if (_alt) data = '\x1b$data';
      setState(() => _ctrl = _alt = false);
    }
    _ptyChannel?.sendInput(data);
  }

  /// Special keys go through xterm so they follow the pane's cursor-key mode.
  void _key(TerminalKey key, {bool shift = false}) {
    final ctrl = _ctrl, alt = _alt;
    setState(() => _ctrl = _alt = false);
    _terminal.keyInput(key, shift: shift, ctrl: ctrl, alt: alt);
  }

  /// Sends [text] as one paste, so multi-line text doesn't submit line by line.
  void _paste(String text) {
    _ptyChannel?.sendInput(_terminal.bracketedPasteMode ? '\x1b[200~$text\x1b[201~' : text);
  }

  Future<void> _pasteClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.isNotEmpty) _paste(text);
  }

  void _copySelection() {
    final range = _controller.selection;
    if (range == null) return _showError('Long-press the terminal to select text first');
    Clipboard.setData(ClipboardData(text: _terminal.buffer.getText(range)));
    _controller.clearSelection();
  }

  /// A plain text field, so the phone keyboard's autocorrect, swipe and voice input work.
  /// The draft survives dismissing the sheet.
  Future<void> _openCompose() async {
    final send = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + MediaQuery.of(context).viewInsets.bottom),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _compose,
                autofocus: true,
                minLines: 1,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Message to send', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send',
              icon: const Icon(Icons.send),
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (send != true || _compose.text.isEmpty) return;
    _paste(_compose.text);
    _ptyChannel?.sendInput('\r');
    _compose.clear();
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
      _dragY = null;
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
  /// per text row moved. A press held still past the long-press timeout is text selection instead.
  void _scroll(PointerMoveEvent e) {
    final y = e.position.dy;
    if (_dragY == null) {
      if (e.timeStamp - _downTime >= kLongPressTimeout || (y - _downAt.dy).abs() < kTouchSlop) return;
      _dragY = y;
    }
    final lineHeight = widget.client.fontSize; // TerminalStyle height is 1.0
    final lines = (y - _dragY!) ~/ lineHeight;
    if (lines == 0) return;
    _ptyChannel?.sendScroll(lines);
    _dragY = _dragY! + lines * lineHeight;
  }

  void _onClientUpdate() {
    if (!mounted) return;
    setState(() {});
    _connectTerminal();
  }

  /// (Re)attaches when the selected pane or bridge address changes.
  void _connectTerminal() {
    final client = widget.client;
    final paneId = client.selectedPaneId;
    final pty = _ptyChannel;
    if (paneId == null) {
      // Machine switched: detach so keystrokes can't reach the old machine's pane.
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
    )..connect();
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientUpdate);
    widget.client.onError = null;
    _controller.dispose();
    _compose.dispose();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _ptyChannel?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final snapshot = client.snapshot;
    final currentPane = snapshot?.panes.where((p) => p.id == client.selectedPaneId).firstOrNull;
    final currentAgent = snapshot?.agents.where((a) => a.paneId == client.selectedPaneId).firstOrNull;
    final isBlocked = (currentAgent?.status == 'blocked' || currentPane?.agentStatus == 'blocked');
    final blockedElsewhere = {
      for (final p in snapshot?.panes ?? <PaneModel>[])
        if (p.agentStatus == 'blocked') p.id,
      for (final a in snapshot?.agents ?? <AgentModel>[])
        if (a.status == 'blocked') a.paneId,
    }..remove(client.selectedPaneId);
    final blockedColor = AgentStatus.blocked.color;
    final workspaceId = currentPane?.workspaceId ?? snapshot?.focusedWorkspaceId;
    final currentWorkspace = snapshot?.workspaces.where((w) => w.id == workspaceId).firstOrNull;
    final workspaceTabs = snapshot?.tabs.where((t) => t.workspaceId == workspaceId).toList() ?? [];
    final currentTab = workspaceTabs.where((t) => t.id == currentPane?.tabId).firstOrNull;
    String tabLabel(TabModel t) => t.label.isNotEmpty ? t.label : 'Tab ${t.number}';

    return Scaffold(
      backgroundColor: Colors.black,
      drawer: WorkspaceDrawer(client: client),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              currentWorkspace?.displayName ?? 'Herdr Mobile',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
            if (currentWorkspace?.gitBranch != null)
              Text(
                currentWorkspace!.gitBranch!,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          if (workspaceTabs.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Switch tab',
              onSelected: (tabId) {
                if (tabId.isEmpty) {
                  client.createTab(workspaceId!);
                  return;
                }
                final tabPanes = snapshot!.panes.where((p) => p.tabId == tabId);
                final pane = tabPanes.where((p) => p.focused).firstOrNull ?? tabPanes.firstOrNull;
                if (pane != null) client.selectPane(pane.id);
              },
              itemBuilder: (_) => [
                for (final tab in workspaceTabs)
                  PopupMenuItem(
                    value: tab.id,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tabLabel(tab),
                            style: TextStyle(
                              fontWeight: tab.id == currentTab?.id ? FontWeight.bold : FontWeight.normal,
                              color: tab.id == currentTab?.id ? Theme.of(context).colorScheme.primary : Colors.white,
                            ),
                          ),
                        ),
                        AgentStatusBadge(status: tab.agentStatus),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: '', // sentinel: create a new tab
                  child: Row(
                    children: [
                      Icon(Icons.add, size: 18, color: Colors.white70),
                      SizedBox(width: 8),
                      Text('New tab'),
                    ],
                  ),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 100),
                      child: Text(
                        currentTab != null ? tabLabel(currentTab) : 'Tabs',
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
          if (blockedElsewhere.isNotEmpty)
            TextButton.icon(
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero),
              onPressed: () => client.selectPane(blockedElsewhere.first),
              icon: Icon(Icons.warning_amber_rounded, size: 18, color: blockedColor),
              label: Text('${blockedElsewhere.length}', style: TextStyle(color: blockedColor)),
            ),
          if (currentPane != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: AgentStatusBadge(
                  status: currentAgent?.status ?? currentPane.agentStatus,
                  agentName: currentAgent?.name,
                ),
              ),
            ),
          // Always reachable, even while disconnected, so machines can be added or switched.
          PopupMenuButton<String>(
            tooltip: 'Machines',
            icon: Icon(Icons.dns, color: client.connected ? Colors.greenAccent : Colors.white54),
            onSelected: (value) {
              if (value.isEmpty) {
                _openSettings();
              } else if (value != client.machine || !client.connected) {
                client.switchMachine(value);
              }
            },
            itemBuilder: (_) => [
              for (final m in client.machines)
                PopupMenuItem(
                  value: m,
                  child: Row(
                    children: [
                      Icon(
                        m == client.machine ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        size: 18,
                        color: m == client.machine ? Theme.of(context).colorScheme.primary : Colors.white54,
                      ),
                      const SizedBox(width: 8),
                      Flexible(child: Text(client.nameOf(m), overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
              if (client.machines.isNotEmpty) const PopupMenuDivider(),
              const PopupMenuItem(
                value: '', // sentinel: open settings
                child: Row(
                  children: [
                    Icon(Icons.add, size: 18, color: Colors.white70),
                    SizedBox(width: 8),
                    Text('Add machine…'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (client.machines.isNotEmpty && !client.connected)
              Container(
                color: Colors.white10,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Connecting to ${client.nameOf(client.machine)}…',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

            // Agents prompt with menus answered by Enter (highlighted option) or Esc, not y/n.
            if (isBlocked)
              Container(
                color: Colors.amber.shade900.withOpacity(0.9),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Agent waiting for input',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    for (final (label, key, color) in [
                      ('Enter', TerminalKey.enter, Colors.green),
                      ('Esc', TerminalKey.escape, Colors.red),
                    ]) ...[
                      const SizedBox(width: 6),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: color,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          minimumSize: Size.zero,
                        ),
                        onPressed: () => _key(key),
                        child: Text(label, style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ),

            // Terminal View
            Expanded(
              child: client.machines.isEmpty
                  ? Center(
                      child: TextButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.add),
                        label: const Text('Add a machine to get started'),
                      ),
                    )
                  : Listener(
                      onPointerDown: _trackPointer,
                      onPointerMove: _trackPointer,
                      onPointerUp: _trackPointer,
                      onPointerCancel: _trackPointer,
                      child: TerminalView(
                        _terminal,
                        controller: _controller,
                        backgroundOpacity: 1.0,
                        // Bundled mono font with full box-drawing coverage; line height 1.0 keeps
                        // vertical lines continuous between rows.
                        textStyle: TerminalStyle(
                          fontSize: client.fontSize,
                          fontFamily: 'MesloLGS Nerd Font Mono',
                          height: 1.0,
                        ),
                        autofocus: true,
                        // Drags scroll herdr's history instead (_scroll); don't turn them into arrow keys.
                        simulateScroll: false,
                      ),
                    ),
            ),

            // Pinned Quick Keyboard Accessory Toolbar
            KeyboardAccessoryBar(
              ctrl: _ctrl,
              alt: _alt,
              onCtrl: () => setState(() => _ctrl = !_ctrl),
              onAlt: () => setState(() => _alt = !_alt),
              onKey: _key,
              onText: _send,
              onPaste: _pasteClipboard,
              onCopy: _copySelection,
              onCompose: _openCompose,
            ),
          ],
        ),
      ),
    );
  }
}
