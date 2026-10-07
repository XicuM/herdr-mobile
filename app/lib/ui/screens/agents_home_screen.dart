import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/herdr_client.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/machine_drawer.dart';
import '../widgets/workspace_drawer.dart';
import 'settings_screen.dart';
import 'terminal_screen.dart';

const _urgency = ['blocked', 'working', 'done', 'idle'];

/// Canonical Material 3 home screen listing all AI agents organized by machine.
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
          drawer: WorkspaceDrawer(client: widget.client, openTerminalOnSelect: true),
          appBar: AppBar(
            title: const Text('Agents'),
            centerTitle: false,
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
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: machines.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _buildMachineSection(context, machines[i], scheme),
                ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_outlined, size: 64, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              'No machines connected',
              style: Theme.of(context).textTheme.titleLarge,
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

    final sortedAgents = [
      for (final s in _urgency) ...agents.where((a) => a.status == s),
      ...agents.where((a) => !_urgency.contains(a.status)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Machine Header ListTile
        ListTile(
          dense: true,
          leading: machineDot(context, client, m),
          minLeadingWidth: 12,
          title: Text(
            client.nameOf(m),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.bold,
                ),
          ),
          subtitle: Text(
            client.isOff(m)
                ? 'Disconnected'
                : client.isConnected(m)
                    ? client.summaryOf(m)
                    : 'Connecting…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          trailing: Switch(
            value: !client.isOff(m),
            onChanged: (on) => on ? client.connect(m) : client.disconnect(m),
          ),
        ),

        // Agents List
        if (!isConnected)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              client.isOff(m) ? 'Machine is switched off' : 'Connecting…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else if (sortedAgents.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No agents running on this machine',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else
          for (final agent in sortedAgents)
            _buildAgentTile(context, m, agent, paneById[agent.paneId], wsById, tabById, scheme),
      ],
    );
  }

  Widget _buildAgentTile(
    BuildContext context,
    String m,
    AgentModel agent,
    PaneModel? pane,
    Map<String, WorkspaceModel> wsById,
    Map<String, TabModel> tabById,
    ColorScheme scheme,
  ) {
    final client = widget.client;
    final ws = pane != null ? wsById[pane.workspaceId] : null;
    final tab = pane != null ? tabById[pane.tabId] : null;

    final wsLabel = ws?.displayName ?? '';
    final branch = ws?.gitBranch;
    final tabLabel = tab?.displayName ?? '';

    final subtitleParts = [
      if (wsLabel.isNotEmpty) wsLabel,
      if (branch != null && branch.isNotEmpty) branch,
      if (tabLabel.isNotEmpty && tabLabel != wsLabel) tabLabel,
      if (pane?.terminalTitle.isNotEmpty == true) pane!.terminalTitle,
    ];

    final isBlocked = agent.status == 'blocked';
    final isMuted = client.isMuted(agent.paneId);

    return ListTile(
      leading: AgentAvatar(name: agent.name, status: agent.status),
      title: Row(
        children: [
          Expanded(
            child: Text(
              agent.name,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isBlocked ? scheme.error : null,
                  ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isBlocked)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'NEEDS INPUT',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
        ],
      ),
      subtitle: subtitleParts.isNotEmpty
          ? Text(
              subtitleParts.join(' · '),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: isMuted ? 'Unmute' : 'Mute',
            icon: Icon(
              isMuted ? Icons.notifications_off : Icons.notifications_none,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () => client.setMuted(agent.paneId, !isMuted),
          ),
          IconButton(
            tooltip: 'Close pane',
            icon: Icon(Icons.close, size: 20, color: scheme.onSurfaceVariant),
            onPressed: () => client.closePane(agent.paneId),
          ),
        ],
      ),
      onTap: () => _openAgent(m, agent.paneId),
    );
  }
}
