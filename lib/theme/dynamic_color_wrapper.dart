import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:mosix/providers/theme_provider.dart';
import 'package:mosix/providers/custom_font_provider.dart';
import 'package:mosix/theme/app_theme.dart';
import 'package:mosix/models/theme_settings.dart';
import 'package:mosix/theme/mornye_theme.dart';

class DynamicColorWrapper extends ConsumerWidget {
  final Widget Function(ThemeData light, ThemeData dark, ThemeMode mode)
  builder;

  const DynamicColorWrapper({super.key, required this.builder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeSettings = ref.watch(themeProvider);
    final fontFamily = ref.watch(customFontFamilyProvider).asData?.value;

    if (themeSettings.style == AppThemeStyle.mornye) {
      return builder(
        MornyeTheme.build(
          Brightness.light,
          accent: themeSettings.mornyeAccent,
          useSystemFont: themeSettings.useSystemFont,
          fontFamily: fontFamily,
          glassClarity: themeSettings.mornyeGlassClarity,
          glassOutlines: themeSettings.mornyeGlassOutlines,
        ),
        MornyeTheme.build(
          Brightness.dark,
          accent: themeSettings.mornyeAccent,
          useSystemFont: themeSettings.useSystemFont,
          fontFamily: fontFamily,
          glassClarity: themeSettings.mornyeGlassClarity,
          glassOutlines: themeSettings.mornyeGlassOutlines,
        ),
        themeSettings.themeMode,
      );
    }

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        ColorScheme lightScheme;
        ColorScheme darkScheme;

        if (themeSettings.useDynamicColor &&
            lightDynamic != null &&
            darkDynamic != null) {
          lightScheme = _toFlutterColorScheme(lightDynamic);
          darkScheme = _toFlutterColorScheme(darkDynamic);
        } else {
          final seedColor = themeSettings.seedColor;
          lightScheme = ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: Brightness.light,
          );
          darkScheme = ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: Brightness.dark,
          );
        }

        if (themeSettings.useAmoled) {
          darkScheme = _applyAmoledColors(darkScheme);
        }

        final lightTheme = AppTheme.light(
          dynamicScheme: lightScheme,
          useSystemFont: themeSettings.useSystemFont,
          fontFamily: fontFamily,
        );
        final darkTheme = AppTheme.dark(
          dynamicScheme: darkScheme,
          isAmoled: themeSettings.useAmoled,
          useSystemFont: themeSettings.useSystemFont,
          fontFamily: fontFamily,
        );

        return builder(lightTheme, darkTheme, themeSettings.themeMode);
      },
    );
  }

  ColorScheme _toFlutterColorScheme(material_ui.ColorScheme scheme) {
    return ColorScheme.fromSeed(
      seedColor: scheme.primary,
      brightness: scheme.brightness,
    ).copyWith(
      primary: scheme.primary,
      onPrimary: scheme.onPrimary,
      primaryContainer: scheme.primaryContainer,
      onPrimaryContainer: scheme.onPrimaryContainer,
      secondary: scheme.secondary,
      onSecondary: scheme.onSecondary,
      secondaryContainer: scheme.secondaryContainer,
      onSecondaryContainer: scheme.onSecondaryContainer,
      tertiary: scheme.tertiary,
      onTertiary: scheme.onTertiary,
      tertiaryContainer: scheme.tertiaryContainer,
      onTertiaryContainer: scheme.onTertiaryContainer,
      error: scheme.error,
      onError: scheme.onError,
      errorContainer: scheme.errorContainer,
      onErrorContainer: scheme.onErrorContainer,
      outline: scheme.outline,
      outlineVariant: scheme.outlineVariant,
      surface: scheme.surface,
      onSurface: scheme.onSurface,
      surfaceContainerLowest: scheme.surfaceContainerLowest,
      surfaceContainerLow: scheme.surfaceContainerLow,
      surfaceContainer: scheme.surfaceContainer,
      surfaceContainerHigh: scheme.surfaceContainerHigh,
      surfaceContainerHighest: scheme.surfaceContainerHighest,
      onSurfaceVariant: scheme.onSurfaceVariant,
      inverseSurface: scheme.inverseSurface,
      onInverseSurface: scheme.onInverseSurface,
      inversePrimary: scheme.inversePrimary,
      shadow: scheme.shadow,
      surfaceTint: scheme.surfaceTint,
      scrim: scheme.scrim,
    );
  }

  /// Apply AMOLED colors - pure black background with adjusted surface colors
  ColorScheme _applyAmoledColors(ColorScheme scheme) {
    return scheme.copyWith(
      surface: Colors.black,
      onSurface: Colors.white,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF0A0A0A),
      surfaceContainer: const Color(0xFF121212),
      surfaceContainerHigh: const Color(0xFF1A1A1A),
      surfaceContainerHighest: const Color(0xFF222222),
      inverseSurface: Colors.white,
      onInverseSurface: Colors.black,
    );
  }
}
