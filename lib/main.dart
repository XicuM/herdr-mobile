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
  static (Object, ThemeData, ThemeData)? _themes;

  @override
  Widget build(BuildContext context) {
    // Material 3 throughout: colors come from the scheme's roles and text from its type scale. Only the
    // terminal uses the mono font.
    ThemeData theme(Brightness brightness) {
      final isDark = brightness == Brightness.dark;
      // On Linux/Omarchy, use Omarchy's dark surface (background in colors.toml, #0c0b0c).
      // On Android, darkSurface is null so it uses Google's 100% native Material You dynamic scheme from the wallpaper.
      final darkSurface = (isDark && client.systemBackground != null) ? client.systemBackground : null;

      var scheme = ColorScheme.fromSeed(
        seedColor: client.seed,
        brightness: brightness,
        surface: darkSurface,
      );

      if (isDark && darkSurface != null) {
        final bg = darkSurface;
        final seed = client.seed;
        // On Linux/Omarchy with a defined dark background, blend containers smoothly from the
        // dark surface toward the seed color, giving the search bar, main bar, and selected
        // agent rows subtle, cohesive contrast instead of harsh light blocks.
        scheme = scheme.copyWith(
          surface: bg,
          surfaceContainerLowest: Color.lerp(bg, seed, 0.04)!,
          surfaceContainerLow: Color.lerp(bg, seed, 0.07)!,
          surfaceContainer: Color.lerp(bg, seed, 0.10)!,
          surfaceContainerHigh: Color.lerp(bg, seed, 0.14)!,
          surfaceContainerHighest: Color.lerp(bg, seed, 0.18)!,
          secondaryContainer: Color.lerp(bg, seed, 0.22)!,
        );
      }

      return ThemeData(
        colorScheme: scheme,
        bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
      );
    }
    return ListenableBuilder(
      listenable: client,
      builder: (_, home) {
        final key = (client.seed, client.systemBackground);
        if (_themes?.$1 != key) _themes = (key, theme(Brightness.light), theme(Brightness.dark));
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
