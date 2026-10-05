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
  client.setMachines(prefs.getStringList('herdr_machines') ?? [], prefs.getStringList('herdr_machine_names') ?? []);
  // On by default; the first launch asks for the permissions it needs.
  final alerts = prefs.getBool('background_alerts');
  client.setAlerts(alerts ?? true, ask: alerts == null);
  // Nothing to connect to until the first machine is added.
  if (host != null) client.configure(host: host, port: prefs.getInt('herdr_port') ?? 7788);

  runApp(HerdrMobileApp(client: client));
}

class HerdrMobileApp extends StatelessWidget {
  final HerdrClientService client;

  const HerdrMobileApp({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    // One surface colour for every piece of chrome around the black terminal.
    const surface = Color(0xFF16181D);
    return MaterialApp(
      title: 'Herdr Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
          surface: surface,
          surfaceContainerLow: surface, // drawer, bottom sheet
          surfaceContainer: const Color(0xFF22252B), // popup menus
          surfaceContainerHigh: const Color(0xFF22252B), // dialogs
        ),
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(backgroundColor: surface, elevation: 0, scrolledUnderElevation: 0),
      ),
      home: TerminalScreen(client: client),
    );
  }
}
