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
  client.setKeyBar(prefs.getBool('show_keys') ?? false);
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
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF38BDF8), brightness: Brightness.dark);
    return MaterialApp(
      title: 'Herdr Mobile',
      debugShowCheckedModeBanner: false,
      // Material 3 throughout: colors come from the scheme's roles and text from its type scale. Only the
      // terminal uses the mono font.
      theme: ThemeData(
        colorScheme: scheme,
        bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
        // M3 drawer destinations: pills, the selected one in secondaryContainer.
        listTileTheme: ListTileThemeData(
          shape: const StadiumBorder(),
          selectedColor: scheme.onSecondaryContainer,
          selectedTileColor: scheme.secondaryContainer,
        ),
      ),
      home: TerminalScreen(client: client),
    );
  }
}
