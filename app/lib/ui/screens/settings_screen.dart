import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';

class SettingsScreen extends StatefulWidget {
  final HerdrClientService client;

  const SettingsScreen({super.key, required this.client});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Accent colours to pick from, besides the system's.
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

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final scheme = Theme.of(context).colorScheme;
    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
        );

    return ListenableBuilder(
      listenable: client,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          children: [
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
                  // Material You's accent, the default where there is one.
                  if (client.systemSeed case final color?)
                    IconButton.filled(
                      tooltip: 'System',
                      style: IconButton.styleFrom(backgroundColor: color),
                      icon: Icon(client.pickedSeed == null ? Icons.check : Icons.wallpaper, color: Colors.black),
                      onPressed: () => setState(() => client.setSeed(null)),
                    ),
                  for (final color in _seeds)
                    IconButton.filled(
                      style: IconButton.styleFrom(backgroundColor: color),
                      icon: Icon(Icons.check,
                          color: color == client.seed && client.systemSeed != client.seed
                              ? Colors.black
                              : Colors.transparent),
                      onPressed: () => setState(() => client.setSeed(color)),
                    ),
                ],
              ),
            ),
            const Divider(),
            section('Notifications'),
            SwitchListTile(
              title: const Text('Agent alerts'),
              subtitle: const Text(
                  'Alert when an agent on any saved machine needs input or finishes, even in the background.'),
              value: client.alerts,
              onChanged: (v) => setState(() => client.setAlerts(v)),
            ),
            if (client.alerts) ...[
              SwitchListTile(
                title: const Text('Needs you'),
                subtitle: const Text('Alert when an agent is blocked or waiting for input'),
                value: client.alertBlocked,
                onChanged: (v) => setState(() => client.setAlertBlocked(v)),
              ),
              SwitchListTile(
                title: const Text('Finished'),
                subtitle: const Text('Alert when an agent finishes its task'),
                value: client.alertFinished,
                onChanged: (v) => setState(() => client.setAlertFinished(v)),
              ),
              SwitchListTile(
                title: const Text('Sound'),
                subtitle: const Text('Play an audio alert tone'),
                value: client.alertSound,
                onChanged: (v) => setState(() => client.setAlertSound(v)),
              ),
              SwitchListTile(
                title: const Text('Desktop notifications'),
                subtitle: const Text('Show desktop notification banners on Linux'),
                value: client.alertDesktop,
                onChanged: (v) => setState(() => client.setAlertDesktop(v)),
              ),
            ],
            const Divider(),
            section('Terminal'),
            ListTile(
              title: const Text('Font size'),
              subtitle: client.pinchZoom || client.volumeKeys == VolumeKeys.fontSize
                  ? Text('Or ${[
                      if (client.pinchZoom) 'pinch the terminal',
                      if (client.volumeKeys == VolumeKeys.fontSize) 'use the volume keys',
                    ].join(', or ')}')
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: client.fontSize > HerdrClientService.minFontSize
                        ? () => setState(() => client.setFontSize(client.fontSize - 1))
                        : null,
                  ),
                  Text('${client.fontSize.round()}', style: Theme.of(context).textTheme.labelLarge),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: client.fontSize < HerdrClientService.maxFontSize
                        ? () => setState(() => client.setFontSize(client.fontSize + 1))
                        : null,
                  ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Pinch to zoom'),
              subtitle: const Text('Pinch the terminal with two fingers to change the font size'),
              value: client.pinchZoom,
              onChanged: (v) => setState(() => client.setPinchZoom(v)),
            ),
            SwitchListTile(
              title: const Text('Hide message terminal'),
              subtitle: const Text('Hide the message input and control keys bar at the bottom of the terminal'),
              value: client.hideMessageTerminal,
              onChanged: (v) => setState(() => client.setHideMessageTerminal(v)),
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
      ),
    );
  }
}
