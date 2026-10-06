import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';
import '../widgets/workspace_drawer.dart';

class SettingsScreen extends StatefulWidget {
  final HerdrClientService client;

  const SettingsScreen({super.key, required this.client});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Accent colours to pick from; the first is the default.
  static const _seeds = [
    Color(0xFF38BDF8), // sky
    Color(0xFF6366F1), // indigo
    Color(0xFFA855F7), // purple
    Color(0xFFEC4899), // pink
    Color(0xFFEF4444), // red
    Color(0xFFF97316), // orange
    Color(0xFFEAB308), // yellow
    Color(0xFF22C55E), // green
    Color(0xFF14B8A6), // teal
    Color(0xFF94A3B8), // slate
  ];

  /// Takes `host`, `host:port`, an IPv6 address (bare or `[addr]:port`) or a pasted URL; the port defaults
  /// to the bridge's 7788. An IPv6 host keeps its brackets, which `host:port` URLs need.
  static (String, int) _parseAddress(String text) {
    final address = text.trim().replaceFirst(RegExp(r'^\w+://'), '').replaceAll('/', '');
    if (':'.allMatches(address).length > 1 && !address.startsWith('[')) return ('[$address]', 7788);
    final i = address.lastIndexOf(':');
    if (i <= address.lastIndexOf(']')) return (address, 7788);
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

  Future<void> _confirmRemoveMachine(String m) async {
    final ok = await WorkspaceDrawer.confirm(
        context, 'Remove machine?', '"${widget.client.nameOf(m)}" ($m) will be forgotten.', 'Remove');
    if (ok) setState(() => widget.client.removeMachine(m));
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final scheme = Theme.of(context).colorScheme;
    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
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
          section('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<Brightness?>(
              segments: const [
                ButtonSegment(value: null, label: Text('System'), icon: Icon(Icons.brightness_auto_outlined)),
                ButtonSegment(value: Brightness.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                ButtonSegment(value: Brightness.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
              ],
              selected: {client.brightness},
              onSelectionChanged: (s) => setState(() => client.setBrightness(s.first)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final color in _seeds)
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: color),
                    icon: Icon(Icons.check, color: color == client.seed ? Colors.black : Colors.transparent),
                    onPressed: () => setState(() => client.setSeed(color)),
                  ),
              ],
            ),
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
          ListTile(
            title: const Text('Font size'),
            subtitle: Text(client.volumeKeys == VolumeKeys.fontSize
                ? 'Or pinch the terminal, or use the volume keys'
                : 'Or pinch the terminal'),
            trailing: Text('${client.fontSize.round()}', style: Theme.of(context).textTheme.labelLarge),
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
          const ListTile(
            title: Text('Volume keys'),
            subtitle: Text('What the volume keys do while the terminal is on screen'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<VolumeKeys>(
              segments: const [
                ButtonSegment(value: VolumeKeys.fontSize, label: Text('Font size'), icon: Icon(Icons.text_fields)),
                ButtonSegment(value: VolumeKeys.arrows, label: Text('↑ / ↓'), icon: Icon(Icons.unfold_more)),
                ButtonSegment(value: VolumeKeys.volume, label: Text('Volume'), icon: Icon(Icons.volume_up_outlined)),
              ],
              selected: {client.volumeKeys},
              onSelectionChanged: (s) => setState(() => client.setVolumeKeys(s.first)),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
