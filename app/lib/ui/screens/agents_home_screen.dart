import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/herdr_client.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/machine_drawer.dart';
import 'settings_screen.dart';
import 'terminal_screen.dart';

const _urgency = ['blocked', 'working', 'done', 'idle'];

/// Main WhatsApp-like home screen listing all AI agents organized by machine.
class AgentsHomeScreen extends StatefulWidget {
  final HerdrClientService client;

  const AgentsHomeScreen({super.key, required this.client});

  @override
  State<AgentsHomeScreen> createState() => _AgentsHomeScreenState();
}

class _AgentsHomeScreenState extends State<AgentsHomeScreen> {
  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen(client: widget.client)),
    );
  }

  void _openAgent(String machine, String paneId) {
    if (widget.client.machine != machine) {
      widget.client.switchMachine(machine);
    }
    widget.client.selectPane(paneId);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TerminalScreen(client: widget.client)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: widget.client,
      builder: (context, _) {
        final machines = widget.client.machines;

        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'Agents',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            actions: [
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: _openSettings,
              ),
            ],
          ),
          body: machines.isEmpty
              ? _buildEmptyState(context, scheme)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: machines.length,
                  itemBuilder: (context, i) => _buildMachineSection(context, machines[i], scheme),
                ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_outlined, size: 64, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              'No machines connected',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Add a machine running herdr-bridge over Tailscale or local network to see and interact with your agents.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.add),
              label: const Text('Add a machine'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMachineSection(BuildContext context, String m, ColorScheme scheme) {
    final client = widget.client;
    final snapshot = client.snapshotOf(m);
    final isConnected = client.isConnected(m) || snapshot != null;
    final agents = snapshot?.agents ?? <AgentModel>[];
    final paneById = {for (final p in snapshot?.panes ?? <PaneModel>[]) p.id: p};
    final wsById = {for (final w in snapshot?.workspaces ?? <WorkspaceModel>[]) w.id: w};
    final tabById = {for (final t in snapshot?.tabs ?? <TabModel>[]) t.id: t};

    // Sort agents by urgency: blocked first, then working, then done, then idle
    final sortedAgents = [
      for (final s in _urgency) ...agents.where((a) => a.status == s),
      ...agents.where((a) => !_urgency.contains(a.status)),
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withOpacity(0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Machine Header
            Row(
              children: [
                machineDot(context, client, m),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        client.nameOf(m),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        client.isOff(m)
                            ? 'Disconnected'
                            : client.isConnected(m)
                                ? client.summaryOf(m)
                                : 'Connecting…',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: !client.isOff(m),
                  onChanged: (on) => on ? client.connect(m) : client.disconnect(m),
                ),
              ],
            ),
            const Divider(height: 20),

            // Agents list for this machine
            if (!isConnected)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    client.isOff(m) ? 'Machine is switched off' : 'Connecting to machine...',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
              )
            else if (sortedAgents.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    'No agents running on this machine',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: sortedAgents.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, idx) {
                  final agent = sortedAgents[idx];
                  final pane = paneById[agent.paneId];
                  final ws = pane != null ? wsById[pane.workspaceId] : null;
                  final tab = pane != null ? tabById[pane.tabId] : null;

                  final wsLabel = ws?.displayName ?? '';
                  final branch = ws?.gitBranch;
                  final tabLabel = tab?.displayName ?? '';

                  final subtitleParts = [
                    if (wsLabel.isNotEmpty) wsLabel,
                    if (branch != null && branch.isNotEmpty) branch,
                    if (tabLabel.isNotEmpty && tabLabel != wsLabel) tabLabel,
                  ];

                  final isBlocked = agent.status == 'blocked';
                  final isMuted = client.isMuted(agent.paneId);

                  return Material(
                    color: isBlocked
                        ? AgentStatus.blocked.color.withOpacity(0.12)
                        : scheme.surfaceContainerHigh.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openAgent(m, agent.paneId),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            AgentAvatar(name: agent.name, status: agent.status),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          agent.name,
                                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                color: isBlocked ? scheme.error : null,
                                              ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (isBlocked) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: AgentStatus.blocked.color,
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            'NEEDS INPUT',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: scheme.surface,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  if (subtitleParts.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      subtitleParts.join(' · '),
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                  if (pane?.terminalTitle.isNotEmpty == true) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      pane!.terminalTitle,
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: scheme.outline,
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: isMuted ? 'Unmute' : 'Mute',
                                  icon: Icon(
                                    isMuted ? Icons.notifications_off : Icons.notifications_none,
                                    size: 18,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  onPressed: () => client.setMuted(agent.paneId, !isMuted),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'Close pane',
                                  icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
                                  onPressed: () => client.closePane(agent.paneId),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
