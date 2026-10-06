import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/herdr_client.dart';
import 'ui/screens/terminal_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final client = HerdrClientService()
    ..load(await SharedPreferences.getInstance())
    ..start();

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
