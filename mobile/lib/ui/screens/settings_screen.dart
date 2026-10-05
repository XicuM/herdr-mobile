import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';

class SettingsScreen extends StatefulWidget {
  final HerdrClientService client;

  const SettingsScreen({super.key, required this.client});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _nameController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '7788');

  void _addMachine() {
    final host = _hostController.text.trim();
    widget.client.configure(
      host: host,
      port: int.tryParse(_portController.text.trim()) ?? 7788,
      name: _nameController.text.trim(),
    );
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final section = TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: primary);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Machines', style: section),
          // Switching lives in the app bar and drawer; here machines are only added or removed.
          for (final m in widget.client.machines)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.dns, color: m == widget.client.machine ? primary : Colors.white54),
              title: Text(widget.client.nameOf(m)),
              subtitle: widget.client.nameOf(m) == m ? null : Text(m),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.delete_outline, color: Colors.white54),
                onPressed: () => setState(() => widget.client.removeMachine(m)),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
              hintText: 'e.g. laptop',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Host (Tailscale IP or LAN address)',
              hintText: 'e.g. 100.x.y.z or 192.168.1.50',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _portController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Bridge Port',
              hintText: '7788',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder(
            valueListenable: _hostController,
            builder: (context, host, _) => FilledButton.icon(
              onPressed: host.text.trim().isEmpty ? null : _addMachine,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              icon: const Icon(Icons.add),
              label: const Text('Add & Connect'),
            ),
          ),
          const SizedBox(height: 28),
          Text('Terminal', style: section),
          const SizedBox(height: 8),
          Text(
            'Font size: ${widget.client.fontSize.round()}  (pinch or volume keys also adjust it)',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          Slider(
            value: widget.client.fontSize,
            min: HerdrClientService.minFontSize,
            max: HerdrClientService.maxFontSize,
            divisions: (HerdrClientService.maxFontSize - HerdrClientService.minFontSize).round(),
            label: widget.client.fontSize.round().toString(),
            onChanged: (v) => setState(() => widget.client.setFontSize(v)),
          ),
        ],
      ),
    );
  }
}
