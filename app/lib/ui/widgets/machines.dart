import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';

/// The machines' panel: every saved machine with how it's doing and a switch. Each connects on its own, so
/// several are on at once. The machines a bridge reaches sit indented under it, and its switch is theirs
/// too. Tap one to edit or remove it; the panel's + adds one ([showMachineDialog]). With [only], just those,
/// unindented, to sit in the search results.
class MachineList extends StatelessWidget {
  final HerdrClientService client;
  final List<String>? only;

  const MachineList({super.key, required this.client, this.only});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (only == null && client.machines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Tap + to add a computer running herdr-bridge.',
              textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    return ListView(
      shrinkWrap: only != null,
      physics: only != null ? const NeverScrollableScrollPhysics() : null,
      padding: only != null ? EdgeInsets.zero : const EdgeInsets.only(bottom: 16),
      children: [
        for (final m in only ?? client.machines)
          GestureDetector(
            onSecondaryTapUp: (_) => showMachineDialog(context, client, m),
            child: ListTile(
            contentPadding:
                EdgeInsets.only(left: only != null || HerdrClientService.parentOf(m) == null ? 16 : 40, right: 16),
            onTap: () => showMachineDialog(context, client, m),
            title: Text(client.nameOf(m), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                if (HerdrClientService.parentOf(m) case final parent?)
                  'via ${client.nameOf(parent)}'
                else if (client.nameOf(m) != m)
                  m,
                machineStatus(client, m),
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: client.errorOf(m) == null ? null : TextStyle(color: scheme.error),
            ),
            trailing: Switch(
              value: !client.isOff(m),
              onChanged: (on) => on ? client.connect(m) : client.disconnect(m),
            ),
          ),
        ),
      ],
    );
  }
}

/// How [m] is doing, in a word or two, or why it isn't showing its agents.
String machineStatus(HerdrClientService client, String m) {
  final parent = HerdrClientService.parentOf(m);
  if (client.isOff(m)) return 'Off';
  if (client.errorOf(m) case final error?) return error;
  if (client.isConnected(m)) return 'Connected';
  if (parent != null && !client.isConnected(parent)) return 'Waiting for ${client.nameOf(parent)}';
  return 'Connecting…';
}

/// Takes `host`, `host:port`, an IPv6 address (bare or `[addr]:port`) or a pasted URL; the port defaults
/// to the bridge's 7788. An IPv6 host keeps its brackets, which `host:port` URLs need.
(String, int) _parseAddress(String text) {
  final address = text.trim().replaceFirst(RegExp(r'^\w+://'), '').replaceAll('/', '');
  if (':'.allMatches(address).length > 1 && !address.startsWith('[')) return ('[$address]', 7788);
  final i = address.lastIndexOf(':');
  if (i <= address.lastIndexOf(']')) return (address, 7788);
  return (address.substring(0, i), int.tryParse(address.substring(i + 1)) ?? 7788);
}

/// Adds a machine when [m] is null (then connects to it), else edits or removes it. One a bridge reaches
/// over SSH only takes a name, its address being the bridge's, and can't be removed: it would come back
/// with the bridge, so switching it off is what keeps it away.
void showMachineDialog(BuildContext context, HerdrClientService client, [String? m]) {
  final reached = m != null && HerdrClientService.parentOf(m) != null;
  final name = TextEditingController(text: m == null || client.nameOf(m) == m ? '' : client.nameOf(m));
  final address = TextEditingController(text: m ?? '');
  void save(BuildContext dialogContext) {
    if (address.text.trim().isEmpty) return;
    final (host, port) = _parseAddress(address.text);
    final to = reached ? m : '$host:$port';
    Navigator.pop(dialogContext);
    if (m != null) return client.updateMachine(m, to: to, name: name.text.trim());
    client.configure(to, name: name.text.trim());
  }

  Future<void> remove(BuildContext dialogContext) async {
    final ok = await showDialog<bool>(
      context: dialogContext,
      builder: (confirmContext) => AlertDialog(
        title: const Text('Remove machine?'),
        content: Text('"${client.nameOf(m!)}" ($m) will be forgotten.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(confirmContext, false), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(confirmContext).colorScheme.error),
            onPressed: () => Navigator.pop(confirmContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !dialogContext.mounted) return;
    Navigator.pop(dialogContext);
    client.removeMachine(m!);
  }

  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(m == null ? 'Add machine' : 'Edit machine'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!reached) ...[
            TextField(
              controller: address,
              autofocus: m == null,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Address',
                helperText: 'Tailscale IP or name; add :port if not 7788',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: name,
            autofocus: m != null,
            decoration: const InputDecoration(labelText: 'Name (optional)', border: OutlineInputBorder()),
            onSubmitted: (_) => save(dialogContext),
          ),
        ],
      ),
      actions: [
        if (m != null && !reached)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => remove(dialogContext),
            child: const Text('Remove'),
          ),
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
        TextButton(onPressed: () => save(dialogContext), child: Text(m == null ? 'Add & connect' : 'Save')),
      ],
    ),
  );
}
