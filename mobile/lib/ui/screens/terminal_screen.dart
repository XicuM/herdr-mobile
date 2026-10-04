import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import '../../services/herdr_client.dart';
import '../../services/pty_channel.dart';
import '../widgets/workspace_drawer.dart';
import '../widgets/keyboard_accessory_bar.dart';
import '../widgets/agent_status_badge.dart';

class TerminalScreen extends StatefulWidget {
  final HerdrClientService client;

  const TerminalScreen({super.key, required this.client});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late Terminal _terminal;
  PtyChannel? _ptyChannel;
  String? _currentPaneId;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = (data) {
      _ptyChannel?.sendInput(data);
    };

    widget.client.addListener(_onClientUpdate);
    _checkActivePane();
  }

  void _onClientUpdate() {
    if (mounted) {
      setState(() {});
      _checkActivePane();
    }
  }

  void _checkActivePane() {
    final paneId = widget.client.selectedPaneId;
    if (paneId != null && paneId != _currentPaneId) {
      _currentPaneId = paneId;
      _ptyChannel?.dispose();
      _terminal.eraseDisplay();

      _ptyChannel = PtyChannel(
        host: widget.client.host,
        port: widget.client.port,
        paneId: paneId,
        terminal: _terminal,
      );
      _ptyChannel!.connect();
    }
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientUpdate);
    _ptyChannel?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final snapshot = client.snapshot;
    final currentPane = snapshot?.panes
        .where((p) => p.id == client.selectedPaneId)
        .firstOrNull;
    final currentAgent = snapshot?.agents
        .where((a) => a.paneId == client.selectedPaneId)
        .firstOrNull;
    final isBlocked = (currentAgent?.status == 'blocked' || currentPane?.agentStatus == 'blocked');

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
              currentPane?.terminalTitle.isNotEmpty == true
                  ? currentPane!.terminalTitle
                  : (client.selectedPaneId ?? 'Herdr Mobile'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
            if (client.selectedPaneId != null)
              Text(
                'Pane ${client.selectedPaneId}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
          ],
        ),
        actions: [
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
                      onPressed: () => _ptyChannel?.sendInput('y\n'),
                      child: const Text('Approve (y)', style: TextStyle(fontSize: 12, color: Colors.white)),
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () => _ptyChannel?.sendInput('n\n'),
                      child: const Text('Reject (n)', style: TextStyle(fontSize: 12, color: Colors.white)),
                    ),
                  ],
                ),
              ),

            // Terminal View
            Expanded(
              child: TerminalView(
                _terminal,
                backgroundOpacity: 1.0,
                autofocus: true,
              ),
            ),

            // Pinned Quick Keyboard Accessory Toolbar
            KeyboardAccessoryBar(
              onSendInput: (input) => _ptyChannel?.sendInput(input),
              onSendKey: (key) => _ptyChannel?.sendKey(key),
            ),
          ],
        ),
      ),
    );
  }
}
