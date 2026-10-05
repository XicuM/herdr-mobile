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
  client.setMachines(prefs.getStringList('herdr_machines') ?? []);
  // Nothing to connect to until the first machine is added.
  if (host != null) client.configure(host: host, port: prefs.getInt('herdr_port') ?? 7788);

  runApp(HerdrMobileApp(client: client));
}

class HerdrMobileApp extends StatelessWidget {
  final HerdrClientService client;

  const HerdrMobileApp({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Herdr Mobile',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.blueAccent,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF181818),
          elevation: 0,
        ),
      ),
      home: TerminalScreen(client: client),
    );
  }
}
