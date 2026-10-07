import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/herdr_client.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/workspace_drawer.dart';
import 'settings_screen.dart';
import 'terminal_screen.dart';

const _urgency = ['blocked', 'working', 'done', 'idle'];

class _AgentItem {
  final String machine;
  final AgentModel agent;
  final PaneModel? pane;
  final WorkspaceModel? workspace;
  final TabModel? tab;

  _AgentItem({
    required this.machine,
    required this.agent,
    this.pane,
    this.workspace,
    this.tab,
  });
}

/// Unified Material 3 home screen listing all AI agents across all machines.
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
        final client = widget.client;
        final machines = client.machines;

        if (machines.isEmpty) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Agents'),
              actions: [
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _openSettings,
                ),
              ],
            ),
            body: _buildEmptyMachinesState(context, scheme),
          );
        }

        // Gather all agents across all machines
        final allAgents = <_AgentItem>[];
        for (final m in machines) {
          final snapshot = client.snapshotOf(m);
          final paneById = {for (final p in snapshot?.panes ?? <PaneModel>[]) p.id: p};
          final wsById = {for (final w in snapshot?.workspaces ?? <WorkspaceModel>[]) w.id: w};
          final tabById = {for (final t in snapshot?.tabs ?? <TabModel>[]) t.id: t};

          for (final agent in snapshot?.agents ?? <AgentModel>[]) {
            final pane = paneById[agent.paneId];
            allAgents.add(_AgentItem(
              machine: m,
              agent: agent,
              pane: pane,
              workspace: pane != null ? wsById[pane.workspaceId] : null,
              tab: pane != null ? tabById[pane.tabId] : null,
            ));
          }
        }

        // Sort by urgency: blocked first, then working, then done, then idle
        final sortedAgents = [
          for (final s in _urgency) ...allAgents.where((item) => item.agent.status == s),
          ...allAgents.where((item) => !_urgency.contains(item.agent.status)),
        ];

        return Scaffold(
          drawer: WorkspaceDrawer(client: client, openTerminalOnSelect: true),
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
          body: sortedAgents.isEmpty
              ? _buildNoAgentsState(context, scheme)
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: sortedAgents.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                  itemBuilder: (context, i) => _buildDismissibleAgentTile(
                    context,
                    sortedAgents[i],
                    machines.length > 1,
                    scheme,
                  ),
                ),
        );
      },
    );
  }

  Widget _buildEmptyMachinesState(BuildContext context, ColorScheme scheme) {
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

  Widget _buildNoAgentsState(BuildContext context, ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline_rounded, size: 64, color: scheme.secondary),
            const SizedBox(height: 16),
            Text(
              'No agents running',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'All tasks are completed or idle across your connected machines.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDismissibleAgentTile(
    BuildContext context,
    _AgentItem item,
    bool showMachineName,
    ColorScheme scheme,
  ) {
    final client = widget.client;
    final agent = item.agent;
    final isMuted = client.isMuted(agent.paneId, item.machine);
    final isBlocked = agent.status == 'blocked';

    final wsLabel = item.workspace?.displayName ?? '';
    final branch = item.workspace?.gitBranch;
    final tabLabel = item.tab?.displayName ?? '';

    final subtitleParts = [
      if (showMachineName) client.nameOf(item.machine),
      if (wsLabel.isNotEmpty) wsLabel,
      if (branch != null && branch.isNotEmpty) branch,
      if (tabLabel.isNotEmpty && tabLabel != wsLabel) tabLabel,
      if (item.pane?.terminalTitle.isNotEmpty == true) item.pane!.terminalTitle,
    ];

    return Dismissible(
      key: Key('${item.machine}/${agent.paneId}'),
      background: Container(
        color: scheme.secondaryContainer,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            Icon(
              isMuted ? Icons.notifications_active : Icons.notifications_off,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Text(
              isMuted ? 'Unmute' : 'Mute',
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
      secondaryBackground: Container(
        color: scheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              'Close',
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.delete_outline, color: scheme.onErrorContainer),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // Swipe right: toggle mute without removing from list
          client.setMuted(agent.paneId, !isMuted, item.machine);
          return false;
        } else if (direction == DismissDirection.endToStart) {
          // Swipe left: close pane and remove from list
          if (client.machine != item.machine) {
            client.switchMachine(item.machine);
          }
          client.closePane(agent.paneId);
          return true;
        }
        return false;
      },
      child: ListTile(
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
            if (isMuted) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.notifications_off_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
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
        trailing: isBlocked
            ? Container(
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
              )
            : null,
        onTap: () => _openAgent(item.machine, agent.paneId),
      ),
    );
  }
}
