import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/settings_provider.dart';

/// True on low-end hardware (arm32-only or low-RAM, resolved at startup in
/// main.dart via a ProviderScope override). UI uses it to skip expensive
/// effects like the shell's backdrop blur.
final lowEndDeviceProvider = Provider<bool>((ref) => false);

/// Raw device capability decided by the startup runtime profile (overridden
/// in main.dart). Only the `high` tier enables blur by default.
final deviceSupportsBackdropBlurProvider = Provider<bool>((ref) => false);

/// Whether the GPU supports the higher blur budget and animated artwork /
/// lyric defocus. Glass controls themselves use the same lightweight renderer
/// on every tier. Overridden in main.dart.
final deviceSupportsLiquidGlassProvider = Provider<bool>((ref) => true);

/// Whether backdrop blur effects should render: the device default, or the
/// user's manual override from appearance settings.
final backdropBlurEnabledProvider = Provider<bool>((ref) {
  return ref.watch(deviceSupportsBackdropBlurProvider) ||
      ref.watch(settingsProvider.select((s) => s.forceBackdropBlur));
});

/// Flutter also reports Android's medium contrast as high contrast. Respect
/// that request unless the user explicitly forces glass; this only controls
/// decorative surfaces, never the inherited text or reduced-motion settings.
final mornyeGlassContrastBlockedProvider = Provider.family<bool, bool>(
  (ref, highContrast) =>
      highContrast &&
      !ref.watch(settingsProvider.select((s) => s.forceBackdropBlur)),
);

/// How much of Mornye's glass the device renders.
enum MornyeGlassLevel {
  /// Opaque surfaces; no backdrop sampling.
  flat,

  /// Translucent surfaces over one backdrop blur; no shader passes.
  frosted,

  /// Impeller backdrop refraction, with a blur fallback on other renderers.
  liquid,
}

final mornyeGlassLevelProvider = Provider<MornyeGlassLevel>((ref) {
  final lowEnd = ref.watch(lowEndDeviceProvider);
  if (!lowEnd && ref.watch(deviceSupportsLiquidGlassProvider)) {
    return MornyeGlassLevel.liquid;
  }
  // The user's "always use blur effects" override restores the full material.
  if (ref.watch(backdropBlurEnabledProvider)) return MornyeGlassLevel.liquid;
  return lowEnd ? MornyeGlassLevel.flat : MornyeGlassLevel.frosted;
});

/// Backdrop blur for Mornye surfaces (frosted or liquid).
final mornyeBlurEnabledProvider = Provider<bool>(
  (ref) => ref.watch(mornyeGlassLevelProvider) != MornyeGlassLevel.flat,
);

/// Higher-quality glass and continuously filtered artwork / lyric effects.
final mornyeLiquidGlassProvider = Provider<bool>(
  (ref) => ref.watch(mornyeGlassLevelProvider) == MornyeGlassLevel.liquid,
);
