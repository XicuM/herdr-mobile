import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/herdr_client.dart';
import 'workspace_drawer.dart';

const _urgency = ['blocked', 'working', 'done', 'idle'];

/// Every agent on the machine, most urgent first, opened from [AgentsButton]. Tap one to show its pane.
void showAgentSheet(BuildContext context, HerdrClientService client) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: client,
      builder: (_, __) {
        final scheme = Theme.of(sheetContext).colorScheme;
        final snapshot = client.snapshot;
        final agents = snapshot?.agents ?? <AgentModel>[];
        final paneById = {for (final p in snapshot?.panes ?? <PaneModel>[]) p.id: p};
        final wsName = {for (final w in snapshot?.workspaces ?? <WorkspaceModel>[]) w.id: w.displayName};
        final tabName = {for (final t in snapshot?.tabs ?? <TabModel>[]) t.id: tabLabel(t)};

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
                  child: Text('Agents', style: Theme.of(sheetContext).textTheme.titleMedium),
                ),
                if (agents.isEmpty)
                  const Padding(padding: EdgeInsets.fromLTRB(24, 8, 24, 24), child: Text('No agents running.')),
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
                            shape: const StadiumBorder(),
                            selected: agent.paneId == client.selectedPaneId,
                            selectedColor: scheme.onSecondaryContainer,
                            selectedTileColor: scheme.secondaryContainer,
                            leading: StatusDot(agent.status),
                            minLeadingWidth: 8,
                            title: Text(agent.name, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [wsName[paneById[agent.paneId]?.workspaceId], tabName[paneById[agent.paneId]?.tabId]]
                                  .whereType<String>()
                                  .join(' · '),
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Text(AgentStatusExtension.fromString(agent.status).label),
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
        );
      },
    ),
  );
}

/// Opens [showAgentSheet]. A ring with how many agents there are, badged in the most urgent status of
/// the ones not on screen, with the count when some are blocked.
class AgentsButton extends StatelessWidget {
  final HerdrClientService client;

  const AgentsButton({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final agents = client.snapshot?.agents ?? <AgentModel>[];
    final others = agents.where((a) => a.paneId != client.selectedPaneId);
    final top = _urgency.take(3).where((s) => others.any((a) => a.status == s)).firstOrNull;
    final blocked = others.where((a) => a.status == 'blocked').length;
    return IconButton(
      tooltip: 'Agents',
      onPressed: () => showAgentSheet(context, client),
      icon: Badge(
        isLabelVisible: top != null,
        backgroundColor: AgentStatusExtension.fromString(top).color,
        textColor: Colors.black,
        label: blocked > 0 ? Text('$blocked') : null,
        child: Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
          child: Text('${agents.length}', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
        ),
      ),
    );
  }
}
