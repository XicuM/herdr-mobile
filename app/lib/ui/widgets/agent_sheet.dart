import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/herdr_client.dart';

const _urgency = ['blocked', 'working', 'done', 'idle'];

/// Every agent on the machine, most urgent first, opened from [AgentsButton]. Tap one to show its pane.
void showAgentSheet(BuildContext context, HerdrClientService client) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: client,
      builder: (_, __) {
        final snapshot = client.snapshot;
        final agents = snapshot?.agents ?? <AgentModel>[];
        final paneById = {for (final p in snapshot?.panes ?? <PaneModel>[]) p.id: p};
        final wsName = {for (final w in snapshot?.workspaces ?? <WorkspaceModel>[]) w.id: w.displayName};
        final tabName = {for (final t in snapshot?.tabs ?? <TabModel>[]) t.id: t.displayName};

        final scheme = Theme.of(sheetContext).colorScheme;
        // Pills, like the workspace drawer's destinations.
        return ListTileTheme.merge(
          shape: const StadiumBorder(),
          selectedColor: scheme.onSecondaryContainer,
          selectedTileColor: scheme.secondaryContainer,
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 0, 16, 10),
                    child: Text('Agents',
                        style: Theme.of(sheetContext).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                  if (agents.isEmpty)
                    const Padding(padding: EdgeInsets.fromLTRB(28, 0, 28, 24), child: Text('No agents running')),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        for (final agent in [
                          for (final s in _urgency) ...agents.where((a) => a.status == s),
                          ...agents.where((a) => !_urgency.contains(a.status)),
                        ])
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: ListTile(
                              selected: agent.paneId == client.selectedPaneId,
                              leading: StatusDot(agent.status),
                              minLeadingWidth: 8,
                              title: Text(agent.name, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                [wsName[paneById[agent.paneId]?.workspaceId], tabName[paneById[agent.paneId]?.tabId]]
                                    .whereType<String>()
                                    .join(' · '),
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: client.isMuted(agent.paneId) ? 'Unmute' : 'Mute',
                                    isSelected: client.isMuted(agent.paneId),
                                    icon: const Icon(Icons.notifications_none),
                                    selectedIcon: const Icon(Icons.notifications_off),
                                    onPressed: () => client.setMuted(agent.paneId, !client.isMuted(agent.paneId)),
                                  ),
                                  IconButton(
                                    tooltip: 'Close',
                                    icon: const Icon(Icons.close),
                                    onPressed: () => client.closePane(agent.paneId),
                                  ),
                                ],
                              ),
                              onTap: () {
                                client.selectPane(agent.paneId);
                                Navigator.pop(sheetContext);
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// Opens [showAgentSheet]. A square with how many agents there are, badged with how many of the ones
/// not on screen and not muted are blocked.
class AgentsButton extends StatelessWidget {
  final HerdrClientService client;

  const AgentsButton({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final agents = client.snapshot?.agents ?? <AgentModel>[];
    final others = agents.where((a) => a.paneId != client.selectedPaneId && !client.isMuted(a.paneId));
    final blocked = others.where((a) => a.status == 'blocked').length;
    return IconButton(
      tooltip: 'Agents',
      onPressed: () => showAgentSheet(context, client),
      icon: Badge(
        isLabelVisible: blocked > 0,
        backgroundColor: AgentStatus.blocked.color,
        textColor: Theme.of(context).colorScheme.surface,
        label: Text('$blocked'),
        child: Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: color, width: 2)),
          child: Text('${agents.length}', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
        ),
      ),
    );
  }
}
