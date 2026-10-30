import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/providers/settings_provider.dart';

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
final mosixGlassContrastBlockedProvider = Provider.family<bool, bool>(
  (ref, highContrast) =>
      highContrast &&
      !ref.watch(settingsProvider.select((s) => s.forceBackdropBlur)),
);

/// How much of Mosix's glass the device renders.
enum MosixGlassLevel {
  /// Opaque surfaces; no backdrop sampling.
  flat,

  /// Translucent surfaces over one backdrop blur; no shader passes.
  frosted,

  /// Impeller backdrop refraction, with a blur fallback on other renderers.
  liquid,
}

final mosixGlassLevelProvider = Provider<MosixGlassLevel>((ref) {
  final lowEnd = ref.watch(lowEndDeviceProvider);
  if (!lowEnd && ref.watch(deviceSupportsLiquidGlassProvider)) {
    return MosixGlassLevel.liquid;
  }
  // The user's "always use blur effects" override restores the full material.
  if (ref.watch(backdropBlurEnabledProvider)) return MosixGlassLevel.liquid;
  return lowEnd ? MosixGlassLevel.flat : MosixGlassLevel.frosted;
});

/// Backdrop blur for Mosix surfaces (frosted or liquid).
final mosixBlurEnabledProvider = Provider<bool>(
  (ref) => ref.watch(mosixGlassLevelProvider) != MosixGlassLevel.flat,
);

/// Higher-quality glass and continuously filtered artwork / lyric effects.
final mosixLiquidGlassProvider = Provider<bool>(
  (ref) => ref.watch(mosixGlassLevelProvider) == MosixGlassLevel.liquid,
);
