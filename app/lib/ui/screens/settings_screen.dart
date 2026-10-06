import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';

class SettingsScreen extends StatefulWidget {
  final HerdrClientService client;

  const SettingsScreen({super.key, required this.client});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Takes `host`, `host:port` or a pasted URL; the port defaults to the bridge's 7788.
  static (String, int) _parseAddress(String text) {
    final address = text.trim().replaceFirst(RegExp(r'^\w+://'), '').replaceAll('/', '');
    final i = address.lastIndexOf(':');
    if (i < 0) return (address, 7788);
    return (address.substring(0, i), int.tryParse(address.substring(i + 1)) ?? 7788);
  }

  /// Adds a machine when [m] is null (then connects to it and goes back to the terminal), else edits it.
  void _machineDialog([String? m]) {
    final client = widget.client;
    final name = TextEditingController(text: m == null || client.nameOf(m) == m ? '' : client.nameOf(m));
    final address = TextEditingController(text: m ?? '');
    void save(BuildContext dialogContext) {
      if (address.text.trim().isEmpty) return;
      final (host, port) = _parseAddress(address.text);
      Navigator.pop(dialogContext);
      if (m != null) return setState(() => client.updateMachine(m, host: host, port: port, name: name.text.trim()));
      client.configure(host: host, port: port, name: name.text.trim());
      Navigator.pop(context);
    }

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(m == null ? 'Add machine' : 'Edit machine'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
              controller: name,
              autofocus: m != null,
              decoration: const InputDecoration(labelText: 'Name (optional)', border: OutlineInputBorder()),
              onSubmitted: (_) => save(dialogContext),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(onPressed: () => save(dialogContext), child: Text(m == null ? 'Add & connect' : 'Save')),
        ],
      ),
    );
  }

  void _confirmRemoveMachine(String m) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove machine?'),
        content: Text('"${widget.client.nameOf(m)}" ($m) will be forgotten.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () {
              Navigator.pop(dialogContext);
              setState(() => widget.client.removeMachine(m));
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final scheme = Theme.of(context).colorScheme;
    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          section('Machines'),
          for (final m in client.machines)
            ListTile(
              onTap: () => _machineDialog(m),
              leading: Icon(m == client.machine ? Icons.computer : Icons.computer_outlined,
                  color: m == client.machine ? scheme.primary : null),
              title: Text(client.nameOf(m)),
              subtitle: Text([if (client.nameOf(m) != m) m, if (m == client.machine) 'Active'].join(' · ')),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _machineDialog(m),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmRemoveMachine(m),
                  ),
                ],
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Add machine'),
            onTap: _machineDialog,
          ),
          const Divider(),
          section('Notifications'),
          SwitchListTile(
            title: const Text('Agent alerts'),
            subtitle:
                const Text('Alert when an agent on any saved machine needs input or finishes, even in the background.'),
            value: client.alerts,
            onChanged: (v) => setState(() => client.setAlerts(v)),
          ),
          const Divider(),
          section('Terminal'),
          SwitchListTile(
            title: const Text('Control keys bar'),
            subtitle: const Text('Esc, ^C, Tab, Ctrl and the arrows, above the message box'),
            value: client.keyBar,
            onChanged: (v) => setState(() => client.setKeyBar(v)),
          ),
          ListTile(
            title: const Text('Font size'),
            subtitle: const Text('Or pinch the terminal, or use the volume keys'),
            trailing: Text('${client.fontSize.round()} pt', style: Theme.of(context).textTheme.labelLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Slider(
              value: client.fontSize,
              min: HerdrClientService.minFontSize,
              max: HerdrClientService.maxFontSize,
              divisions: (HerdrClientService.maxFontSize - HerdrClientService.minFontSize).round(),
              label: '${client.fontSize.round()}',
              onChanged: (v) => setState(() => client.setFontSize(v)),
            ),
          ),
        ],
      ),
    );
  }
}
