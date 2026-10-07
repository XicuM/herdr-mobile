import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/palette_builder.dart'; // the palette xterm paints with, to resolve a cell's colour
import '../../models/session.dart';
import '../../services/herdr_client.dart';
import '../../services/pty_channel.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/keyboard_accessory_bar.dart';
import '../widgets/machines.dart';
import '../widgets/workspaces.dart';

/// Offered below the message history; picking one sends it straight away.
const _quickReplies = ['yes', 'no', 'continue', '/clear', '/exit'];

class TerminalScreen extends StatefulWidget {
  final HerdrClientService client;

  /// Beside the agents on a wide screen, rather than a screen of its own: then it never goes back, and
  /// the home screen shows something else once its pane or machine is gone.
  final bool embedded;

  const TerminalScreen({super.key, required this.client, this.embedded = false});

  // Unsent message box text per pane, by `machine/pane`; static, so it outlives the screen, which goes back
  // to the agent list.
  static final _drafts = <String, String>{};
  static bool hasDraft(String paneId, String machine) => _drafts['$machine/$paneId']?.isNotEmpty ?? false;
  static String? draftOf(String paneId, String machine) => _drafts['$machine/$paneId'];
  static void setDraftForTesting(String paneId, String machine, String text) => _drafts['$machine/$paneId'] = text;
  static void clearDraftsForTesting() => _drafts.clear();

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with SingleTickerProviderStateMixin {
  final _terminal = Terminal();
  final _controller = TerminalController();
  final _view = GlobalKey<TerminalViewState>();
  final _message = TextEditingController();
  PtyChannel? _ptyChannel;
  late final AppLifecycleListener _lifecycle;
  bool _ctrl = false;
  List<String> _history = []; // sent messages, newest first, shared by every pane
  String? _draftKey; // the pane whose draft is in the message box
  int _scrolledUp = 0; // scrolls back into the pane's history; 0 is live
  bool _left = false; // popped back to the agents, since the machine went off

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

  // The current tab in the top bar's strip, scrolled into view when it changes.
  final _currentTab = GlobalKey();
  // The tab being dragged.
  String? _draggedTab;
  String? _shownTabId;

  // The terminal's true background: the colour most of the screen's edges are painted, since full-screen agents
  // paint their own over the default. The message bar and the current tab take it, joining the terminal.
  // Null while it's the default: the scheme's surface, like the rest of the app.
  static const _defaultTheme = TerminalThemes.defaultTheme;
  static final _palette = PaletteBuilder(_defaultTheme).build();
  Color? _background;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _send;
    _terminal.onResize = (cols, rows, _, __) => _ptyChannel?.sendResize(cols, rows);
    _terminal.addListener(_findBackground);

    _message.addListener(_onMessageChanged);
    _controller.addListener(() => setState(() {})); // shows the Copy button while text is selected
    widget.client.addListener(_onClientUpdate);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // The app now keeps running in the background (for alerts), so the pane is attached only while shown.
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _connectTerminal());
    _connectTerminal();
    if (widget.client.selectedPaneId case final paneId?) _swapDraft('${widget.client.machine}/$paneId');
    SharedPreferences.getInstance().then((p) => _history = p.getStringList('message_history') ?? []);
  }

  void _onMessageChanged() {
    if (_draftKey != null) {
      if (_message.text.isNotEmpty) {
        TerminalScreen._drafts[_draftKey!] = _message.text;
      } else {
        TerminalScreen._drafts.remove(_draftKey);
      }
    }
  }

  /// Volume keys zoom the terminal font or send ↑/↓ while this screen is on top, as set in Settings.
  bool _onHardwareKey(KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.audioVolumeUp && key != LogicalKeyboardKey.audioVolumeDown) return false;
    final client = widget.client;
    if (client.volumeKeys == VolumeKeys.volume) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    if (event is! KeyUpEvent) {
      final up = key == LogicalKeyboardKey.audioVolumeUp;
      if (client.volumeKeys == VolumeKeys.arrows) {
        _key(up ? TerminalKey.arrowUp : TerminalKey.arrowDown);
      } else {
        client.setFontSize(client.fontSize + (up ? 1 : -1));
      }
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
                children: [
                  // Headed like the other sheets.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Text('Recent messages',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
                  for (final h in _history)
                    ListTile(
                      leading: const Icon(Icons.history),
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

  /// Takes the background most of the screen's edge cells have as [_background]: the top and bottom rows
  /// and the outer columns, which meet the tab strip and the message bar. What's drawn in the middle (a
  /// diff, a selection) doesn't sway it. The default counts as the theme's.
  void _findBackground() {
    final counts = <int, int>{};
    final buffer = _terminal.buffer;
    final first = buffer.height - buffer.viewHeight;
    for (var y = first; y < buffer.height; y++) {
      final line = buffer.lines[y];
      final edgeRow = y == first || y == buffer.height - 1;
      for (var x = 0; x < line.length; x++) {
        if (!edgeRow && x != 0 && x != line.length - 1) continue;
        final bg = line.getBackground(x);
        counts[bg] = (counts[bg] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return;
    final top = counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    final background = switch (top & CellColor.typeMask) {
      CellColor.normal => null,
      CellColor.rgb => Color(top & CellColor.valueMask | 0xFF000000),
      _ => _palette[top & CellColor.valueMask],
    };
    if (background != _background) setState(() => _background = background);
  }

  /// Back to the bottom of the pane's history. Herdr's own scrollback takes a scroll's line count, so
  /// one scroll long enough reaches the bottom (herdr caps it at a u16); an app on the alternate screen
  /// (Claude Code) gets each scroll as one wheel tick whatever its count, so it needs as many ticks back
  /// as went up. Send twice that: going past the bottom does nothing, falling short leaves the view up.
  void _toLive() {
    if (_scrolledUp == 0) return;
    for (var i = 0; i < 2 * _scrolledUp; i++) {
      _ptyChannel?.sendScroll(-65535);
    }
    setState(() => _scrolledUp = 0);
  }

  /// Raw pointers, so the swipe works over the message box too, whose own drags would win the arena.
  /// A drag that is mostly sideways moves the terminal with the finger.
  void _trackSwipe(PointerEvent e) {
    // Swiping between agents is a one-finger (left-button) gesture; right/middle drags select text.
    if (_isMouseSecondary(e)) {
      _swipeFrom = null;
      _swiping = false;
      return;
    }
    final width = context.size!.width;
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

  /// The agent running in a tab (focused pane's first), or null if it runs none.
  AgentModel? _tabAgent(TabModel tab) {
    final snapshot = widget.client.snapshot;
    if (snapshot == null) return null;
    final panes = snapshot.panes.where((p) => p.tabId == tab.id).toList();
    final focusedPane = panes.where((p) => p.focused).firstOrNull ?? panes.firstOrNull;
    if (focusedPane != null) {
      final agent = snapshot.agents.where((a) => a.paneId == focusedPane.id).firstOrNull;
      if (agent != null) return agent;
    }
    final paneIds = {for (final p in panes) p.id};
    return snapshot.agents.where((a) => paneIds.contains(a.paneId)).firstOrNull;
  }

  /// A concise summary of what's happening in [tab]: the terminal title of its focused pane,
  /// or the running agent's name, falling back to the tab's display name.
  String _tabSummary(TabModel tab) {
    final snapshot = widget.client.snapshot;
    if (snapshot == null) return tab.displayName;
    final panes = snapshot.panes.where((p) => p.tabId == tab.id).toList();
    final pane = panes.where((p) => p.focused).firstOrNull ?? panes.firstOrNull;
    if (pane != null && pane.terminalTitle.isNotEmpty) {
      return pane.terminalTitle;
    }
    final agent = _tabAgent(tab);
    if (agent != null && agent.name.isNotEmpty) {
      return agent.name;
    }
    return tab.displayName;
  }

  /// Desktop right-click on a tab: select it, close it, or move it without long-press dragging.
  Future<void> _showTabMenu(TapUpDetails details, TabModel tab, List<TabModel> tabs, int index) async {
    final client = widget.client;
    final at = details.globalPosition;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.tab), title: Text('Open tab'))),
        if (index > 0)
          const PopupMenuItem(
              value: 'left', child: ListTile(leading: Icon(Icons.arrow_back), title: Text('Move left'))),
        if (index < tabs.length - 1)
          const PopupMenuItem(
              value: 'right', child: ListTile(leading: Icon(Icons.arrow_forward), title: Text('Move right'))),
        const PopupMenuItem(
            value: 'close', child: ListTile(leading: Icon(Icons.close), title: Text('Close tab'))),
      ],
    );
    switch (picked) {
      case 'open':
        client.selectTab(tab.id);
      case 'left':
        if (index > 0) client.moveTab(tab.id, tabs[index - 1].id);
      case 'right':
        if (index < tabs.length - 1) client.moveTab(tab.id, tabs[index + 1].id);
      case 'close':
        client.closeTab(tab.id);
    }
  }

  /// The workspace's tabs, and the current one's index in them.
  (List<TabModel>, int)? _tabs() {
    final snapshot = widget.client.snapshot;
    final pane = widget.client.selectedPane;
    if (pane == null) return null;
    final tabs = snapshot!.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
    return (tabs, tabs.indexWhere((t) => t.id == pane.tabId));
  }

  /// Where a sideways swipe goes: every agent on every connected machine, each machine's in herdr's order
  /// (workspace, tab, pane), as labels and how to show each, with the current one's index. The pane on
  /// screen is among them even when it runs no agent, so a plain shell still has neighbours.
  (List<(String, VoidCallback)>, int)? _stops() {
    final client = widget.client;
    final current = client.selectedPane;
    if (current == null) return null;
    final stops = <(String, VoidCallback)>[];
    var at = -1;
    for (final m in client.machines) {
      final snapshot = client.snapshotOf(m);
      if (client.isOff(m) || snapshot == null) continue;
      final here = m == client.machine;
      final ws = [for (final w in snapshot.workspaces) w.id];
      final tabs = [for (final t in snapshot.tabs) t.id];
      final names = {for (final a in snapshot.agents) a.paneId: a.name};
      final wsName = {for (final w in snapshot.workspaces) w.id: w.displayName};
      final order = snapshot.panes.indexOf;
      final panes = snapshot.panes.where((p) => names.containsKey(p.id) || here && p.id == current.id).toList()
        ..sort((a, b) => [
              ws.indexOf(a.workspaceId).compareTo(ws.indexOf(b.workspaceId)),
              tabs.indexOf(a.tabId).compareTo(tabs.indexOf(b.tabId)),
              order(a).compareTo(order(b)),
            ].firstWhere((c) => c != 0, orElse: () => 0));
      for (final p in panes) {
        if (here && p.id == current.id) at = stops.length;
        final tabNumber = snapshot.tabs.where((t) => t.id == p.tabId).firstOrNull?.number ?? 1;
        stops.add((
          [
            if (!here) client.nameOf(m),
            if (!here || p.workspaceId != current.workspaceId) wsName[p.workspaceId],
            names[p.id] ?? '${wsName[p.workspaceId]} ($tabNumber)',
          ].whereType<String>().join(' · '),
          () {
            if (client.machine != m) client.switchMachine(m);
            client.selectPane(p.id);
          },
        ));
      }
    }
    return (stops, at);
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
    // herdr repaints every cell, blanks included, so each row ends in spaces up to the terminal's width.
    // And agents wrap their own text into rows, continued indented, so a row is joined to the next when
    // that one is indented, isn't a list item, and its first word wouldn't have fit on this row.
    final selection = _controller.selection!.normalized;
    final lines = _terminal.buffer.lines;
    final text = StringBuffer();
    var joined = false;
    for (final segment in selection.toSegments()) {
      final row = segment.line;
      if (row < 0 || row >= lines.length) continue;
      final part = lines[row].getText(segment.start, segment.end).trimRight();
      text.write(joined ? part.trimLeft() : part);
      if (row == selection.end.y || row + 1 >= lines.length) break;
      final line = lines[row].getText().trimRight();
      final next = RegExp(r'^( +)(?![-*•] |\d+[.)] )(\S+)').firstMatch(lines[row + 1].getText());
      joined = line.trim().isNotEmpty &&
          next != null &&
          next[1]!.length >= line.length - line.trimLeft().length &&
          line.length + 1 + next[2]!.length >= _terminal.viewWidth;
      text.write(joined ? ' ' : '\n');
    }
    Clipboard.setData(ClipboardData(text: text.toString()));
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

  /// Right/middle mouse buttons never start pinch-zoom or history scrolling: they are
  /// for selection and the context menu. Up/cancel still clears the tracked pointer.
  bool _isMouseSecondary(PointerEvent e) =>
      e.kind == PointerDeviceKind.mouse &&
      e is! PointerUpEvent &&
      e is! PointerCancelEvent &&
      (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0;

  /// Desktop context menu: copy the selection, paste the clipboard, select all.
  /// Right-click never clears the selection, unlike a left tap.
  Future<void> _showTerminalMenu(TapDownDetails details) async {
    final hasSelection = _controller.selection != null;
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final canPaste =
        (clipboard?.text?.isNotEmpty ?? false) && _ptyChannel != null && widget.client.connected;
    if (!mounted) return;
    final at = details.globalPosition;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (hasSelection)
          const PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.content_copy), title: Text('Copy'))),
        if (canPaste)
          const PopupMenuItem(value: 'paste', child: ListTile(leading: Icon(Icons.content_paste), title: Text('Paste'))),
        const PopupMenuItem(
            value: 'selectAll', child: ListTile(leading: Icon(Icons.select_all), title: Text('Select all'))),
        if (hasSelection)
          const PopupMenuItem(
              value: 'clear', child: ListTile(leading: Icon(Icons.clear), title: Text('Clear selection'))),
      ],
    );
    switch (picked) {
      case 'copy':
        _copySelection();
      case 'paste':
        _pasteFromClipboard(clipboard?.text);
      case 'selectAll':
        _selectAll();
      case 'clear':
        _controller.clearSelection();
    }
  }

  /// Pastes clipboard text as one bracketed paste (like the message box), then Enter is left to the user.
  void _pasteFromClipboard(String? text) {
    if (text == null || text.isEmpty) return;
    _toLive();
    _ptyChannel?.sendInput(_terminal.bracketedPasteMode ? '\x1b[200~$text\x1b[201~' : text);
  }

  /// Selects the visible screen, like xterm's own Select-all action.
  void _selectAll() {
    final buffer = _terminal.buffer;
    final top = buffer.height - _terminal.viewHeight;
    _controller.setSelection(
      buffer.createAnchor(0, top < 0 ? 0 : top),
      buffer.createAnchor(_terminal.viewWidth, buffer.height - 1),
    );
    setState(() {});
  }

  void _trackPointer(PointerEvent e) {
    if (_isMouseSecondary(e)) return;
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
    if (!widget.client.pinchZoom) {
      _pinched = true;
      return;
    }
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
    // Counts scrolls, not lines: an app on the alternate screen moves a wheel tick per scroll, however
    // many lines it carries (see [_toLive]). Herdr stops at the bottom, so the count does too; it may
    // overshoot the top, which only means the way back scrolls further than needed. Capped, since the
    // way back sends a scroll per count.
    setState(() => _scrolledUp = (_scrolledUp + lines.sign).clamp(0, 1000));
  }

  /// Parks the box's text as the current pane's draft and brings back [key]'s.
  void _swapDraft(String? key) {
    if (_draftKey != null) TerminalScreen._drafts[_draftKey!] = _message.text;
    TerminalScreen._drafts.removeWhere((_, text) => text.isEmpty);
    _draftKey = key;
    final text = TerminalScreen._drafts[key] ?? '';
    _message.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  void _onClientUpdate() {
    if (!mounted) return;
    // Each pane keeps its own draft: park the box's text and bring back the new pane's.
    final paneId = widget.client.selectedPaneId;
    final key = paneId == null ? null : '${widget.client.machine}/$paneId';
    if (key != _draftKey) _swapDraft(key);
    // Switched off (e.g. from the notification) or removed: nothing to show, so back to the agents, once.
    final client = widget.client;
    if ((client.isDisconnected || !client.machines.contains(client.machine)) && !_left && !widget.embedded) {
      _left = true;
      Navigator.maybePop(context);
    }
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
    if (pty != null && pty.paneId == paneId && pty.machine == client.machine) return;
    pty?.dispose();
    _ptyChannel = PtyChannel(
      machine: client.machine,
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
    _onMessageChanged();
    _message.removeListener(_onMessageChanged);
    _slide.dispose();
    _lifecycle.dispose();
    widget.client.removeListener(_onClientUpdate);
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
    final background = _background ?? scheme.surface;
    // The message bar's own buttons sit on the pane's background, which may be light in a dark theme or dark
    // in a light one: then they take the inverse colour.
    final onBackground = ThemeData.estimateBrightnessForColor(background) == scheme.brightness
        ? Theme.of(context)
        : Theme.of(context).copyWith(
            colorScheme: scheme.copyWith(onSurfaceVariant: scheme.onInverseSurface, primary: scheme.onInverseSurface),
          );
    final snapshot = client.snapshot;
    final pane = client.selectedPane;
    final workspace = snapshot?.workspaces.where((w) => w.id == pane?.workspaceId).firstOrNull;
    final connecting = client.machines.isNotEmpty && !client.connected && !client.isDisconnected;
    if (pane?.tabId != _shownTabId) {
      _shownTabId = pane?.tabId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final tab = _currentTab.currentContext;
        if (tab != null) Scrollable.ensureVisible(tab, alignment: 0.5, duration: const Duration(milliseconds: 200));
      });
    }

    final isWorktree = workspace?.isLinkedWorktree ?? false;
    final mainRepo = isWorktree
        ? snapshot?.workspaces.where((w) => !w.isLinkedWorktree && w.repoKey == workspace?.repoKey).firstOrNull
        : null;
    final title =
        (isWorktree ? mainRepo?.displayName : workspace?.displayName) ?? workspace?.displayName ?? 'workspace';
    final branch = isWorktree
        ? (workspace?.gitBranch?.replaceFirst('worktree/', '') ?? workspace?.displayName ?? '')
        : (workspace?.gitBranch ?? '');

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        // Beside the back button; embedded, with none, the usual inset from the agents.
        titleSpacing: widget.embedded ? NavigationToolbar.kMiddleSpacing : 0,
        // The terminal isn't content scrolling under the bar: keep the bar's colour when it scrolls.
        notificationPredicate: (_) => false,
        // A step above the terminal's surface, so the current tab stands out joined to the terminal.
        backgroundColor: scheme.surfaceContainerHigh,
        // The workspace header: tapping it opens the workspace's actions.
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: workspace == null
              ? null
              : () => showWorkspaceActions(context, client, workspace,
                  onDelete: widget.embedded ? null : () => Navigator.maybePop(context)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
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
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
                if (branch.isNotEmpty)
                  Text(
                    branch,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              backgroundColor: scheme.secondaryContainer,
              side: BorderSide.none,
              labelStyle: TextStyle(color: scheme.onSecondaryContainer),
              avatar: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: switch (client.machine) {
                    final m when client.isOff(m) => scheme.onSurfaceVariant,
                    final m when client.errorOf(m) != null => scheme.error,
                    final m when client.isConnected(m) => Colors.green,
                    _ => Colors.orange,
                  },
                  shape: BoxShape.circle,
                ),
              ),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  client.nameOf(client.machine),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              onPressed: () => showMachineDialog(context, client, client.machine),
              tooltip: '${client.nameOf(client.machine)} · ${machineStatus(client, client.machine)}',
            ),
          ),
        ],
        // The workspace's tabs, like Vivaldi's: equal 168dp tabs, scrolling when they overflow.
        // The current one is rounded on top and takes the terminal's color, joined to it below.
        // Each shows its agent icon with an online status ring and truncated tab summary. Long-press a tab to move or close it.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          // While connecting, a thin progress bar over the strip's top edge, taking no room of its own.
          child: Stack(
            children: [
              SizedBox(
                height: 34,
                child: switch (_tabs()) {
                  (final tabs, final i) when i >= 0 => Row(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final (j, t) in tabs.indexed)
                                  // Long-press and drag a tab onto another to take its place, or onto
                                  // the bin.
                                  DragTarget<String>(
                                    onWillAcceptWithDetails: (d) => d.data != t.id,
                                    onAcceptWithDetails: (d) => client.moveTab(d.data, t.id),
                                    builder: (context, over, _) {
                                      final tabAgent = _tabAgent(t);
                                      final label = Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            AgentAvatar(name: tabAgent?.name ?? '', radius: 7.5, status: t.agentStatus),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: Text(
                                                _tabSummary(t),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                                    color: j == i ? scheme.onSurface : scheme.onSurfaceVariant),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                      const top = BorderRadius.vertical(top: Radius.circular(10));
                                      return LongPressDraggable<String>(
                                        data: t.id,
                                        axis: Axis.horizontal,
                                        onDragStarted: () => setState(() => _draggedTab = t.id),
                                        onDragEnd: (_) => setState(() => _draggedTab = null),
                                        feedback: Material(
                                          color: scheme.secondaryContainer,
                                          elevation: 3,
                                          borderRadius: top,
                                          child: SizedBox(
                                            height: 34,
                                            width: 168,
                                            child: label,
                                          ),
                                        ),
                                        childWhenDragging: Opacity(opacity: 0.3, child: label),
                                        child: GestureDetector(
                                          onSecondaryTapUp: (d) => _showTabMenu(d, t, tabs, j),
                                          child: Container(
                                            key: j == i ? _currentTab : null,
                                            width: 168,
                                            decoration: over.isNotEmpty
                                                ? BoxDecoration(color: scheme.secondaryContainer, borderRadius: top)
                                                : j == i
                                                    ? BoxDecoration(color: background, borderRadius: top)
                                                    : null,
                                            child: InkWell(
                                              customBorder: const RoundedRectangleBorder(borderRadius: top),
                                              onTap: () => client.selectTab(t.id),
                                              child: label,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ),
                        // While a tab is dragged, a bin: drop it there to close it.
                        DragTarget<String>(
                          onAcceptWithDetails: (d) => client.closeTab(d.data),
                          builder: (context, over, _) => IconButton(
                            tooltip: _draggedTab == null ? 'New tab' : 'Close tab',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(width: 40, height: 34),
                            iconSize: 18,
                            color: _draggedTab == null ? null : scheme.error,
                            style: over.isEmpty ? null : IconButton.styleFrom(backgroundColor: scheme.errorContainer),
                            icon: Icon(_draggedTab == null ? Icons.add : Icons.delete_outline),
                            onPressed: () => client.createTab(tabs[i].workspaceId),
                          ),
                        ),
                      ],
                    ),
                  _ => null,
                },
              ),
              if (connecting) const LinearProgressIndicator(minHeight: 2),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              // Connected to its bridge, which can't show it: e.g. a machine it reaches over SSH is down.
              child: client.errorOf(client.machine) != null && snapshot == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.cloud_off, size: 48, color: scheme.onSurfaceVariant),
                            const SizedBox(height: 12),
                            Text("Can't reach ${client.nameOf(client.machine)}",
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 8),
                            Text(client.errorOf(client.machine)!,
                                textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                          ],
                        ),
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
                                  Text(stops[(i - 1) % stops.length].$1, style: Theme.of(context).textTheme.labelLarge),
                                  const Spacer(),
                                  Text(stops[(i + 1) % stops.length].$1, style: Theme.of(context).textTheme.labelLarge),
                                  const Icon(Icons.chevron_right),
                                ],
                              ),
                            ),
                          ),
                        Positioned.fill(
                          child: AnimatedBuilder(
                            animation: _slide,
                            // Clipped, so sliding out doesn't paint over the agents beside it on a wide screen.
                            builder: (_, child) => ClipRect(
                                child: FractionalTranslation(translation: Offset(_slide.value, 0), child: child)),
                            child: Listener(
                              onPointerDown: _trackPointer,
                              onPointerMove: _trackPointer,
                              onPointerUp: _trackPointer,
                              onPointerCancel: _trackPointer,
                              onPointerSignal: _scrollSignal,
                              onPointerPanZoomUpdate: _scrollSignal,
                              // Embedded, a little room from the agents and the screen's edge, in the pane's colour.
                              child: Container(
                                  color: background,
                                  padding: EdgeInsets.symmetric(horizontal: widget.embedded ? 4 : 0),
                                  child: TerminalView(
                                    _terminal,
                                    key: _view,
                                    controller: _controller,
                                    onSecondaryTapDown: (details, _) => _showTerminalMenu(details),
                                    backgroundOpacity: 1.0,
                                    // xterm's default colours, on the app's surface.
                                    theme: TerminalTheme(
                                      cursor: _defaultTheme.cursor,
                                      selection: _defaultTheme.selection,
                                      foreground: scheme.onSurface,
                                      background: scheme.surface,
                                      black: _defaultTheme.black,
                                      white: _defaultTheme.white,
                                      red: _defaultTheme.red,
                                      green: _defaultTheme.green,
                                      yellow: _defaultTheme.yellow,
                                      blue: _defaultTheme.blue,
                                      magenta: _defaultTheme.magenta,
                                      cyan: _defaultTheme.cyan,
                                      brightBlack: _defaultTheme.brightBlack,
                                      brightRed: _defaultTheme.brightRed,
                                      brightGreen: _defaultTheme.brightGreen,
                                      brightYellow: _defaultTheme.brightYellow,
                                      brightBlue: _defaultTheme.brightBlue,
                                      brightMagenta: _defaultTheme.brightMagenta,
                                      brightCyan: _defaultTheme.brightCyan,
                                      brightWhite: _defaultTheme.brightWhite,
                                      searchHitBackground: _defaultTheme.searchHitBackground,
                                      searchHitBackgroundCurrent: _defaultTheme.searchHitBackgroundCurrent,
                                      searchHitForeground: _defaultTheme.searchHitForeground,
                                    ),
                                    textStyle: TerminalStyle(
                                      fontSize: client.fontSize,
                                      fontFamily: 'MesloLGS Nerd Font Mono',
                                      height: 1.1,
                                    ),
                                    autofocus: true,
                                    simulateScroll: false,
                                  )),
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
            // Swipe sideways here to move between agents in herdr's order, machine by machine. The keyboard
            // button swaps the message box for the control keys and back. It takes the terminal's background.
            if (!client.hideMessageTerminal)
              Listener(
                onPointerDown: _trackSwipe,
                onPointerMove: _trackSwipe,
                onPointerUp: _trackSwipe,
                onPointerCancel: _trackSwipe,
                child: Container(
                  color: background,
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                  child: Row(
                    children: [
                      Theme(
                        data: onBackground,
                        child: IconButton(
                          tooltip: client.keyBar ? 'Message box' : 'Control keys',
                          isSelected: client.keyBar,
                          icon: const Icon(Icons.keyboard_outlined),
                          selectedIcon: const Icon(Icons.keyboard_hide_outlined),
                          onPressed: () => client.setKeyBar(!client.keyBar),
                        ),
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
                                  fillColor: scheme.secondaryContainer,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    borderSide: BorderSide.none,
                                  ),
                                  prefixIcon: IconButton(
                                    tooltip: 'Quick replies and history',
                                    icon: const Icon(Icons.history),
                                    onPressed: _showHistory,
                                  ),
                                ),
                              ),
                      ),
                      if (!client.keyBar) ...[
                        const SizedBox(width: 6),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _message,
                          builder: (context, val, _) => IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: scheme.primary,
                              foregroundColor: scheme.onPrimary,
                            ),
                            tooltip: val.text.isEmpty ? 'Enter' : 'Send',
                            icon: Icon(val.text.isEmpty ? Icons.keyboard_return : Icons.send_rounded),
                            onPressed: _sendMessage,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
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
