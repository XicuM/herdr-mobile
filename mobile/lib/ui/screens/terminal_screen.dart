import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import '../../changelog.dart';
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
  late Terminal _terminal;
  PtyChannel? _ptyChannel;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = (data) => _ptyChannel?.sendInput(data);
    _terminal.onResize = (cols, rows, _, __) => _ptyChannel?.sendResize(cols, rows);

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
        backgroundColor: const Color(0xFF1E1E1E),
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
                  'workspace or agent. The volume keys change the font size.',
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
    final workspaceId = currentPane?.workspaceId ?? snapshot?.focusedWorkspaceId;
    final currentWorkspace = snapshot?.workspaces.where((w) => w.id == workspaceId).firstOrNull;
    final workspaceTabs = snapshot?.tabs.where((t) => t.workspaceId == workspaceId).toList() ?? [];
    final currentTab = workspaceTabs.where((t) => t.id == currentPane?.tabId).firstOrNull;
    String tabLabel(TabModel t) => t.label.isNotEmpty ? t.label : 'Tab ${t.number}';

    return Scaffold(
      backgroundColor: Colors.black,
      drawer: WorkspaceDrawer(client: client),
      appBar: AppBar(
        backgroundColor: const Color(0xFF181818),
        elevation: 0,
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
              color: const Color(0xFF222222),
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
                              color: tab.id == currentTab?.id ? Colors.blueAccent : Colors.white,
                            ),
                          ),
                        ),
                        AgentStatusBadge(status: tab.agentStatus, compact: true),
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
            color: const Color(0xFF222222),
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
                        color: m == client.machine ? Colors.blueAccent : Colors.white54,
                      ),
                      const SizedBox(width: 8),
                      Flexible(child: Text(m, overflow: TextOverflow.ellipsis)),
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
            // Blocked / Approval Banner
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
                        'Agent waiting for your input / approval',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () => client.sendPaneInput(client.selectedPaneId!, text: 'y\n'),
                      child: const Text('Approve (y)', style: TextStyle(fontSize: 12, color: Colors.white)),
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () => client.sendPaneInput(client.selectedPaneId!, text: 'n\n'),
                      child: const Text('Reject (n)', style: TextStyle(fontSize: 12, color: Colors.white)),
                    ),
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
                  : TerminalView(
                      _terminal,
                      backgroundOpacity: 1.0,
                      // Bundled mono font with full box-drawing coverage; line height 1.0 keeps
                      // vertical lines continuous between rows.
                      textStyle: TerminalStyle(
                        fontSize: client.fontSize,
                        fontFamily: 'MesloLGS Nerd Font Mono',
                        height: 1.0,
                      ),
                      autofocus: true,
                    ),
            ),

            // Pinned Quick Keyboard Accessory Toolbar
            KeyboardAccessoryBar(
              onSendInput: (input) => _ptyChannel?.sendInput(input),
            ),
          ],
        ),
      ),
    );
  }
}
