import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';

/// The machines' panel: every saved machine, a green dot or a warning for how it's doing, and a switch. Each connects on its own, so
/// several are on at once. The machines a bridge reaches sit indented under it, and its switch is theirs
/// too. Tap one to edit or remove it; the panel's + adds either kind ([showMachineDialog]). Its ⋮ moves it up or
/// down, and a long-press drags it; the order is the app's own. With [only], just those, unindented, to sit in the
/// search results.
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
    // [m]'s row; its ⋮ moves it among its siblings, and [drag] is its index to long-press and drag it by.
    Widget row(String m, {int? drag}) {
      final siblings = client.machines.where((x) => HerdrClientService.parentOf(x) == HerdrClientService.parentOf(m));
      final k = siblings.toList().indexOf(m);
      Future<void> menu(Offset at) async {
        final picked = await showMenu<String>(
          context: context,
          position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
          items: [
            if (k > 0)
              const PopupMenuItem(
                  value: 'up', child: ListTile(leading: Icon(Icons.arrow_upward), title: Text('Move up'))),
            if (k + 1 < siblings.length)
              const PopupMenuItem(
                  value: 'down', child: ListTile(leading: Icon(Icons.arrow_downward), title: Text('Move down'))),
            const PopupMenuItem(
                value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit'))),
          ],
        );
        if (!context.mounted) return;
        switch (picked) {
          case 'up':
            client.moveMachine(m, k - 1);
          case 'down':
            client.moveMachine(m, k + 1);
          case 'edit':
            showMachineDialog(context, client, m);
        }
      }

      final tile = GestureDetector(
        key: ValueKey(m),
        onSecondaryTapUp: (d) => menu(d.globalPosition),
        child: ListTile(
          contentPadding:
              EdgeInsets.only(left: only != null || HerdrClientService.parentOf(m) == null ? 16 : 40, right: 4),
          onTap: () => showMachineDialog(context, client, m),
          // A green dot while it shows its agents, a warning when it can't (the why is in its dialog).
          leading: SizedBox(
            width: 24,
            child: client.errorOf(m) != null
                ? Icon(Icons.warning_amber_rounded, color: scheme.error)
                : client.isConnected(m)
                    ? const Center(child: CircleAvatar(radius: 5, backgroundColor: Colors.green))
                    : null,
          ),
          minLeadingWidth: 24,
          title: Text(client.nameOf(m), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: HerdrClientService.parentOf(m) == null && client.nameOf(m) != m
              ? Text(m, maxLines: 1, overflow: TextOverflow.ellipsis)
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: !client.isOff(m),
                onChanged: (on) => on ? client.connect(m) : client.disconnect(m),
              ),
              Builder(
                builder: (context) => IconButton(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => menu((context.findRenderObject() as RenderBox).localToGlobal(Offset.zero)),
                ),
              ),
            ],
          ),
        ),
      );
      return drag == null ? tile : ReorderableDelayedDragStartListener(key: tile.key, index: drag, child: tile);
    }

    if (only != null) {
      return ListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [for (final m in only!) row(m)],
      );
    }
    // Long-press and drag to reorder: a bridge among the bridges, with the machines it reaches, and those
    // among themselves, under it.
    void reorder(List<String> siblings, int from, int to) => client.moveMachine(siblings[from], to > from ? to - 1 : to);
    final bridges = client.machines.where((m) => HerdrClientService.parentOf(m) == null).toList();
    return ReorderableListView(
      padding: const EdgeInsets.only(bottom: 16),
      buildDefaultDragHandles: false,
      onReorder: (from, to) => reorder(bridges, from, to),
      children: [
        for (final (i, b) in bridges.indexed)
          Column(
            key: ValueKey(b),
            children: [
              row(b, drag: bridges.length < 2 ? null : i),
              Builder(builder: (context) {
                final reached = client.machines.where((m) => HerdrClientService.parentOf(m) == b).toList();
                return ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorder: (from, to) => reorder(reached, from, to),
                  children: [
                    for (final (j, m) in reached.indexed) row(m, drag: reached.length < 2 ? null : j),
                  ],
                );
              }),
            ],
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

/// Adds a machine when [m] is null, else edits or removes it. A new one is either a bridge, at its
/// address, or an SSH machine saved in a bridge's herdr (`herdr machine add`), which that bridge then
/// reaches. One a bridge reaches is edited and removed in that herdr, where it comes from: its name and
/// its SSH target.
void showMachineDialog(BuildContext context, HerdrClientService client, [String? m]) {
  final reached = m != null && HerdrClientService.parentOf(m) != null;
  final bridges = client.machines.where((x) => HerdrClientService.parentOf(x) == null).toList();
  var via = bridges.where(client.isConnected).firstOrNull ?? bridges.firstOrNull;
  var ssh = false;
  var busy = false;
  final name = TextEditingController(text: m == null || client.nameOf(m) == m ? '' : client.nameOf(m));
  final address = TextEditingController(text: m ?? '');
  final target = TextEditingController(text: reached ? client.targetOf(m) ?? '' : '');
  final token = TextEditingController(text: m == null || reached ? '' : client.tokenOf(m) ?? '');

  Future<void> save(BuildContext dialogContext, StateSetter setState) async {
    if (ssh || reached) {
      if (target.text.trim().isEmpty || (!reached && via == null)) return;
      setState(() => busy = true);
      final done = reached
          ? await client.editSshMachine(m, target.text.trim(), name.text.trim())
          : await client.addSshMachine(via!, target.text.trim(), name.text.trim());
      if (!dialogContext.mounted) return;
      if (done) return Navigator.pop(dialogContext);
      return setState(() => busy = false);
    }
    if (address.text.trim().isEmpty) return;
    final (host, port) = _parseAddress(address.text);
    final to = reached ? m : '$host:$port';
    final key = token.text.replaceAll(RegExp(r'\s'), '');
    Navigator.pop(dialogContext);
    if (m != null) return client.updateMachine(m, to: to, name: name.text.trim(), token: key);
    client.configure(to, name: name.text.trim(), token: key);
  }

  Future<void> remove(BuildContext dialogContext) async {
    final ok = await showDialog<bool>(
      context: dialogContext,
      builder: (confirmContext) => AlertDialog(
        title: const Text('Remove machine?'),
        content: Text(reached
            ? '"${client.nameOf(m)}" will be removed from herdr on ${client.nameOf(HerdrClientService.parentOf(m)!)}.'
            : '"${client.nameOf(m!)}" ($m) will be forgotten.'),
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
    reached ? client.removeSshMachine(m) : client.removeMachine(m!);
  }

  showDialog(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Text(m == null ? 'Add machine' : 'Edit machine'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (m == null && bridges.isNotEmpty) ...[
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Bridge')),
                    ButtonSegment(value: true, label: Text('SSH')),
                  ],
                  selected: {ssh},
                  onSelectionChanged: busy ? null : (v) => setState(() => ssh = v.first),
                ),
                const SizedBox(height: 16),
              ],
              if (reached) ...[
                if (client.errorOf(m) case final error?) ...[
                  SelectableText(error, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: target,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'SSH target',
                    helperText: 'Changing it sets the machine up there again',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
              ] else if (ssh) ...[
                if (bridges.length > 1) ...[
                  DropdownMenu<String>(
                    initialSelection: via,
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Via'),
                    enabled: !busy,
                    onSelected: (b) => via = b,
                    dropdownMenuEntries: [
                      for (final b in bridges) DropdownMenuEntry(value: b, label: client.nameOf(b))
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: target,
                  autofocus: true,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'SSH target',
                    helperText: 'user@host, saved in herdr on ${client.nameOf(via ?? '')}',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
              ] else ...[
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
                TextField(
                  controller: token,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: const InputDecoration(
                    labelText: 'Token',
                    helperText: 'herdr-bridge --print-token on that computer',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: name,
                autofocus: m != null,
                enabled: !busy,
                decoration: const InputDecoration(labelText: 'Name (optional)', border: OutlineInputBorder()),
                onSubmitted: (_) => save(dialogContext, setState),
              ),
              if (busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
            ],
          ),
          actions: [
            if (m != null)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                onPressed: () => remove(dialogContext),
                child: const Text('Remove'),
              ),
            TextButton(onPressed: busy ? null : () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            TextButton(
              onPressed: busy ? null : () => save(dialogContext, setState),
              child: Text(m == null ? (ssh ? 'Add' : 'Add & connect') : 'Save'),
            ),
          ],
        );
      },
    ),
  );
}
