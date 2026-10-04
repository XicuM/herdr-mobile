import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';
import 'agent_status_badge.dart';
import '../screens/settings_screen.dart';

class WorkspaceDrawer extends StatelessWidget {
  final HerdrClientService client;

  const WorkspaceDrawer({
    super.key,
    required this.client,
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = client.snapshot;

    return Drawer(
      backgroundColor: const Color(0xFF181818),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              alignment: Alignment.centerLeft,
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.white12)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.hub_outlined, color: Colors.blueAccent),
                  const SizedBox(width: 10),
                  const Text(
                    'Herdr Workspaces',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: client.connected ? Colors.greenAccent : Colors.redAccent,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: snapshot == null
                  ? const Center(
                      child: Text(
                        'Connecting to Herdr...',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.builder(
                      itemCount: snapshot.workspaces.length,
                      itemBuilder: (context, wsIndex) {
                        final ws = snapshot.workspaces[wsIndex];
                        final wsPanes = snapshot.panes
                            .where((p) => p.workspaceId == ws.id)
                            .toList();

                        return ExpansionTile(
                          initiallyExpanded: true,
                          leading: const Icon(Icons.folder_outlined, color: Colors.white70),
                          title: Text(
                            ws.label.isNotEmpty ? ws.label : 'Workspace ${ws.number}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${ws.tabCount} tabs · ${ws.paneCount} panes',
                            style: const TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                          children: wsPanes.map((pane) {
                            final isSelected = client.selectedPaneId == pane.id;
                            final agent = snapshot.agents
                                .where((a) => a.paneId == pane.id)
                                .firstOrNull;

                            return ListTile(
                              selected: isSelected,
                              selectedTileColor: Colors.blueAccent.withOpacity(0.15),
                              contentPadding: const EdgeInsets.only(left: 36, right: 16),
                              leading: Icon(
                                Icons.terminal,
                                size: 18,
                                color: isSelected ? Colors.blueAccent : Colors.white54,
                              ),
                              title: Text(
                                pane.terminalTitle.isNotEmpty
                                    ? pane.terminalTitle
                                    : 'Pane ${pane.id}',
                                style: TextStyle(
                                  color: isSelected ? Colors.blueAccent : Colors.white,
                                  fontSize: 14,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                              trailing: AgentStatusBadge(
                                status: agent?.status ?? pane.agentStatus,
                                agentName: agent?.name,
                                compact: true,
                              ),
                              onTap: () {
                                client.selectPane(pane.id);
                                Navigator.pop(context);
                              },
                            );
                          }).toList(),
                        );
                      },
                    ),
            ),
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white12)),
              ),
              child: ListTile(
                leading: const Icon(Icons.settings_outlined, color: Colors.white70),
                title: const Text('Settings', style: TextStyle(color: Colors.white70)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(client: client),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
