import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/herdr_client.dart';

class SettingsScreen extends StatefulWidget {
  final HerdrClientService client;

  const SettingsScreen({super.key, required this.client});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _ntfyController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.client.host);
    _portController = TextEditingController(text: widget.client.port.toString());
    _ntfyController = TextEditingController();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _hostController.text = prefs.getString('herdr_host') ?? widget.client.host;
      _portController.text = (prefs.getInt('herdr_port') ?? widget.client.port).toString();
      _ntfyController.text = prefs.getString('ntfy_topic') ?? '';
    });
  }

  Future<void> _savePreferences() async {
    setState(() => _saving = true);
    final prefs = await SharedPreferences.getInstance();
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 7788;
    final ntfy = _ntfyController.text.trim();

    await prefs.setString('herdr_host', host);
    await prefs.setInt('herdr_port', port);
    await prefs.setString('ntfy_topic', ntfy);

    widget.client.configure(host: host, port: port);

    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved & reconnecting...')),
      );
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _ntfyController.dispose();
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
            'Connection Configuration',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.blueAccent,
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
          const SizedBox(height: 28),
          const Text(
            'Push Notifications (ntfy.sh)',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.blueAccent,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Enter your private ntfy.sh topic name to receive phone alerts when an agent is waiting for approval or finishes a task.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ntfyController,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'ntfy Topic',
              hintText: 'e.g. my-private-agents-1234',
              labelStyle: TextStyle(color: Colors.white70),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _saving ? null : _savePreferences,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            icon: const Icon(Icons.save),
            label: Text(_saving ? 'Saving...' : 'Save & Reconnect'),
          ),
        ],
      ),
    );
  }
}
