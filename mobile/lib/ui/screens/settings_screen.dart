import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';

class SettingsScreen extends StatefulWidget {
  final HerdrClientService client;

  const SettingsScreen({super.key, required this.client});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '7788');

  void _addMachine() {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    widget.client.configure(host: host, port: int.tryParse(_portController.text.trim()) ?? 7788);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Connecting to ${widget.client.machine}...')),
    );
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: const Color(0xFF1E1E1E),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Machines',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.blueAccent,
            ),
          ),
          for (final m in widget.client.machines)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                m == widget.client.machine ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: m == widget.client.machine ? Colors.blueAccent : Colors.white54,
              ),
              title: Text(m, style: const TextStyle(color: Colors.white)),
              onTap: () {
                widget.client.switchMachine(m);
                Navigator.pop(context);
              },
              trailing: m == widget.client.machine
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.white54),
                      onPressed: () => setState(() =>
                          widget.client.setMachines(widget.client.machines.where((x) => x != m).toList())),
                    ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _hostController,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Host (Tailscale IP or LAN address)',
              hintText: 'e.g. 100.x.y.z or 192.168.1.50',
              labelStyle: TextStyle(color: Colors.white70),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _portController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Bridge Port',
              hintText: '7788',
              labelStyle: TextStyle(color: Colors.white70),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _addMachine,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Add & Connect'),
          ),
          const SizedBox(height: 28),
          const Text(
            'Terminal',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.blueAccent,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Font size: ${widget.client.fontSize.round()}  (volume keys also adjust it)',
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
