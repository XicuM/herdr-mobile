import 'dart:io';
import 'package:flutter/material.dart';
import '../../services/herdr_client.dart';

class SettingsScreen extends StatefulWidget {
  final HerdrClientService client;
  final VoidCallback? onClose;

  const SettingsScreen({super.key, required this.client, this.onClose});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _batteryOptimized;

  @override
  void initState() {
    super.initState();
    _checkBattery();
  }

  void _checkBattery() {
    if (Platform.isAndroid) {
      widget.client.isIgnoringBatteryOptimizations().then((ignored) {
        if (mounted) setState(() => _batteryOptimized = !ignored);
      });
    }
  }

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

  void _showMutedAgents(BuildContext context, HerdrClientService client) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: client,
        builder: (context, _) {
          final muted = client.muted.toList();
          if (muted.isEmpty) {
            return const SizedBox(
              height: 160,
              child: Center(child: Text('No muted agents')),
            );
          }
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                  child: Row(
                    children: [
                      Text('Muted agents', style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          client.unmuteAll();
                          Navigator.pop(context);
                        },
                        child: const Text('Unmute all'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: muted.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final key = muted[index];
                      final parts = key.split('/');
                      final m = parts.first;
                      final paneId = parts.sublist(1).join('/');
                      final snap = client.snapshotOf(m);
                      final pane = snap?.panes.where((p) => p.id == paneId).firstOrNull;
                      final agent = snap?.agents.where((a) => a.paneId == paneId).firstOrNull;
                      final ws = snap?.workspaces.where((w) => w.id == pane?.workspaceId).firstOrNull;
                      final agentName = agent?.name.isNotEmpty == true ? agent!.name : '';
                      final title = pane?.terminalTitle.isNotEmpty == true
                          ? pane!.terminalTitle
                          : agentName.isNotEmpty
                              ? agentName
                              : paneId;
                      final subtitle = [if (ws != null) ws.displayName, client.nameOf(m)].join(' · ');

                      return ListTile(
                        leading: const Icon(Icons.notifications_off_outlined),
                        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: subtitle.isNotEmpty ? Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
                        trailing: IconButton(
                          tooltip: 'Unmute',
                          icon: const Icon(Icons.notifications_outlined),
                          onPressed: () {
                            client.setMuted(paneId, false, m);
                            if (client.muted.isEmpty) Navigator.pop(context);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
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

    return ListenableBuilder(
      listenable: client,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: widget.onClose == null,
          leading: widget.onClose != null
              ? IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: widget.onClose,
                )
              : null,
          title: const Text('Settings'),
        ),
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
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Agent alerts'),
              subtitle: const Text(
                  'Alert when an agent on any saved machine needs input or finishes, even in the background.'),
              value: client.alerts,
              onChanged: (v) => setState(() => client.setAlerts(v)),
            ),
            if (client.alerts) ...[
              if (_batteryOptimized == true)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Card(
                    color: scheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.battery_alert, color: scheme.onErrorContainer),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Battery optimization may pause background alerts when asleep.',
                              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              client.askBattery();
                              _checkBattery();
                            },
                            child: const Text('Fix'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              SwitchListTile(
                secondary: const Icon(Icons.error_outline),
                title: const Text('Needs you'),
                subtitle: const Text('Alert when an agent is blocked or waiting for input'),
                value: client.alertBlocked,
                onChanged: (v) => setState(() => client.setAlertBlocked(v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.check_circle_outline),
                title: const Text('Finished'),
                subtitle: const Text('Alert when an agent finishes its task'),
                value: client.alertFinished,
                onChanged: (v) => setState(() => client.setAlertFinished(v)),
              ),
              if (Platform.isAndroid)
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: const Text('System notification settings'),
                  subtitle: const Text('Manage alert sounds, vibration, and channels'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: client.openNotificationSettings,
                ),
              if (Platform.isLinux) ...[
                SwitchListTile(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: const Text('Sound'),
                  subtitle: const Text('Play an audio alert tone'),
                  value: client.alertSound,
                  onChanged: (v) => setState(() => client.setAlertSound(v)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.desktop_windows_outlined),
                  title: const Text('Desktop notifications'),
                  subtitle: const Text('Show desktop notification banners on Linux'),
                  value: client.alertDesktop,
                  onChanged: (v) => setState(() => client.setAlertDesktop(v)),
                ),
              ],
            ],
            // Muting shows in the agents' list too, so it's here with alerts off as well.
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('Muted agents'),
              subtitle: Text(client.muted.isEmpty ? 'None' : '${client.muted.length} muted'),
              trailing: client.muted.isNotEmpty ? const Icon(Icons.chevron_right) : null,
              onTap: client.muted.isNotEmpty ? () => _showMutedAgents(context, client) : null,
            ),
            const Divider(),
            section('Terminal'),
            ListTile(
              leading: const Icon(Icons.format_size),
              title: const Text('Font size'),
              subtitle: client.pinchZoom || (Platform.isAndroid && client.volumeKeys == VolumeKeys.fontSize) || Platform.isLinux
                  ? Text('Or ${[
                      if (Platform.isLinux) 'use Ctrl + / Ctrl -',
                      if (client.pinchZoom) 'pinch the terminal',
                      if (Platform.isAndroid && client.volumeKeys == VolumeKeys.fontSize) 'use the volume keys',
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
              secondary: const Icon(Icons.pinch_outlined),
              title: const Text('Pinch to zoom'),
              subtitle: const Text('Pinch the terminal with two fingers to change the font size'),
              value: client.pinchZoom,
              onChanged: (v) => setState(() => client.setPinchZoom(v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.chat_bubble_outline),
              title: const Text('Hide message bar'),
              subtitle: const Text('Hide the message box and control keys under the terminal'),
              value: client.hideMessageTerminal,
              onChanged: (v) => setState(() => client.setHideMessageTerminal(v)),
            ),
            // Only on Android, where the terminal screen takes them ([VolumeKeys]).
            if (Platform.isAndroid) ...[
              const ListTile(
                leading: Icon(Icons.volume_up_outlined),
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
            ],
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
