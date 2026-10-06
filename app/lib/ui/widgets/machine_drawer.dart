import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../services/herdr_client.dart';

/// The connection's color: green connected, yellow connecting, grey disconnected.
Color machineColor(BuildContext context, HerdrClientService client, String m) => client.isConnected(m)
    ? AgentStatus.done.color
    : client.isOff(m)
        ? Theme.of(context).colorScheme.outline
        : AgentStatus.working.color;

/// The foot of the workspace drawer: every saved machine with its connection and what its agents are
/// doing. Each one connects or disconnects on its own, so several can be connected at once; tapping one
/// shows it.
class MachineList extends StatelessWidget {
  final HerdrClientService client;

  const MachineList({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 16, 10),
          child:
              Text('Machines', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
        if (client.machines.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(horizontal: 28), child: Text('No machines yet')),
        for (final m in client.machines)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.only(left: 16, right: 8),
              selected: m == client.machine,
              leading: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(shape: BoxShape.circle, color: machineColor(context, client, m)),
              ),
              minLeadingWidth: 10,
              title: Text(client.nameOf(m), overflow: TextOverflow.ellipsis),
              subtitle: Text(
                client.isOff(m)
                    ? 'Disconnected'
                    : client.isConnected(m)
                        ? client.summaryOf(m)
                        : 'Connecting…',
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Switch(
                value: !client.isOff(m),
                onChanged: (on) => on ? client.connect(m) : client.disconnect(m),
              ),
              onTap: () {
                if (m != client.machine) client.switchMachine(m);
                Navigator.pop(context);
              },
            ),
          ),
      ],
    );
  }
}
