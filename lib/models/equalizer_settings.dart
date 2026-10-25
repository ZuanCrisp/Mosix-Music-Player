import 'dart:math' as math;

/// Portable graphic EQ settings. Gains are independent of the system volume.
class EqualizerSettings {
  const EqualizerSettings({
    this.enabled = false,
    this.gains = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    this.preamp = 0,
    this.bass = 0,
    this.treble = 0,
    this.balance = 0,
    this.autoHeadroom = true,
    this.limiter = true,
    this.compressor = false,
    this.threshold = -18,
    this.ratio = 3,
    this.attack = 10,
    this.release = 150,
  });

  static const bandCounts = [5, 10, 15, 31];
  final bool enabled, autoHeadroom, limiter, compressor;
  final List<double> gains;
  final double preamp, bass, treble, balance;
  final double threshold, ratio, attack, release;

  static const _centers = <int, List<double>>{
    5: [63, 250, 1000, 4000, 16000],
    10: [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
    15: [
      25,
      40,
      63,
      100,
      160,
      250,
      400,
      630,
      1000,
      1600,
      2500,
      4000,
      6300,
      10000,
      16000,
    ],
    31: [
      20,
      25,
      31.5,
      40,
      50,
      63,
      80,
      100,
      125,
      160,
      200,
      250,
      315,
      400,
      500,
      630,
      800,
      1000,
      1250,
      1600,
      2000,
      2500,
      3150,
      4000,
      5000,
      6300,
      8000,
      10000,
      12500,
      16000,
      20000,
    ],
  };

  List<double> get frequencies => _centers[gains.length]!;

  /// Tone controls merge into the graphic curve, identically on both OSes.
  List<double> get effectiveGains => [
    for (var i = 0; i < gains.length; i++)
      (gains[i] +
              bass / (1 + math.pow(frequencies[i] / 180, 2)) +
              treble / (1 + math.pow(5000 / frequencies[i], 2)))
          .clamp(-24.0, 24.0),
  ];

  double get headroom =>
      autoHeadroom ? effectiveGains.fold(0.0, math.max).clamp(0.0, 24.0) : 0;
  double get inputGain => (preamp - headroom).clamp(-48.0, 12.0);

  EqualizerSettings copyWith({
    bool? enabled,
    List<double>? gains,
    double? preamp,
    double? bass,
    double? treble,
    double? balance,
    bool? autoHeadroom,
    bool? limiter,
    bool? compressor,
    double? threshold,
    double? ratio,
    double? attack,
    double? release,
  }) => EqualizerSettings(
    enabled: enabled ?? this.enabled,
    gains: gains == null ? this.gains : List.unmodifiable(gains),
    preamp: preamp ?? this.preamp,
    bass: bass ?? this.bass,
    treble: treble ?? this.treble,
    balance: balance ?? this.balance,
    autoHeadroom: autoHeadroom ?? this.autoHeadroom,
    limiter: limiter ?? this.limiter,
    compressor: compressor ?? this.compressor,
    threshold: threshold ?? this.threshold,
    ratio: ratio ?? this.ratio,
    attack: attack ?? this.attack,
    release: release ?? this.release,
  );

  EqualizerSettings withBandCount(int count) {
    if (!bandCounts.contains(count)) throw const FormatException('Band count');
    final next = EqualizerSettings(gains: List.filled(count, 0));
    return copyWith(gains: [for (final hz in next.frequencies) gainAt(hz)]);
  }

  /// A preset carries a sound; headroom, limiting, compression and balance
  /// stay as the listener set them.
  EqualizerSettings withToneOf(EqualizerSettings preset) => copyWith(
    gains: preset.gains,
    preamp: preset.preamp,
    bass: preset.bass,
    treble: preset.treble,
  );

  double gainAt(double hz, {bool includeTone = false}) {
    final values = includeTone ? effectiveGains : gains;
    final centers = frequencies;
    if (hz <= centers.first) return values.first;
    for (var index = 1; index < centers.length; index++) {
      if (hz <= centers[index]) {
        final fraction =
            math.log(hz / centers[index - 1]) /
            math.log(centers[index] / centers[index - 1]);
        return values[index - 1] +
            (values[index] - values[index - 1]) * fraction;
      }
    }
    return values.last;
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'gains': gains,
    'preamp': preamp,
    'bass': bass,
    'treble': treble,
    'balance': balance,
    'autoHeadroom': autoHeadroom,
    'limiter': limiter,
    'compressor': compressor,
    'threshold': threshold,
    'ratio': ratio,
    'attack': attack,
    'release': release,
  };

  Map<String, dynamic> toNative() => {
    ...toJson(),
    'frequencies': frequencies,
    'gains': effectiveGains,
    'inputGain': inputGain,
  };

  factory EqualizerSettings.fromJson(Map<String, dynamic> json) {
    double number(String key, double fallback, double min, double max) {
      final value = json[key];
      if (value is! num || !value.isFinite) return fallback;
      return value.toDouble().clamp(min, max);
    }

    final raw = json['gains'];
    if (raw is! List ||
        !bandCounts.contains(raw.length) ||
        raw.any((v) => v is! num || !v.isFinite)) {
      throw const FormatException('Invalid equalizer bands');
    }
    return EqualizerSettings(
      enabled: json['enabled'] == true,
      gains: List.unmodifiable(
        raw.map((v) => (v as num).toDouble().clamp(-15.0, 15.0)),
      ),
      preamp: number('preamp', 0, -24, 12),
      bass: number('bass', 0, -12, 12),
      treble: number('treble', 0, -12, 12),
      balance: number('balance', 0, -1, 1),
      autoHeadroom: json['autoHeadroom'] != false,
      limiter: json['limiter'] != false,
      compressor: json['compressor'] == true,
      threshold: number('threshold', -18, -60, 0),
      ratio: number('ratio', 3, 1, 20),
      attack: number('attack', 10, 1, 100),
      release: number('release', 150, 20, 1000),
    );
  }
}

class EqualizerPreset {
  const EqualizerPreset(this.name, this.settings);
  final String name;
  final EqualizerSettings settings;

  Map<String, dynamic> toJson() => {
    'name': name,
    'settings': settings.toJson(),
  };

  factory EqualizerPreset.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final settings = json['settings'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 80 ||
        settings is! Map) {
      throw const FormatException('Invalid equalizer preset');
    }
    return EqualizerPreset(
      name.trim(),
      EqualizerSettings.fromJson(Map<String, dynamic>.from(settings)),
    );
  }

  static final builtIn = <EqualizerPreset>[
    const EqualizerPreset('Flat', EqualizerSettings()),
    for (final entry in <String, List<double>>{
      'Bass boost': [6, 5, 3, 1, 0, 0, 0, 0, 0, 0],
      'Treble boost': [0, 0, 0, 0, 0, 1, 2, 3, 4, 5],
      'Vocal': [-2, -2, -1, 0, 2, 3, 3, 2, 0, -1],
      'Rock': [4, 3, 1, -1, -2, 0, 2, 3, 4, 4],
      'Pop': [-1, 1, 3, 4, 3, 1, -1, -1, 1, 2],
      'Jazz': [3, 2, 1, 1, -1, -1, 0, 1, 2, 3],
      'Classical': [3, 2, 1, 0, -1, -1, 0, 1, 2, 3],
      'Electronic': [5, 4, 1, -1, -2, 0, 1, 3, 4, 4],
      'Acoustic': [3, 2, 1, 2, 2, 2, 3, 2, 1, 2],
    }.entries)
      EqualizerPreset(
        entry.key,
        EqualizerSettings(gains: List.unmodifiable(entry.value)),
      ),
  ];
}
