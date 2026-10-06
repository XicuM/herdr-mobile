import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../services/herdr_client.dart';
import 'workspace_drawer.dart';

/// The current workspace's tabs, opened by swiping up on the message bar or tapping the tab dots. The current
/// tab's split panes are listed under it, so a pane that isn't the tab's focused one can be reached.
void showTabSheet(BuildContext context, HerdrClientService client) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: client,
      builder: (_, __) {
        final scheme = Theme.of(sheetContext).colorScheme;
        final snapshot = client.snapshot;
        final pane = snapshot?.panes.where((p) => p.id == client.selectedPaneId).firstOrNull;
        if (snapshot == null || pane == null) return const SizedBox(height: 120);
        final workspace = snapshot.workspaces.where((w) => w.id == pane.workspaceId).firstOrNull;
        final tabs = snapshot.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
        final splits = snapshot.panes.where((p) => p.tabId == pane.tabId).toList();
        final tabOf = {for (final p in snapshot.panes) p.id: p.tabId};
        String? agentOf(String? paneId) => snapshot.agents.where((a) => a.paneId == paneId).firstOrNull?.name;

        void go(VoidCallback select) {
          select();
          Navigator.pop(sheetContext);
        }

        Widget row({
          required String status,
          required String title,
          String? subtitle,
          required bool selected,
          double indent = 0,
          required VoidCallback onTap,
          Widget? trailing,
        }) =>
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ListTile(
                shape: const StadiumBorder(),
                contentPadding: EdgeInsets.only(left: 16 + indent, right: 4),
                selected: selected,
                selectedColor: scheme.onSecondaryContainer,
                selectedTileColor: scheme.secondaryContainer,
                leading: StatusDot(status),
                minLeadingWidth: 8,
                title: Text(title, overflow: TextOverflow.ellipsis),
                subtitle: subtitle == null ? null : Text(subtitle, overflow: TextOverflow.ellipsis),
                trailing: trailing,
                onTap: onTap,
              ),
            );

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          workspace?.displayName ?? 'Tabs',
                          style: Theme.of(sheetContext).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.add),
                        label: const Text('New tab'),
                        onPressed: () => go(() => client.createTab(pane.workspaceId)),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      for (final t in tabs) ...[
                        row(
                          status: t.agentStatus,
                          // Herdr marks only one pane in the whole session as focused, so find the tab's
                          // agent through any of its panes, preferring the one on screen.
                          title: () {
                            final agent = agentOf(t.id == pane.tabId ? pane.id : null) ??
                                snapshot.agents.where((a) => tabOf[a.paneId] == t.id).firstOrNull?.name;
                            return agent == null ? tabLabel(t) : '${tabLabel(t)} · $agent';
                          }(),
                          selected: t.id == pane.tabId,
                          onTap: () => go(() => client.selectTab(t.id)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Rename tab',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () async {
                                  final name = await WorkspaceDrawer.prompt(sheetContext, 'Rename tab', 'Tab name',
                                      initial: t.label);
                                  if (name != null) client.renameTab(t.id, name);
                                },
                              ),
                              IconButton(
                                tooltip: 'Close tab',
                                icon: const Icon(Icons.close),
                                onPressed: () => client.closeTab(t.id),
                              ),
                            ],
                          ),
                        ),
                        if (t.id == pane.tabId && splits.length > 1)
                          for (final (i, p) in splits.indexed)
                            row(
                              indent: 24,
                              status: p.agentStatus,
                              title: agentOf(p.id) ?? (p.terminalTitle.isNotEmpty ? p.terminalTitle : 'Pane ${i + 1}'),
                              selected: p.id == pane.id,
                              onTap: () => go(() => client.selectPane(p.id)),
                            ),
                      ],
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
