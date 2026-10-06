import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';

/// A dot in the connection's color, from the scheme so it can't be read as an agent's status: primary
/// connected, error unreachable, tertiary connecting, outline disconnected.
Widget machineDot(BuildContext context, HerdrClientService client, String m) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: client.errorOf(m) != null
          ? scheme.error
          : client.isConnected(m)
              ? scheme.primary
              : client.isOff(m)
                  ? scheme.outline
                  : scheme.tertiary,
    ),
  );
}

/// How [m] is doing, in a few words: its agents, or why it isn't showing them.
String machineStatus(HerdrClientService client, String m) {
  final parent = HerdrClientService.parentOf(m);
  if (client.isOff(m)) return 'Disconnected';
  if (client.errorOf(m) case final error?) return error;
  if (client.isConnected(m)) return client.summaryOf(m);
  if (parent != null && !client.isConnected(parent)) return 'Waiting for ${client.nameOf(parent)}';
  return 'Connecting…';
}

/// The foot of the workspace drawer: every saved machine with its connection and what its agents are
/// doing. Each one connects or disconnects on its own, so several can be connected at once; tapping one
/// shows it. The machines a bridge reaches over SSH sit indented under it, and its switch is theirs too.
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
            padding: EdgeInsets.only(left: HerdrClientService.parentOf(m) == null ? 12 : 36, right: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.only(left: 16, right: 8),
              selected: m == client.machine,
              leading: machineDot(context, client, m),
              minLeadingWidth: 8,
              title: Text(client.nameOf(m), overflow: TextOverflow.ellipsis),
              subtitle: Text(machineStatus(client, m), overflow: TextOverflow.ellipsis),
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
