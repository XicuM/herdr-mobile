import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/herdr_client.dart';
import 'workspaces.dart';

/// The machines' panel: every saved machine, a green dot or a warning for how it's doing, and a switch. Each connects on its own, so
/// several are on at once. The machines a bridge reaches sit indented under it, and its switch is theirs
/// too. Tap one to edit or remove it; the panel's + adds either kind ([showMachinePage]). Hold one and lift to
/// move it up or down (or right-click), hold and drag to reorder it; the order is the app's own. With [only], just those, unindented, to sit in the
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
    // [m]'s row; its menu moves it among its siblings, and [drag] is its index to hold and drag it by.
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
            showMachinePage(context, client, m);
        }
      }

      final tile = HoldMenu(
        key: ValueKey(m),
        onMenu: menu,
        child: ListTile(
          contentPadding:
              EdgeInsets.only(left: only != null || HerdrClientService.parentOf(m) == null ? 16 : 40, right: 16),
          onTap: () => showMachinePage(context, client, m),
          leading: SizedBox(width: 24, child: machineStatusIcon(client, m, scheme)),
          minLeadingWidth: 24,
          title: Text(client.nameOf(m), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: HerdrClientService.parentOf(m) == null && client.nameOf(m) != m
              ? Text(m, maxLines: 1, overflow: TextOverflow.ellipsis)
              : null,
          trailing: Switch(
            value: !client.isOff(m),
            onChanged: (on) => on ? client.connect(m) : client.disconnect(m),
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

/// A green dot while [m] shows its agents, a warning when it can't (the why is [machineStatus]), a hollow
/// dot while it connects, and none while it's off. The one way a machine's state is drawn, everywhere.
Widget? machineStatusIcon(HerdrClientService client, String m, ColorScheme scheme) => client.isOff(m)
    ? null
    : client.errorOf(m) != null
        ? Icon(Icons.warning_amber_rounded, color: scheme.error)
        : Center(
            child: Container(
              width: 10,
              height: 10,
              decoration: client.isConnected(m)
                  ? const BoxDecoration(shape: BoxShape.circle, color: Colors.green)
                  : BoxDecoration(shape: BoxShape.circle, border: Border.all(color: scheme.onSurfaceVariant, width: 1.5)),
            ),
          );

/// How [m] is doing (the whole reason when it fails) beside its switch, on a card: the top of its sheet and
/// its page.
Widget machineStatusCard(HerdrClientService client, String m, ThemeData theme) => Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            SizedBox(width: 24, height: 20, child: machineStatusIcon(client, m, theme.colorScheme)),
            const SizedBox(width: 12),
            Expanded(
              child: SelectableText(machineStatus(client, m),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: client.errorOf(m) != null ? theme.colorScheme.error : null)),
            ),
            const SizedBox(width: 8),
            Switch(
              value: !client.isOff(m),
              onChanged: (on) => on ? client.connect(m) : client.disconnect(m),
            ),
          ],
        ),
      ),
    );

/// [m] at a glance, from the terminal's machine chip: its name and address, Edit ([showMachinePage]), and
/// its status card.
void showMachineSheet(BuildContext context, HerdrClientService client, String m) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: client,
      builder: (sheetContext, _) {
        if (!client.machines.contains(m)) return const SizedBox();
        final theme = Theme.of(sheetContext);
        final scheme = theme.colorScheme;
        final address = HerdrClientService.parentOf(m) == null ? m : client.targetOf(m);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 4),
                  leading: CircleAvatar(
                    backgroundColor: scheme.secondaryContainer,
                    foregroundColor: scheme.onSecondaryContainer,
                    child: Icon(HerdrClientService.parentOf(m) == null ? Icons.lan_outlined : Icons.terminal),
                  ),
                  title: Text(client.nameOf(m),
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  subtitle: address != null && address != client.nameOf(m) ? Text(address) : null,
                  trailing: IconButton.filledTonal(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit',
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      showMachinePage(context, client, m);
                    },
                  ),
                ),
                const SizedBox(height: 12),
                machineStatusCard(client, m, theme),
              ],
            ),
          ),
        );
      },
    ),
  );
}

typedef MachineDetailCallback = void Function(String? m);

class MachineDetailScope extends InheritedWidget {
  final MachineDetailCallback onOpenDetail;

  const MachineDetailScope({super.key, required this.onOpenDetail, required super.child});

  static MachineDetailCallback? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MachineDetailScope>()?.onOpenDetail;

  @override
  bool updateShouldNotify(MachineDetailScope oldWidget) => onOpenDetail != oldWidget.onOpenDetail;
}

/// Adds a machine when [m] is null, else shows it to edit or remove: how it's doing, its switch, its
/// settings, and for a bridge the machines it reaches. A new one is either a bridge, at its address, or an
/// SSH machine saved in a bridge's herdr (`herdr machine add`), which that bridge then reaches. One a
/// bridge reaches is edited and removed in that herdr, where it comes from: its name and its SSH target.
void showMachinePage(BuildContext context, HerdrClientService client, [String? m]) {
  final openDetail = MachineDetailScope.of(context);
  if (openDetail != null) {
    openDetail(m);
    return;
  }
  Navigator.push(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MachineScreen(client: client, machine: m),
    ),
  );
}

class MachineScreen extends StatefulWidget {
  final HerdrClientService client;
  final String? machine;
  final VoidCallback? onClose;

  const MachineScreen({super.key, required this.client, this.machine, this.onClose});

  @override
  State<MachineScreen> createState() => _MachineScreenState();
}

class _MachineScreenState extends State<MachineScreen> {
  HerdrClientService get client => widget.client;
  String? get m => widget.machine;

  late bool reached;
  late List<String> bridges;
  String? via;
  var ssh = false;
  var busy = false;
  late final TextEditingController name;
  late final TextEditingController address;
  late final TextEditingController target;
  late final TextEditingController token;

  @override
  void initState() {
    super.initState();
    reached = m != null && HerdrClientService.parentOf(m!) != null;
    bridges = client.machines.where((x) => HerdrClientService.parentOf(x) == null).toList();
    via = bridges.where(client.isConnected).firstOrNull ?? bridges.firstOrNull;
    name = TextEditingController(text: m == null || client.nameOf(m!) == m ? '' : client.nameOf(m!));
    address = TextEditingController(text: m ?? '');
    target = TextEditingController(text: reached ? client.targetOf(m!) ?? '' : '');
    token = TextEditingController(text: _dashed(_tokenChars(m == null || reached ? '' : client.tokenOf(m!) ?? '')));
  }

  @override
  void dispose() {
    name.dispose();
    address.dispose();
    target.dispose();
    token.dispose();
    super.dispose();
  }

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _save() async {
    if (ssh || reached) {
      if (target.text.trim().isEmpty || (!reached && via == null)) return;
      setState(() => busy = true);
      final done = reached
          ? await client.editSshMachine(m!, target.text.trim(), name.text.trim())
          : await client.addSshMachine(via!, target.text.trim(), name.text.trim());
      if (!mounted) return;
      if (done) return _close();
      return setState(() => busy = false);
    }
    if (address.text.trim().isEmpty) return;
    final (host, port) = _parseAddress(address.text);
    final to = reached ? m! : '$host:$port';
    final key = _tokenChars(token.text);
    _close();
    if (m != null) return client.updateMachine(m!, to: to, name: name.text.trim(), token: key);
    client.configure(to, name: name.text.trim(), token: key);
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (confirmContext) => AlertDialog(
        title: const Text('Remove machine?'),
        content: Text(reached
            ? '"${client.nameOf(m!)}" will be removed from herdr on ${client.nameOf(HerdrClientService.parentOf(m!)!)}.'
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
    if (ok != true || !mounted) return;
    _close();
    reached ? client.removeSshMachine(m!) : client.removeMachine(m!);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        // Gone meanwhile (e.g. its bridge was removed): nothing left to edit.
        if (m != null && !client.machines.contains(m)) return const Scaffold();
        Widget section(String title) => Padding(
              padding: const EdgeInsets.fromLTRB(4, 24, 4, 12),
              child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary)),
            );
        final children = m == null || reached
            ? const <String>[]
            : client.machines.where((x) => HerdrClientService.parentOf(x) == m).toList();
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: widget.onClose == null,
            leading: widget.onClose != null
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: _close,
                  )
                : null,
            title: Text(m == null ? 'Add machine' : client.nameOf(m!)),
            actions: [
              TextButton(
                onPressed: busy ? null : _save,
                child: Text(m == null ? 'Add' : 'Save'),
              ),
              const SizedBox(width: 8),
            ],
            bottom: busy
                ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
                : null,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (m != null) machineStatusCard(client, m!, theme),
              if (m == null && bridges.isNotEmpty)
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, icon: Icon(Icons.lan_outlined), label: Text('Bridge')),
                    ButtonSegment(value: true, icon: Icon(Icons.terminal), label: Text('SSH')),
                  ],
                  selected: {ssh},
                  onSelectionChanged: busy ? null : (v) => setState(() => ssh = v.first),
                ),
              section('Connection'),
              if (reached)
                TextField(
                  controller: target,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'SSH target',
                    prefixIcon: const Icon(Icons.terminal),
                    helperText:
                        'Saved in herdr on ${client.nameOf(HerdrClientService.parentOf(m!)!)}; changing it sets the machine up there again',
                    helperMaxLines: 2,
                    border: const OutlineInputBorder(),
                  ),
                )
              else if (ssh) ...[
                if (bridges.length > 1) ...[
                  DropdownMenu<String>(
                    initialSelection: via,
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Via'),
                    leadingIcon: const Icon(Icons.lan_outlined),
                    enabled: !busy,
                    onSelected: (b) => setState(() => via = b),
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
                    prefixIcon: const Icon(Icons.terminal),
                    helperText: 'user@host, saved in herdr on ${client.nameOf(via ?? '')}',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: address,
                  autofocus: m == null,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    prefixIcon: Icon(Icons.lan_outlined),
                    helperText: 'Tailscale IP or name; add :port if not 7788',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                _TokenField(controller: token),
              ],
              section('Display'),
              TextField(
                controller: name,
                enabled: !busy,
                decoration: InputDecoration(
                  labelText: 'Name',
                  prefixIcon: const Icon(Icons.label_outline),
                  hintText: reached || ssh ? target.text : address.text,
                  helperText: 'Optional; the address is shown without one',
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _save(),
              ),
              if (children.isNotEmpty) ...[
                section('Reached over SSH'),
                MachineList(client: client, only: children),
              ],
              if (m != null) ...[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: !busy,
                  iconColor: scheme.error,
                  textColor: scheme.error,
                  leading: const Icon(Icons.delete_outline),
                  title: Text(reached ? 'Remove from herdr' : 'Remove machine'),
                  subtitle: Text(reached
                      ? 'Deletes it from herdr on ${client.nameOf(HerdrClientService.parentOf(m!)!)}'
                      : 'Forgets it on this phone'),
                  onTap: _remove,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// A token as the bridge compares it: without the spaces and dashes it ignores, in capitals as it prints
/// them (it ignores case too).
String _tokenChars(String s) => s.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

/// [raw] in groups of four, `K3MF-9QXA` as `herdr-bridge --print-token` prints it.
String _dashed(String raw) =>
    [for (var i = 0; i < raw.length; i += 4) raw.substring(i, i + 4 > raw.length ? raw.length : i + 4)].join('-');

/// The bridge's token, one field that groups what is typed or pasted in fours and hides a saved one until
/// asked.
class _TokenField extends StatefulWidget {
  final TextEditingController controller;

  const _TokenField({required this.controller});

  @override
  State<_TokenField> createState() => _TokenFieldState();
}

class _TokenFieldState extends State<_TokenField> {
  late var _hidden = widget.controller.text.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: _hidden,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      textCapitalization: TextCapitalization.characters,
      style: const TextStyle(fontFamily: 'monospace', letterSpacing: 2),
      decoration: InputDecoration(
        labelText: 'Token',
        hintText: 'XXXX-XXXX',
        prefixIcon: const Icon(Icons.key_outlined),
        suffixIcon: IconButton(
          icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          tooltip: _hidden ? 'Show token' : 'Hide token',
          onPressed: () => setState(() => _hidden = !_hidden),
        ),
        helperText: 'Run herdr-bridge --print-token on that computer',
        border: const OutlineInputBorder(),
      ),
      inputFormatters: [
        TextInputFormatter.withFunction((old, v) {
          var raw = _tokenChars(v.text);
          // Raw characters before the cursor, so it stays put as dashes come and go.
          var at = _tokenChars(v.text.substring(0, v.selection.end.clamp(0, v.text.length))).length;
          // Backspace over a dash deletes the character before it.
          if (v.text.length < old.text.length && raw == _tokenChars(old.text) && at > 0) {
            raw = raw.substring(0, at - 1) + raw.substring(at);
            at--;
          }
          return TextEditingValue(
              text: _dashed(raw), selection: TextSelection.collapsed(offset: at + (at > 0 ? (at - 1) ~/ 4 : 0)));
        }),
      ],
    );
  }
}
