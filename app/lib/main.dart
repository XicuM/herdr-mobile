import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/herdr_client.dart';
import 'ui/screens/terminal_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final host = prefs.getString('herdr_host');

  final client = HerdrClientService();
  client.setFontSize(prefs.getDouble('terminal_font_size') ?? 14);
  final seed = prefs.getInt('theme_seed');
  if (seed != null) client.setSeed(Color(seed));
  client.setBrightness(Brightness.values.asNameMap()[prefs.getString('theme_mode')]);
  client.setKeyBar(prefs.getBool('show_keys') ?? false);
  client.setVolumeKeys(VolumeKeys.values.asNameMap()[prefs.getString('volume_keys')] ?? VolumeKeys.fontSize);
  client.setMutedPanes(prefs.getStringList('muted_panes') ?? []);
  client.setMachines(
    prefs.getStringList('herdr_machines') ?? [],
    prefs.getStringList('herdr_machine_names') ?? [],
    prefs.getStringList('herdr_machines_off') ?? [],
  );
  // On by default; the first launch asks for the permissions it needs.
  final alerts = prefs.getBool('background_alerts');
  client.setAlerts(alerts ?? true, ask: alerts == null);
  // The machine on screen last time; it stays off if it was disconnected.
  if (host != null) client.configure(host: host, port: prefs.getInt('herdr_port') ?? 7788, connect: false);
  client.start();

  runApp(HerdrMobileApp(client: client));
}

class HerdrMobileApp extends StatelessWidget {
  final HerdrClientService client;

  const HerdrMobileApp({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    // Material 3 throughout: colors come from the scheme's roles and text from its type scale. Only the
    // terminal uses the mono font.
    ThemeData theme(Brightness brightness) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: client.seed, brightness: brightness),
          bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
        );
    return ListenableBuilder(
      listenable: client,
      builder: (_, home) => MaterialApp(
        title: 'Herdr Mobile',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        themeMode: switch (client.brightness) {
          Brightness.light => ThemeMode.light,
          Brightness.dark => ThemeMode.dark,
          null => ThemeMode.system,
        },
        home: home,
      ),
      child: TerminalScreen(client: client),
    );
  }
}
