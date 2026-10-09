import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../changelog.dart';
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/herdr_client.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/machines.dart';
import '../widgets/workspaces.dart';
import 'settings_screen.dart';
import 'terminal_screen.dart';

/// Most urgent first; any other status after these.
const _urgency = ['blocked', 'working', 'done', 'idle'];

/// The home screen, like a chat list: every agent on every connected machine, most urgent first and
/// within that most recently changed first. Each row shows, as its terminal's top bar does, the summary
/// the agent's terminal title gives, and under it its workspace, tab and status.
/// Tap one for its terminal; swipe it right to mute it, left to close it (with Undo). Long-press one, or
/// tap its avatar, to select it, as in Gmail: then taps select more and the top bar mutes or closes them all.
/// The top bar is Gmail's: ☰ opens the workspaces (and Settings), the search finds agents, workspaces,
/// tabs and machines, a section each, and the machines' icon, green while one is connected, opens them.
class AgentsHomeScreen extends StatefulWidget {
  final HerdrClientService client;

  const AgentsHomeScreen({super.key, required this.client});

  /// The time today, the day this year, the date before that.
  static String formatWhen(BuildContext context, DateTime at) {
    final l = MaterialLocalizations.of(context);
    final now = DateTime.now();
    if (DateUtils.isSameDay(at, now)) return l.formatTimeOfDay(TimeOfDay.fromDateTime(at));
    return at.year == now.year ? l.formatShortMonthDay(at) : l.formatCompactDate(at);
  }

  @override
  State<AgentsHomeScreen> createState() => _AgentsHomeScreenState();
}

sealed class _Detail {}

class _SettingsDetail extends _Detail {}

class _MachineDetail extends _Detail {
  final String? machine;
  _MachineDetail([this.machine]);
}

class _AgentsHomeScreenState extends State<AgentsHomeScreen> {
  HerdrClientService get client => widget.client;

  /// The selected agents, as (machine, pane id).
  final _selected = <(String, String)>{};

  final _scaffold = GlobalKey<ScaffoldState>();

  /// What's searched for; null while the search is closed.
  String? _query;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  /// The detail view shown on the right side in landscape wide mode instead of the terminal.
  _Detail? _detail;

  /// The terminal's own screen, while it's pushed over the agents (on a narrow screen).
  Route<dynamic>? _terminalRoute;
  bool? _wasWide;

  /// Wide enough for the terminal beside the agents, as Material's list-detail layout: a tablet in
  /// landscape, though not a phone in landscape, whose terminal would be left too narrow.
  static bool isWide(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 840 && size.shortestSide >= 600;
  }

  static bool _isWide(BuildContext context) => isWide(context);

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    setState(() {
      _query = null;
      _search.clear();
    });
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showIntroOrChangelog());
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final isAlt = HardwareKeyboard.instance.isAltPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    if (!isAlt || isCtrl) return false;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyB) {
      if (event is! KeyUpEvent) {
        if (_scaffold.currentState?.isDrawerOpen == true) {
          _scaffold.currentState?.closeDrawer();
        } else {
          _scaffold.currentState?.openDrawer();
        }
      }
      return true;
    }
    if (key == LogicalKeyboardKey.keyM) {
      if (event is! KeyUpEvent) {
        _openMachines();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.keyG) {
      if (event is! KeyUpEvent) {
        _searchFocus.requestFocus();
        setState(() => _query = _query ?? '');
      }
      return true;
    }
    if (key == LogicalKeyboardKey.keyO) {
      if (event is! KeyUpEvent) {
        client.jumpToAttention();
        if (client.selectedPaneId != null && !_isWide(context)) {
          _openTerminal(context);
        }
      }
      return true;
    }
    if (key == LogicalKeyboardKey.keyH) {
      if (event is! KeyUpEvent) {
        if (_query != null) _closeSearch();
        if (_detail != null) setState(() => _detail = null);
        if (_scaffold.currentState?.isDrawerOpen == true) _scaffold.currentState?.closeDrawer();
        if (_scaffold.currentState?.isEndDrawerOpen == true) _scaffold.currentState?.closeEndDrawer();
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
    if (key == LogicalKeyboardKey.keyT) {
      if (event is! KeyUpEvent) {
        final wsId = client.selectedPane?.workspaceId ?? client.snapshot?.workspaces.firstOrNull?.id;
        if (wsId != null) client.createTab(wsId);
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

    return false;
  }

  /// Welcome on first launch; afterwards, the changelog entries newer than the last one seen.
  Future<void> _showIntroOrChangelog() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getString('last_seen_changelog');
    final latest = changelog.first.$1;
    if (seen == latest || !mounted) return;
    await prefs.setString('last_seen_changelog', latest);
    final firstRun = seen == null && client.machines.isEmpty;
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
                  'Every agent on every machine is listed here, the ones that need you first. Tap one for its '
                  'terminal, swipe it right to mute it or left to close it, and long-press to pick several. '
                  'In a terminal, tap the top bar for the workspace\'s actions; the tabs sit under it. Type in '
                  'the box at the bottom, with autocorrect and voice. Swipe the terminal sideways with two '
                  'fingers to go from agent to agent, and pinch it to change the font size.',
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
    if (addMachine == true && mounted) _addMachine();
  }

  void _toggle((String, String) agent) =>
      setState(() => _selected.contains(agent) ? _selected.remove(agent) : _selected.add(agent));

  /// Desktop right-click on an agent row: the swipe actions (mute/close) as a menu, plus open/select.
  Future<void> _agentMenu(TapUpDetails details, String machine, AgentModel agent) async {
    final key = (machine, agent.paneId);
    final muted = client.isMuted(agent.paneId, machine);
    final at = details.globalPosition;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.terminal), title: Text('Open terminal'))),
        PopupMenuItem(
            value: 'mute',
            child: ListTile(
                leading: Icon(muted ? Icons.notifications_outlined : Icons.notifications_off_outlined),
                title: Text(muted ? 'Unmute' : 'Mute'))),
        PopupMenuItem(
            value: 'select',
            child: ListTile(
                leading: Icon(_selected.contains(key) ? Icons.check_box_outline_blank : Icons.check_box_outlined),
                title: Text(_selected.contains(key) ? 'Deselect' : 'Select'))),
        PopupMenuItem(
          value: 'close',
          child: ListTile(
            leading: Icon(Icons.close, color: Theme.of(context).colorScheme.error),
            title: Text('Close', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'open':
        if (_selected.isEmpty) {
          _openAgent(context, machine, agent.paneId);
        } else {
          _toggle(key);
          _openAgent(context, machine, agent.paneId);
        }
      case 'mute':
        client.setMuted(agent.paneId, !muted, machine);
      case 'select':
        _toggle(key);
      case 'close':
        _close([key]);
    }
  }

  /// Mutes them all, or unmutes them when all already are.
  void _muteSelected() {
    final on = _selected.any((a) => !client.isMuted(a.$2, a.$1));
    for (final (m, id) in _selected) {
      client.setMuted(id, on, m);
    }
    setState(_selected.clear);
  }

  /// Closes [agents] unless undone. One at a time, so each close sees the snapshot after the last and keeps
  /// their workspace alive.
  void _close(List<(String, String)> agents) {
    setState(_selected.clear);
    closeWithUndo(context, client, agents.length == 1 ? 'Agent closed' : '${agents.length} agents closed',
        [for (final (m, id) in agents) '$m/$id'], () async {
      for (final (m, id) in agents) {
        await client.closePane(id, m);
      }
    });
  }

  /// To the machines' panel, adding one.
  void _addMachine() {
    if (_isWide(context)) {
      setState(() => _detail = _MachineDetail());
      return;
    }
    _openMachines();
    showMachinePage(context, client);
  }

  void _openMachines() {
    if (_scaffold.currentState?.isEndDrawerOpen == true) {
      _scaffold.currentState?.closeEndDrawer();
    } else {
      _scaffold.currentState?.openEndDrawer();
    }
  }

  /// Closes the drawer, then goes on to [to].
  void _fromDrawer(void Function(BuildContext) to) {
    _scaffold.currentState?.closeDrawer();
    to(context);
  }

  void _openSettings(BuildContext context) {
    if (_isWide(context)) {
      setState(() => _detail = _SettingsDetail());
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(client: client)));
  }

  /// Pushes the selected pane's terminal; on a wide screen it's already beside the agents.
  Future<void> _openTerminal(BuildContext context) async {
    if (_isWide(context)) {
      setState(() => _detail = null);
      return;
    }
    final route = _terminalRoute = MaterialPageRoute(builder: (_) => TerminalScreen(client: client));
    final action = await Navigator.push(context, route);
    if (_terminalRoute == route) _terminalRoute = null;
    if (mounted) {
      setState(() {});
      if (action == 'search') {
        _searchFocus.requestFocus();
        setState(() => _query = _query ?? '');
      } else if (action == 'drawer') {
        if (_scaffold.currentState?.isDrawerOpen == true) {
          _scaffold.currentState?.closeDrawer();
        } else {
          _scaffold.currentState?.openDrawer();
        }
      } else if (action == 'machines') {
        if (_scaffold.currentState?.isEndDrawerOpen == true) {
          _scaffold.currentState?.closeEndDrawer();
        } else {
          _scaffold.currentState?.openEndDrawer();
        }
      }
    }
  }

  /// Turning wide (rotated, or the window resized), the terminal's own screen moves beside the agents;
  /// turning narrow, the terminal beside them gets its own screen back.
  void _onWidthChange(bool wide, bool showing) {
    final was = _wasWide;
    _wasWide = wide;
    if (was == null || was == wide) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = _terminalRoute;
      if (wide && route != null && route.isActive) {
        Navigator.popUntil(context, (r) => r == route);
        Navigator.pop(context);
      } else if (!wide) {
        if (_detail != null) {
          final d = _detail;
          _detail = null;
          if (d is _SettingsDetail) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(client: client)));
          } else if (d is _MachineDetail) {
            Navigator.push(
              context,
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (_) => MachineScreen(client: client, machine: d.machine),
              ),
            );
          }
        } else if (showing && ModalRoute.of(context)?.isCurrent == true) {
          _openTerminal(context);
        }
      }
    });
  }

  void _openAgent(BuildContext context, String machine, String paneId) {
    if (client.machine != machine) client.switchMachine(machine);
    client.selectPane(paneId);
    _openTerminal(context);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final machines = client.machines;
        final on = machines.where((m) => !client.isOff(m)).toList();
        final connected = on.where(client.isConnected).toList();
        final rows = <(String, SessionSnapshot, AgentModel, PaneModel?)>[];
        for (final m in on) {
          final s = client.snapshotOf(m);
          if (s == null) continue;
          final pane = {for (final p in s.panes) p.id: p};
          for (final a in s.agents) {
            rows.add((m, s, a, pane[a.paneId]));
          }
        }
        int rank(AgentModel a) => switch (_urgency.indexOf(a.status)) { -1 => _urgency.length, final i => i };
        DateTime at(String m, AgentModel a) => client.changedAt(a.paneId, m) ?? DateTime(0);
        // Those with no time (there before the app saw them change) by herdr's seq, one counter for all its panes.
        rows.sort((x, y) => rank(x.$3) != rank(y.$3)
            ? rank(x.$3) - rank(y.$3)
            : switch (at(y.$1, y.$3).compareTo(at(x.$1, x.$3))) {
                0 => (y.$3.stateChangeSeq ?? 0) - (x.$3.stateChangeSeq ?? 0),
                final c => c,
              });
        // Agents that have gone drop out of the selection.
        _selected.retainWhere((a) => rows.any((r) => r.$1 == a.$1 && r.$3.paneId == a.$2));
        final selecting = _selected.isNotEmpty;
        final allMuted = _selected.every((a) => client.isMuted(a.$2, a.$1));

        // Each word must be somewhere in what a result shows or is known by.
        final searching = _query != null;
        final words = (_query ?? '').toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        bool hit(Iterable<String?> fields) {
          final text = fields.whereType<String>().join(' ').toLowerCase();
          return words.every(text.contains);
        }

        final agentHits = [
          for (final r in rows)
            if (hit([
              r.$4?.terminalTitle,
              r.$3.name,
              client.nameOf(r.$1),
              if (r.$4 != null) r.$2.placeOf(r.$4!),
              AgentStatus.fromString(r.$3.status).label,
              if (TerminalScreen.hasDraft(r.$3.paneId, r.$1)) 'Draft',
            ]))
              r
        ];
        final workspaceHits = <(String, SessionSnapshot, WorkspaceModel)>[];
        final tabHits = <(String, SessionSnapshot, TabModel)>[];
        final machineHits = <String>[];
        if (words.isNotEmpty) {
          for (final m in on) {
            final s = client.snapshotOf(m);
            if (s == null) continue;
            for (final ws in s.workspaces) {
              // A worktree is also found by its repository's workspace.
              final repo = ws.isLinkedWorktree
                  ? s.workspaces.where((w) => !w.isLinkedWorktree && w.repoKey == ws.repoKey).firstOrNull
                  : null;
              if (hit([
                ws.displayName,
                ws.gitBranch,
                repo?.displayName,
                client.nameOf(m),
                AgentStatus.fromString(ws.agentStatus).label
              ])) {
                workspaceHits.add((m, s, ws));
              }
            }
            for (final t in s.tabs) {
              if (hit([
                t.displayName,
                s.workspaces.where((w) => w.id == t.workspaceId).firstOrNull?.displayName,
                client.nameOf(m),
              ])) {
                tabHits.add((m, s, t));
              }
            }
          }
          machineHits.addAll(machines.where((m) => hit([
                client.nameOf(m),
                m,
                if (HerdrClientService.parentOf(m) case final parent?) client.nameOf(parent),
                machineStatus(client, m),
              ])));
        }
        final shown = searching ? agentHits : rows;

        // On a wide screen the selected pane's terminal is beside the list, while there's one to show.
        final wide = _isWide(context);
        final paneId = client.selectedPaneId;
        final showing = paneId != null &&
            !client.isDisconnected &&
            machines.contains(client.machine) &&
            (client.snapshot == null || client.selectedPane != null);
        _onWidthChange(wide, showing);

        final PreferredSizeWidget bar = selecting
            ? AppBar(
                leading: IconButton(
                  tooltip: 'Clear selection',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(_selected.clear),
                ),
                title: Text('${_selected.length}'),
                actions: [
                  IconButton(
                    tooltip: 'Select all',
                    icon: const Icon(Icons.select_all),
                    onPressed: () => setState(() => _selected.addAll([for (final r in shown) (r.$1, r.$3.paneId)])),
                  ),
                  IconButton(
                    tooltip: allMuted ? 'Unmute' : 'Mute',
                    icon: Icon(allMuted ? Icons.notifications_outlined : Icons.notifications_off_outlined),
                    onPressed: _muteSelected,
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => _close(_selected.toList()),
                  ),
                ],
              )
            // The ☰ for the workspaces, the search between, and the machines on the right: each icon in
            // a 56dp slot, so the search sits in the middle.
            : AppBar(
                leadingWidth: 56,
                leading: searching
                    ? BackButton(onPressed: _closeSearch)
                    : IconButton(
                        tooltip: 'Workspaces',
                        icon: const Icon(Icons.menu),
                        onPressed: () => _scaffold.currentState?.openDrawer(),
                      ),
                titleSpacing: 0,
                // A pill with its text centred, which M3's SearchBar can't do: the search icon on the left
                // and as wide a slot on the right, for the clear button.
                title: Container(
                  height: 48,
                  decoration: ShapeDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    shape: const StadiumBorder(),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 48,
                        child: Icon(Icons.search, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _search,
                          focusNode: _searchFocus,
                          textAlign: TextAlign.center,
                          decoration: InputDecoration.collapsed(
                            // "Connecting…", like WhatsApp's title while it has no connection.
                            hintText: connected.isEmpty && on.isNotEmpty ? 'Connecting…' : 'Search',
                          ),
                          onTap: () => setState(() => _query ??= ''),
                          onChanged: (q) => setState(() => _query = q),
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        child: _query?.isNotEmpty ?? false
                            ? IconButton(
                                tooltip: 'Clear',
                                icon: const Icon(Icons.close),
                                onPressed: () => setState(() {
                                  _search.clear();
                                  _query = '';
                                }),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
                actions: [
                  // Green while one is connected.
                  SizedBox(
                    width: 56,
                    child: IconButton(
                      tooltip: 'Machines',
                      icon: Icon(Icons.computer,
                          color: connected.isEmpty ? Theme.of(context).colorScheme.onSurfaceVariant : Colors.green),
                      onPressed: _openMachines,
                    ),
                  ),
                ],
              );
        final Widget list = searching
            ? _results(context, words.isEmpty, agentHits, workspaceHits, tabHits, machineHits, machines.length > 1)
            : machines.isEmpty
                ? _empty(
                    context,
                    Icons.computer_outlined,
                    'No machines',
                    'Add a machine running herdr-bridge to see its agents.',
                    FilledButton.icon(
                      onPressed: _addMachine,
                      icon: const Icon(Icons.add),
                      label: const Text('Add a machine'),
                    ),
                  )
                : on.isEmpty
                    ? _empty(
                        context,
                        Icons.link_off,
                        'All machines are off',
                        'Switch one on to see its agents.',
                        FilledButton.tonal(onPressed: _openMachines, child: const Text('Machines')),
                      )
                    : rows.isEmpty && connected.isEmpty
                        ? const Center(child: CircularProgressIndicator())
                        : rows.isEmpty
                            ? _empty(context, Icons.smart_toy_outlined, 'No agents',
                                'Agents started in herdr show up here.', null)
                            : ListView.separated(
                                padding: const EdgeInsets.only(bottom: 16),
                                itemCount: rows.length,
                                // A hairline across the whole row, faint like WhatsApp's chat list.
                                separatorBuilder: (context, _) => Divider(
                                  height: 1,
                                  thickness: 0.5,
                                  color: Theme.of(context).colorScheme.outlineVariant.withAlpha(128),
                                ),
                                itemBuilder: (context, i) => _tile(context, rows[i], machines.length > 1),
                              );

        final Widget scaffold = PopScope(
          // Back leaves the selection first, then the search, then the detail view.
          canPop: !selecting && !searching && _detail == null,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (selecting) return setState(_selected.clear);
            if (searching) return _closeSearch();
            if (_detail != null) return setState(() => _detail = null);
          },
          child: Scaffold(
              key: _scaffold,
              // Only the ☰ opens it: an edge swipe would fight the rows' swipe to mute and Android's back.
              drawerEnableOpenDragGesture: false,
              drawer: Drawer(
                child: SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text('Workspaces', style: Theme.of(context).textTheme.titleLarge),
                      ),
                      Expanded(child: WorkspaceList(client: client, open: () => _fromDrawer(_openTerminal))),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.settings_outlined),
                        title: const Text('Settings'),
                        onTap: () => _fromDrawer(_openSettings),
                      ),
                    ],
                  ),
                ),
              ),
              // The machines, on the side their icon is: each with how it's doing and a switch; its + adds one.
              endDrawerEnableOpenDragGesture: false,
              endDrawer: Drawer(
                child: SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                        child: Row(
                          children: [
                            Expanded(child: Text('Machines', style: Theme.of(context).textTheme.titleLarge)),
                            IconButton(
                              tooltip: 'Add machine',
                              icon: const Icon(Icons.add),
                              onPressed: () => showMachinePage(context, client),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: MachineList(client: client)),
                    ],
                  ),
                ),
              ),
              appBar: wide ? null : bar,
              body: wide
                  ? Row(
                      children: [
                        SizedBox(width: 360, child: Column(children: [bar, Expanded(child: list)])),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: switch (_detail) {
                            _SettingsDetail() => SettingsScreen(
                                client: client,
                                onClose: () => setState(() => _detail = null),
                              ),
                            _MachineDetail(:final machine) => MachineScreen(
                                // Its fields are filled in once: another machine (or + after one) needs its own.
                                key: ValueKey(machine),
                                client: client,
                                machine: machine,
                                onClose: () => setState(() => _detail = null),
                              ),
                            null => showing
                                // Its scrolling (the terminal's output, the tab strip) stops here, or it would tint
                                // the agents' top bar as if the list had scrolled under it.
                                ? NotificationListener<Notification>(
                                    onNotification: (n) => n is ScrollNotification || n is ScrollMetricsNotification,
                                    child: TerminalScreen(
                                      client: client,
                                      embedded: true,
                                      onOpenDrawer: () {
                                        if (_scaffold.currentState?.isDrawerOpen == true) {
                                          _scaffold.currentState?.closeDrawer();
                                        } else {
                                          _scaffold.currentState?.openDrawer();
                                        }
                                      },
                                      onOpenMachines: _openMachines,
                                      onOpenSearch: () {
                                        _searchFocus.requestFocus();
                                        setState(() => _query = _query ?? '');
                                      },
                                    ),
                                  )
                                : _empty(
                                    context, Icons.terminal, 'No agent open', 'Pick one to see its terminal.', null),
                          },
                        ),
                      ],
                    )
                  : list,
            ),
          );

        return wide
            ? MachineDetailScope(
                onOpenDetail: (m) {
                  _scaffold.currentState?.closeEndDrawer();
                  _scaffold.currentState?.closeDrawer();
                  setState(() => _detail = _MachineDetail(m));
                },
                child: scaffold,
              )
            : scaffold;
      },
    );
  }

  /// The search's results, a section each, in the order they're likeliest wanted.
  Widget _results(
    BuildContext context,
    bool blank,
    List<(String, SessionSnapshot, AgentModel, PaneModel?)> agents,
    List<(String, SessionSnapshot, WorkspaceModel)> workspaces,
    List<(String, SessionSnapshot, TabModel)> tabs,
    List<String> machines,
    bool showMachine,
  ) {
    final theme = Theme.of(context);
    if (blank) return const SizedBox.shrink();
    if (agents.isEmpty && workspaces.isEmpty && tabs.isEmpty && machines.isEmpty) {
      return _empty(context, Icons.search_off, 'No results', 'Nothing matches "${_query!.trim()}".', null);
    }
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        );
    // Requests and the terminal go to the active machine, so a result switches to its own first.
    void open(String m, VoidCallback select) {
      if (client.machine != m) client.switchMachine(m);
      select();
      _openTerminal(context);
    }

    String sub(String m, Iterable<String?> parts) =>
        [...parts.whereType<String>(), if (showMachine) client.nameOf(m)].where((p) => p.isNotEmpty).join(' · ');
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (agents.isNotEmpty) ...[
          header('Agents'),
          for (final r in agents) _tile(context, r, showMachine),
        ],
        if (workspaces.isNotEmpty) ...[
          header('Workspaces'),
          for (final (m, s, ws) in workspaces)
            // Held and lifted (or right-clicked), its menu, as in the drawer.
            HoldMenu(
              onMenu: (at) {
                if (client.machine != m) client.switchMachine(m);
                showWorkspaceContextMenu(context, client, ws, at, onShow: () => _openTerminal(context));
              },
              child: ListTile(
                leading: StatusDot(ws.agentStatus, size: 10),
                minLeadingWidth: 10,
                title: Text(
                  ws.isLinkedWorktree
                      ? (s.workspaces
                              .where((w) => !w.isLinkedWorktree && w.repoKey == ws.repoKey)
                              .firstOrNull
                              ?.displayName ??
                          ws.displayName)
                      : ws.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  sub(m, [
                    ws.isLinkedWorktree
                        ? (ws.gitBranch?.replaceFirst('worktree/', '') ?? ws.displayName)
                        : ws.gitBranch
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => open(m, () => client.selectWorkspace(ws.id)),
              ),
            ),
        ],
        if (tabs.isNotEmpty) ...[
          header('Tabs'),
          for (final (m, s, t) in tabs)
            ListTile(
              leading: StatusDot(t.agentStatus, size: 10),
              minLeadingWidth: 10,
              title: Text(t.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(sub(m, [s.workspaces.where((w) => w.id == t.workspaceId).firstOrNull?.displayName]),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => open(m, () => client.selectTab(t.id)),
            ),
        ],
        if (machines.isNotEmpty) ...[
          header('Machines'),
          MachineList(client: client, only: machines),
        ],
      ],
    );
  }

  Widget _tile(BuildContext context, (String, SessionSnapshot, AgentModel, PaneModel?) row, bool showMachine) {
    final (machine, snapshot, agent, pane) = row;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = AgentStatus.fromString(agent.status);
    final needsYou = status == AgentStatus.blocked;
    final hasDraft = TerminalScreen.hasDraft(agent.paneId, machine);
    final statusLabel = hasDraft ? 'Draft' : status.label;
    final statusColor = hasDraft ? AgentStatus.draftColor : status.color;
    final muted = client.isMuted(agent.paneId, machine);
    final at = client.changedAt(agent.paneId, machine);
    final key = (machine, agent.paneId);
    final selected = _selected.contains(key);
    // The summary its terminal shows on top, as what matters; under it where it is.
    final title = switch (pane?.terminalTitle ?? '') { '' => agent.name, final t => t };
    final place = [
      if (pane != null) snapshot.placeOf(pane),
      if (showMachine) client.nameOf(machine),
    ].where((p) => p.isNotEmpty).join(' · ');

    // What a swipe does, drawn under the row: its colour, with its icon and label at the edge it leaves.
    Widget behind(Color bg, Color fg, IconData icon, String label, bool start) => ColoredBox(
          color: bg,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: start ? MainAxisAlignment.start : MainAxisAlignment.end,
              children: [
                Icon(icon, color: fg),
                const SizedBox(width: 12),
                Text(label, style: theme.textTheme.labelLarge?.copyWith(color: fg)),
              ],
            ),
          ),
        );

    // Swipe right to mute (the row stays), left to close.
    return Dismissible(
      key: ValueKey('$machine/${agent.paneId}'),
      direction: _selected.isEmpty ? DismissDirection.horizontal : DismissDirection.none,
      background: behind(scheme.secondaryContainer, scheme.onSecondaryContainer,
          muted ? Icons.notifications_outlined : Icons.notifications_off_outlined, muted ? 'Unmute' : 'Mute', true),
      secondaryBackground: behind(scheme.errorContainer, scheme.onErrorContainer, Icons.close, 'Close', false),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          client.setMuted(agent.paneId, !muted, machine);
          return false;
        }
        return true;
      },
      onDismissed: (_) => _close([key]),
      child: GestureDetector(
        onSecondaryTapUp: (d) => _agentMenu(d, machine, agent),
        child: ListTile(
        // On a wide screen, the agent whose terminal is beside the list is marked, as an open chat is.
        tileColor: selected
            ? scheme.secondaryContainer
            : _isWide(context) && client.machine == machine && client.selectedPaneId == agent.paneId
                ? scheme.surfaceContainerHighest
                : null,
        leading: GestureDetector(
          onTap: () => _toggle(key),
          // Selected, the check sits in the status ring's place, so the row keeps its size.
          child: selected
              ? Container(
                  padding: const EdgeInsets.all(1.5),
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, border: Border.all(color: scheme.primary, width: 3)),
                  child: CircleAvatar(
                    radius: 20,
                    backgroundColor: scheme.primary,
                    child: Icon(Icons.check, color: scheme.onPrimary),
                  ),
                )
              : AgentAvatar(name: agent.name, status: agent.status),
        ),
        // Bold while it needs you, like an unread chat.
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: needsYou ? FontWeight.bold : null)),
        subtitle: place.isNotEmpty
            ? Text(
                place,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        // A chat's column: when it last changed status on top, and muted icon + status text aligned at bottom.
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Its glyphs' top level with the summary's: titleMedium's 24px line puts them ~2px lower than bodySmall's 16px.
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                at != null ? AgentsHomeScreen.formatWhen(context, at) : '',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (muted) ...[
                  Icon(Icons.notifications_off_outlined, size: 16, color: scheme.onSurfaceVariant),
                  if (statusLabel.isNotEmpty) const SizedBox(width: 4),
                ],
                if (statusLabel.isNotEmpty)
                  Text(
                    statusLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ],
        ),
        onTap: () => _selected.isEmpty ? _openAgent(context, machine, agent.paneId) : _toggle(key),
        onLongPress: () => _toggle(key),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context, IconData icon, String title, String body, Widget? action) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (action != null) ...[const SizedBox(height: 24), action],
          ],
        ),
      ),
    );
  }
}
