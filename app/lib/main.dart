import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/herdr_client.dart';
import 'ui/screens/agents_home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final client = HerdrClientService()
    ..load(await SharedPreferences.getInstance())
    ..start();

  runApp(HerdrMobileApp(client: client));
}

class HerdrMobileApp extends StatelessWidget {
  final HerdrClientService client;

  HerdrMobileApp({super.key, required this.client});

  final _messenger = GlobalKey<ScaffoldMessengerState>();

  /// The light and dark themes of an accent: this rebuilds with every snapshot, and making them is costly.
  static (Color, ThemeData, ThemeData)? _themes;

  @override
  Widget build(BuildContext context) {
    // Material 3 throughout: colors come from the scheme's roles and text from its type scale. Only the
    // terminal uses the mono font.
    ThemeData theme(Brightness brightness) {
      final scheme = ColorScheme.fromSeed(seedColor: client.seed, brightness: brightness);
      return ThemeData(
        colorScheme: scheme,
        bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: scheme.surfaceContainerHighest,
          contentTextStyle: TextStyle(color: scheme.onSurface),
          actionTextColor: scheme.primary,
        ),
      );
    }
    return ListenableBuilder(
      listenable: client,
      builder: (_, home) {
        if (_themes?.$1 != client.seed) _themes = (client.seed, theme(Brightness.light), theme(Brightness.dark));
        return MaterialApp(
          title: 'Herdr Mobile',
          scaffoldMessengerKey: _messenger,
          debugShowCheckedModeBanner: false,
          theme: _themes!.$2,
          darkTheme: _themes!.$3,
          themeMode: switch (client.brightness) {
            Brightness.light => ThemeMode.light,
            Brightness.dark => ThemeMode.dark,
            null => ThemeMode.system,
          },
          home: home,
        );
      },
      child: AgentsHomeScreen(client: client),
    );
  }
}
