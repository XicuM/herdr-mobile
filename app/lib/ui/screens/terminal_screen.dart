import 'dart:io';
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

  final VoidCallback? onOpenDrawer;
  final VoidCallback? onOpenMachines;
  final VoidCallback? onOpenSearch;

  const TerminalScreen({
    super.key,
    required this.client,
    this.embedded = false,
    this.onOpenDrawer,
    this.onOpenMachines,
    this.onOpenSearch,
  });

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

class _TerminalScreenState extends State<TerminalScreen> {
  final _terminal = Terminal();
  final _controller = TerminalController();
  final _view = GlobalKey<TerminalViewState>();
  final _message = TextEditingController();
  final _messageFocus = FocusNode();
  int _historyIndex = -1;
  String _savedDraft = '';
  PtyChannel? _ptyChannel;
  late final AppLifecycleListener _lifecycle;
  bool _ctrl = false;
  List<String> _history = []; // sent messages, newest first, shared by every pane
  String? _draftKey; // the pane whose draft is in the message box
  int _scrolledUp = 0; // scrolls back into the pane's history; 0 is live
  bool _left = false; // popped back to the agents, since the machine went off

  // Pinch-to-zoom, two-finger swipes between agents and history scrolling, tracked from raw pointers so
  // they don't fight the terminal's own gestures.
  final _pointers = <int, Offset>{};
  Offset? _twoAt; // where two fingers' midpoint started, while two are down
  double _twoDistance = 0; // and how far apart they were
  bool? _swiping; // what two fingers do: null until they pinch (false) or move sideways together (true)
  bool _swiped = false; // the swipe has switched agent; once a gesture
  double _swipeDx = 0; // how far the terminal follows a swipe, before it switches
  Offset _padPan = Offset.zero; // a touchpad's two-finger pan so far, until it picks an axis
  Axis? _padAxis;
  double _pinchFont = 0;
  Offset _downAt = Offset.zero;
  Duration _downTime = Duration.zero;
  bool _dragging = false; // set once a one-finger drag counts as a scroll
  double _scrollRest = 0; // scrolled pixels not yet a whole line
  bool _pinched = false; // the rest of a gesture that pinched never scrolls

  // The current tab in the top bar's strip, scrolled into view when it changes.
  final _currentTab = GlobalKey();
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
    _messageFocus.onKeyEvent = _onMessageKeyEvent;
    _controller.addListener(() => setState(() {})); // shows the Copy button while text is selected
    widget.client.addListener(_onClientUpdate);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // The app now keeps running in the background (for alerts), so the pane is attached only while shown.
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _connectTerminal());
    _connectTerminal();
    if (widget.client.selectedPaneId case final paneId?) _swapDraft('${widget.client.machine}/$paneId');
    SharedPreferences.getInstance().then((p) => _history = p.getStringList('message_history') ?? []);
  }

  KeyEventResult _onMessageKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_history.isNotEmpty) {
        if (_historyIndex == -1) _savedDraft = _message.text;
        if (_historyIndex + 1 < _history.length) {
          setState(() {
            _historyIndex++;
            final text = _history[_historyIndex];
            _message.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
          });
          return KeyEventResult.handled;
        }
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_historyIndex > 0) {
        setState(() {
          _historyIndex--;
          final text = _history[_historyIndex];
          _message.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
        });
        return KeyEventResult.handled;
      } else if (_historyIndex == 0) {
        setState(() {
          _historyIndex = -1;
          _message.value = TextEditingValue(
            text: _savedDraft,
            selection: TextSelection.collapsed(offset: _savedDraft.length),
          );
        });
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _onMessageChanged() {
    if (_historyIndex != -1 && (_historyIndex >= _history.length || _message.text != _history[_historyIndex])) {
      _historyIndex = -1;
    }
    if (_draftKey != null) {
      if (_message.text.isNotEmpty) {
        TerminalScreen._drafts[_draftKey!] = _message.text;
      } else {
        TerminalScreen._drafts.remove(_draftKey);
      }
    }
  }

  /// Alt keybindings, volume keys, and Ctrl +/- zoom handling while this screen is active.
  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    final client = widget.client;
    final isAlt = HardwareKeyboard.instance.isAltPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isCtrl = HardwareKeyboard.instance.isControlPressed;

    if (isAlt && !isCtrl) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (event is! KeyUpEvent) {
          if (isShift) {
            client.moveTabPrevious();
          } else {
            client.previousTab();
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        if (event is! KeyUpEvent) {
          if (isShift) {
            client.moveTabNext();
          } else {
            client.nextTab();
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        if (event is! KeyUpEvent) client.previousWorkspace();
        return true;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        if (event is! KeyUpEvent) client.nextWorkspace();
        return true;
      }
      if (key == LogicalKeyboardKey.escape) {
        if (event is! KeyUpEvent) {
          final pane = client.selectedPane;
          if (pane != null) {
            if (!widget.embedded && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
            client.closePane(pane.id);
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyT) {
        if (event is! KeyUpEvent) {
          final wsId = client.selectedPane?.workspaceId ?? client.snapshot?.workspaces.firstOrNull?.id;
          if (wsId != null) client.createTab(wsId);
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyG) {
        if (event is! KeyUpEvent) {
          if (widget.onOpenSearch != null) {
            widget.onOpenSearch!();
          } else if (!widget.embedded && Navigator.canPop(context)) {
            Navigator.pop(context, 'search');
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyO) {
        if (event is! KeyUpEvent) client.jumpToAttention();
        return true;
      }
      if (key == LogicalKeyboardKey.keyB) {
        if (event is! KeyUpEvent) {
          if (widget.onOpenDrawer != null) {
            widget.onOpenDrawer!();
          } else if (!widget.embedded && Navigator.canPop(context)) {
            Navigator.pop(context, 'drawer');
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyM) {
        if (event is! KeyUpEvent) {
          if (widget.onOpenMachines != null) {
            widget.onOpenMachines!();
          } else if (!widget.embedded && Navigator.canPop(context)) {
            Navigator.pop(context, 'machines');
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyH) {
        if (event is! KeyUpEvent) {
          if (!widget.embedded && Navigator.canPop(context)) {
            Navigator.pop(context);
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyI) {
        if (event is! KeyUpEvent) {
          if (_messageFocus.hasFocus) {
            _messageFocus.unfocus();
          } else {
            _messageFocus.requestFocus();
          }
        }
        return true;
      }

      final digit = switch (key) {
        LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => 1,
        LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => 2,
        LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => 3,
        LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => 4,
        LogicalKeyboardKey.digit5 || LogicalKeyboardKey.numpad5 => 5,
        LogicalKeyboardKey.digit6 || LogicalKeyboardKey.numpad6 => 6,
        LogicalKeyboardKey.digit7 || LogicalKeyboardKey.numpad7 => 7,
        LogicalKeyboardKey.digit8 || LogicalKeyboardKey.numpad8 => 8,
        LogicalKeyboardKey.digit9 || LogicalKeyboardKey.numpad9 => 9,
        _ => null,
      };
      if (digit != null && !isShift) {
        if (event is! KeyUpEvent) client.selectTabAt(digit - 1);
        return true;
      }
    }

    if (isCtrl) {
      final isZoomIn =
          key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd;
      final isZoomOut = key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract;
      final isZoomReset = key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0;

      if (isZoomIn || isZoomOut || isZoomReset) {
        if (event is! KeyUpEvent) {
          if (isZoomIn) {
            client.setFontSize(client.fontSize + 1);
          } else if (isZoomOut) {
            client.setFontSize(client.fontSize - 1);
          } else if (isZoomReset) {
            client.setFontSize(14);
          }
        }
        return true;
      }
    }

    if (key != LogicalKeyboardKey.audioVolumeUp && key != LogicalKeyboardKey.audioVolumeDown) return false;
    if (client.volumeKeys == VolumeKeys.volume) return false;
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
    _historyIndex = -1;
    _savedDraft = '';
    if (quickReply != null) return;
    _message.clear();
    if (text.trim().isEmpty) return;
    _history = [text, ..._history.where((h) => h != text)].take(30).toList();
    SharedPreferences.getInstance().then((p) => p.setStringList('message_history', _history));
  }

  /// Quick replies, sent as soon as picked, and earlier messages, which go in the message box to edit or send.
  void _showHistory() {
    void pick(String text) {
      _historyIndex = -1;
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

  static Color _quotaColor(ColorScheme scheme, AgentUsage? usage) {
    if (usage == null || usage.limits.isEmpty) {
      return scheme.onSurfaceVariant.withAlpha(128);
    }
    final pct = usage.highestPercent ?? 0.0;
    if (pct >= 0.90) return scheme.error;
    if (pct >= 0.75) return Colors.orange;
    return Colors.green;
  }

  static String _formatResetTime(String raw) {
    try {
      final parsed = DateTime.parse(raw).toLocal();
      final diff = parsed.difference(DateTime.now());
      if (diff.isNegative) return 'shortly';
      if (diff.inHours > 24) {
        final days = (diff.inHours / 24).ceil();
        return 'in $days ${days == 1 ? 'day' : 'days'}';
      }
      if (diff.inHours > 0) {
        final m = diff.inMinutes % 60;
        return 'in ${diff.inHours}h ${m}m';
      }
      if (diff.inMinutes > 0) {
        return 'in ${diff.inMinutes}m';
      }
      return 'in < 1m';
    } catch (_) {
      return raw;
    }
  }

  static String _formatTokens(int count) {
    if (count >= 1000000000) return '${(count / 1000000000).toStringAsFixed(1)}B';
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}k';
    return '$count';
  }

  void _showUsage(AgentModel? agent, AgentUsage? usage) {
    _messageFocus.unfocus();
    FocusScope.of(context).unfocus();
    showModalBottomSheet(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final title = agent?.name.isNotEmpty == true ? agent!.name : 'Agent';
        final tier = usage?.tierLabel;
        final limits = usage?.limits ?? [];

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AgentAvatar(name: agent?.name ?? '', radius: 14),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                          if (tier != null && tier.isNotEmpty)
                            Text(tier, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (limits.isNotEmpty) ...[
                  for (final limit in limits) ...[
                    Builder(builder: (context) {
                      final leftPct = ((1.0 - limit.percent).clamp(0.0, 1.0) * 100).round();
                      final usedPct = (limit.percent.clamp(0.0, 1.0) * 100).round();
                      final statusColor = limit.percent >= 0.90
                          ? scheme.error
                          : limit.percent >= 0.75
                              ? Colors.orange
                              : Colors.green;
                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  limit.label,
                                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  '$leftPct% left',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: statusColor,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: limit.percent.clamp(0.0, 1.0),
                                minHeight: 8,
                                backgroundColor: scheme.surfaceContainerHighest,
                                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '$usedPct% used',
                                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                                if (limit.resetsAt != null && limit.resetsAt!.isNotEmpty)
                                  Text(
                                    'Resets ${_formatResetTime(limit.resetsAt!)}',
                                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ] else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No active rate limits recorded for this agent.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (usage?.todayTokens != null || usage?.todayPrompts != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        if (usage?.todayTokens case final tokens?)
                          Column(
                            children: [
                              Text(_formatTokens(tokens),
                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                              Text('Tokens today',
                                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        if (usage?.todayPrompts case final prompts?)
                          Column(
                            children: [
                              Text('$prompts',
                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                              Text('Prompts today',
                                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Takes the background most of the screen's edge cells have as [_background]: the top and bottom rows
  /// and the outer columns, which meet the tab strip and the message bar. What's drawn in the middle (a
  /// diff, a selection) doesn't sway it. The default counts as the theme's.
  void _findBackground() {
    final counts = <int, int>{};
    final buffer = _terminal.buffer;
    final first = buffer.height - buffer.viewHeight;
    // Runs on every frame the pane sends, so it visits only those cells.
    for (var y = first; y < buffer.height; y++) {
      final line = buffer.lines[y];
      final edgeRow = y == first || y == buffer.height - 1;
      final last = line.length - 1;
      for (var x = 0; x <= last; x = edgeRow || x == last ? x + 1 : last) {
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

  /// A tab's menu, from the current tab's ⋮ or a right-click on any: select it, move it, or close it.
  Future<void> _showTabMenu(Offset at, TabModel tab, List<TabModel> tabs, int index) async {
    final client = widget.client;
    final scheme = Theme.of(context).colorScheme;
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
        PopupMenuItem(
          value: 'close',
          child: ListTile(
            leading: Icon(Icons.close, color: scheme.error),
            title: Text('Close tab', style: TextStyle(color: scheme.error)),
          ),
        ),
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
    final canPaste = (clipboard?.text?.isNotEmpty ?? false) && _ptyChannel != null && widget.client.connected;
    if (!mounted) return;
    final at = details.globalPosition;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (hasSelection)
          const PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.content_copy), title: Text('Copy'))),
        if (canPaste)
          const PopupMenuItem(
              value: 'paste', child: ListTile(leading: Icon(Icons.content_paste), title: Text('Paste'))),
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
      _twoAt = null;
      if (_swipeDx != 0) setState(() => _swipeDx = 0);
      return;
    }
    _pinched = true; // the rest of the gesture never scrolls
    final p = _pointers.values.toList();
    final distance = (p[0] - p[1]).distance;
    final centre = (p[0] + p[1]) / 2;
    if (_twoAt == null) {
      _twoAt = centre;
      _twoDistance = distance;
      _pinchFont = widget.client.fontSize;
      _swiping = null;
      _swiped = false;
      return;
    }
    // Fingers moving sideways together swipe; moving apart or together pinch, whichever shows first.
    final dx = centre.dx - _twoAt!.dx;
    final stretch = distance - _twoDistance;
    _swiping ??= dx.abs() > kPanSlop && dx.abs() > stretch.abs()
        ? true
        : stretch.abs() > kPanSlop && widget.client.pinchZoom
            ? false
            : null;
    if (_swiping == false) widget.client.setFontSize((_pinchFont * distance / _twoDistance).roundToDouble());
    if (_swiping == true) _swipe(dx);
  }

  /// Where a swipe [step] agents along leads, named as the list does: the agent's summary, then where it is.
  String? _peek(int step) {
    final client = widget.client;
    final (m, paneId) = client.agentAt(step) ?? ('', '');
    final snapshot = client.snapshotOf(m);
    final pane = snapshot?.panes.where((p) => p.id == paneId).firstOrNull;
    if (pane == null) return null;
    final agent = snapshot!.agents.where((a) => a.paneId == paneId).firstOrNull;
    final place = [snapshot.placeOf(pane), if (m != client.machine) client.nameOf(m)].join(' · ');
    return '${pane.terminalTitle.isNotEmpty ? pane.terminalTitle : agent?.name ?? ''}\n$place';
  }

  /// Two fingers have moved [dx] sideways together: the terminal follows them a little, and past a threshold,
  /// once a gesture, shows the next agent (fingers going left, as a page turns) or the previous ([stepAgent]).
  void _swipe(double dx) {
    if (_swiped) return;
    if (dx.abs() < 80) return setState(() => _swipeDx = dx / 2);
    _swiped = true;
    setState(() => _swipeDx = 0);
    HapticFeedback.selectionClick();
    widget.client.stepAgent(dx < 0 ? 1 : -1);
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

  /// A mouse wheel scrolls herdr's view like a drag does, and so does a desktop touchpad's two-finger pan
  /// up or down; sideways, it swipes between agents as two fingers on a phone do. A pan keeps the axis
  /// it first moves along.
  void _scrollSignal(PointerEvent e) {
    if (e is PointerScrollEvent) _scrollBy(-e.scrollDelta.dy);
    if (e is PointerPanZoomStartEvent) {
      _padPan = Offset.zero;
      _padAxis = null;
      _swiped = false;
    }
    if (e is PointerPanZoomEndEvent && _swipeDx != 0) setState(() => _swipeDx = 0);
    if (e is! PointerPanZoomUpdateEvent) return;
    _padPan += e.panDelta;
    if (_padAxis == null && _padPan.distance > kTouchSlop) {
      _padAxis = _padPan.dx.abs() > _padPan.dy.abs() ? Axis.horizontal : Axis.vertical;
      if (_padAxis == Axis.vertical) return _scrollBy(_padPan.dy);
    }
    if (_padAxis == Axis.vertical) _scrollBy(e.panDelta.dy);
    if (_padAxis == Axis.horizontal) _swipe(_padPan.dx);
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
    final headers = client.headersOf(client.machine);
    // A new token for the machine reconnects too.
    if (pty != null &&
        pty.paneId == paneId &&
        pty.machine == client.machine &&
        pty.headers[HttpHeaders.authorizationHeader] == headers[HttpHeaders.authorizationHeader]) {
      return;
    }
    pty?.dispose();
    _ptyChannel = PtyChannel(
      machine: client.machine,
      paneId: paneId,
      terminal: _terminal,
      headers: headers,
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
    _messageFocus.dispose();
    _lifecycle.dispose();
    widget.client.removeListener(_onClientUpdate);
    _controller.dispose();
    _message.dispose();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _ptyChannel?.dispose();
    super.dispose();
  }

  AgentModel? _currentAgent() {
    final snapshot = widget.client.snapshot;
    if (snapshot == null) return null;
    final paneId = widget.client.selectedPaneId;
    if (paneId != null) {
      final agent = snapshot.agentOf(paneId);
      if (agent != null) return agent;
      final pane = snapshot.panes.where((p) => p.id == paneId).firstOrNull;
      if (pane != null) {
        final tabPanes = snapshot.panes.where((p) => p.tabId == pane.tabId).map((p) => p.id).toSet();
        final agentInTab = snapshot.agents.where((a) => tabPanes.contains(a.paneId)).firstOrNull;
        if (agentInTab != null) return agentInTab;
      }
    }
    return null;
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
    final currentAgent = _currentAgent();
    final currentUsage = currentAgent?.usage;
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
        // The workspace header: on mobile, tapping opens the workspace actions sheet;
        // on Linux, tapping does nothing and right-clicking opens the context menu.
        title: GestureDetector(
          onSecondaryTapUp: workspace == null
              ? null
              : (d) => showWorkspaceContextMenu(
                    context,
                    client,
                    workspace,
                    d.globalPosition,
                    onDelete: widget.embedded ? null : () => Navigator.maybePop(context),
                  ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: (Platform.isLinux || workspace == null)
                ? null
                : () => showWorkspaceActions(context, client, workspace,
                    onDelete: widget.embedded ? null : () => Navigator.maybePop(context)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isWorktree || branch.isNotEmpty)
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
                          if (branch.isNotEmpty) const SizedBox(width: 6),
                        ],
                        if (branch.isNotEmpty)
                          Flexible(
                            child: Text(
                              branch,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Usage and quotas',
            icon: Icon(Icons.bolt, color: _quotaColor(scheme, currentUsage)),
            onPressed: () => _showUsage(currentAgent, currentUsage),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Tooltip(
              message: '${client.nameOf(client.machine)} · ${machineStatus(client, client.machine)}',
              child: Chip(
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
              ),
            ),
          ),
        ],
        // The workspace's tabs, like Vivaldi's: equal 168dp tabs, scrolling when they overflow.
        // The current one is rounded on top and takes the terminal's color, joined to it below.
        // Each shows its agent icon with an online status ring and truncated tab summary; the current one has a ⋮ menu. Long-press a tab to move it.
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
                                  // Long-press and drag a tab onto another to take its place.
                                  DragTarget<String>(
                                    onWillAcceptWithDetails: (d) => d.data != t.id,
                                    onAcceptWithDetails: (d) => client.moveTab(d.data, t.id),
                                    builder: (context, over, _) {
                                      final tabAgent = _tabAgent(t);
                                      final label = Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        child: Row(
                                          children: [
                                            AgentAvatar(name: tabAgent?.name ?? '', radius: 7.5, status: t.agentStatus),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                _tabSummary(t),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                                    color: j == i ? scheme.onSurface : scheme.onSurfaceVariant),
                                              ),
                                            ),
                                            // The current tab's menu, as browsers show close on theirs.
                                            if (j == i)
                                              Builder(
                                                builder: (context) => InkResponse(
                                                  radius: 14,
                                                  onTap: () => _showTabMenu(
                                                      (context.findRenderObject() as RenderBox)
                                                          .localToGlobal(Offset.zero),
                                                      t,
                                                      tabs,
                                                      j),
                                                  child: const Icon(Icons.more_vert, size: 16),
                                                ),
                                              ),
                                          ],
                                        ),
                                      );
                                      const top = BorderRadius.vertical(top: Radius.circular(10));
                                      return LongPressDraggable<String>(
                                        data: t.id,
                                        axis: Axis.horizontal,
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
                                        childWhenDragging: Opacity(
                                          opacity: 0.3,
                                          child: Container(
                                            width: 168,
                                            decoration:
                                                j == i ? BoxDecoration(color: background, borderRadius: top) : null,
                                            child: label,
                                          ),
                                        ),
                                        child: GestureDetector(
                                          onSecondaryTapUp: (d) => _showTabMenu(d.globalPosition, t, tabs, j),
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
                        IconButton(
                          tooltip: 'New tab',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(width: 40, height: 34),
                          iconSize: 18,
                          icon: const Icon(Icons.add),
                          onPressed: () => client.createTab(tabs[i].workspaceId),
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
                        Positioned.fill(
                          child: Listener(
                            onPointerDown: _trackPointer,
                            onPointerMove: _trackPointer,
                            onPointerUp: _trackPointer,
                            onPointerCancel: _trackPointer,
                            onPointerSignal: _scrollSignal,
                            onPointerPanZoomStart: _scrollSignal,
                            onPointerPanZoomUpdate: _scrollSignal,
                            onPointerPanZoomEnd: _scrollSignal,
                            // Embedded, a little room from the agents and the screen's edge, in the pane's colour.
                            child: Container(
                                color: background,
                                padding: EdgeInsets.symmetric(horizontal: widget.embedded ? 4 : 0),
                                // Following a two-finger swipe until it switches agent, and springing back after;
                                // behind it, where each way leads.
                                child: Stack(children: [
                                  if (_swipeDx != 0)
                                    Positioned.fill(
                                      child: Row(children: [
                                        for (final step in [-1, 1])
                                          if (_peek(step) case final label?)
                                            Expanded(
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                                child: Text(step < 0 ? '‹ $label' : '$label ›',
                                                    maxLines: 4,
                                                    overflow: TextOverflow.ellipsis,
                                                    textAlign: step < 0 ? TextAlign.left : TextAlign.right,
                                                    style: Theme.of(context).textTheme.labelLarge),
                                              ),
                                            ),
                                      ]),
                                    ),
                                  AnimatedContainer(
                                    duration: _swipeDx == 0 ? const Duration(milliseconds: 150) : Duration.zero,
                                    curve: Curves.easeOut,
                                    transform: Matrix4.translationValues(_swipeDx, 0, 0),
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
                                  ]),
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
            // The keyboard button swaps the message box for the control keys and back. It takes the terminal's background.
            if (!client.hideMessageTerminal)
              Container(
                color: background,
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                child: Row(
                  children: [
                    Theme(
                      data: onBackground,
                      child: IconButton(
                        tooltip: client.keyBar ? 'Message box' : 'Control keys',
                        isSelected: client.keyBar,
                        icon: const Icon(Icons.keyboard_command_key),
                        selectedIcon: const Icon(Icons.chat_bubble_outline),
                        onPressed: () {
                          // A keyboard that is up stays up: it types into the terminal beside the keys, and
                          // into the box again when it comes back. Focus moves before the swap, in one frame.
                          if (MediaQuery.viewInsetsOf(context).bottom > 0) {
                            client.keyBar ? _messageFocus.requestFocus() : _view.currentState?.requestKeyboard();
                          }
                          client.setKeyBar(!client.keyBar);
                        },
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
                              focusNode: _messageFocus,
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
                                  tooltip: 'History and quick replies',
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
          ],
        ),
      ),
    );
  }
}
