import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
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
      // On Android, darkSurface is null and, with no accent picked, `palette` is the device's own Material You scheme.
      final darkSurface = (isDark && client.systemBackground != null) ? client.systemBackground : null;

      final palette = client.pickedSeed == null ? client.systemPalette : null;
      var scheme = palette != null
          ? _fromPalette(palette, brightness)
          : ColorScheme.fromSeed(
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
        final key = (client.seed, client.systemBackground, client.pickedSeed, client.systemSeed);
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

/// The device's Material You scheme, from its tonal palettes as Android resolves them, not regenerated from
/// one seed: a neutral accent stays neutral. `fromSeed` fills the roles the legacy `Scheme` lacks.
ColorScheme _fromPalette(CorePalette palette, Brightness brightness) {
  final s = brightness == Brightness.dark
      ? Scheme.darkFromCorePalette(palette)
      : Scheme.lightFromCorePalette(palette);
  return ColorScheme.fromSeed(
          seedColor: Color(s.primary), brightness: brightness)
      .copyWith(
    primary: Color(s.primary),
    onPrimary: Color(s.onPrimary),
    primaryContainer: Color(s.primaryContainer),
    onPrimaryContainer: Color(s.onPrimaryContainer),
    secondary: Color(s.secondary),
    onSecondary: Color(s.onSecondary),
    secondaryContainer: Color(s.secondaryContainer),
    onSecondaryContainer: Color(s.onSecondaryContainer),
    tertiary: Color(s.tertiary),
    onTertiary: Color(s.onTertiary),
    tertiaryContainer: Color(s.tertiaryContainer),
    onTertiaryContainer: Color(s.onTertiaryContainer),
    error: Color(s.error),
    onError: Color(s.onError),
    errorContainer: Color(s.errorContainer),
    onErrorContainer: Color(s.onErrorContainer),
    outline: Color(s.outline),
    outlineVariant: Color(s.outlineVariant),
    surface: Color(s.surface),
    onSurface: Color(s.onSurface),
    onSurfaceVariant: Color(s.onSurfaceVariant),
    inverseSurface: Color(s.inverseSurface),
    onInverseSurface: Color(s.inverseOnSurface),
    inversePrimary: Color(s.inversePrimary),
    surfaceTint: Color(s.primary),
  );
}
