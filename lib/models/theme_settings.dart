import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mosix/utils/desktop_platform.dart';

const String kThemeModeKey = 'theme_mode';
const String kUseDynamicColorKey = 'use_dynamic_color';
const String kSeedColorKey = 'seed_color';
const String kUseAmoledKey = 'use_amoled';
const String kThemeStyleKey = 'theme_style';
const String kMosixAccentKey = 'mosix_accent';
const String kLegacyMosixAccentKey = 'mornye_accent';
const String kUseSystemFontKey = 'use_system_font';
const String kCustomFontIdKey = 'custom_font_id';
const String kCustomFontNameKey = 'custom_font_name';
const String kLyricsTextScaleKey = 'lyrics_text_scale';

double normalizeLyricsTextScale(num? value) =>
    value != null && value.isFinite ? value.toDouble().clamp(0.8, 1.4) : 1.0;
const String kMosixGlassClarityKey = 'mosix_glass_clarity';
const String kMosixGlassOutlinesKey = 'mosix_glass_outlines';
const String kLegacyMosixGlassClarityKey = 'mornye_glass_clarity';
const String kLegacyMosixGlassOutlinesKey = 'mornye_glass_outlines';
const double kDefaultMosixGlassClarity = 0.75;

double normalizeMosixGlassClarity(num? value) => value != null && value.isFinite
    ? value.toDouble().clamp(0.0, 1.0)
    : kDefaultMosixGlassClarity;

enum AppThemeStyle { material, mosix }

enum MosixAccent { red, orange, green, teal, blue, purple, pink }

MosixAccent mosixAccentFromString(String? value) =>
    MosixAccent.values.firstWhere(
      (accent) => accent.name == value,
      orElse: () => MosixAccent.red,
    );

/// Style used until the person picks one: Mosix on Android and macOS,
/// Material on Windows, Linux and other mobile platforms.
AppThemeStyle defaultAppThemeStyle() =>
    (defaultTargetPlatform == TargetPlatform.android ||
        (isDesktopPlatform && defaultTargetPlatform == TargetPlatform.macOS))
    ? AppThemeStyle.mosix
    : AppThemeStyle.material;

AppThemeStyle themeStyleFromString(String? value) {
  if (value == 'mornye') return AppThemeStyle.mosix;
  return AppThemeStyle.values.firstWhere(
    (style) => style.name == value,
    orElse: defaultAppThemeStyle,
  );
}

/// Default Spotify green color for fallback
const int kDefaultSeedColor = 0xFF1DB954;

class ThemeSettings {
  final ThemeMode themeMode;
  final bool useDynamicColor;
  final int seedColorValue;
  final bool useAmoled;
  final AppThemeStyle style;
  final MosixAccent mosixAccent;
  final bool useSystemFont;
  final String customFontId;
  final String customFontName;
  final double lyricsTextScale;
  final double mosixGlassClarity;
  final bool mosixGlassOutlines;

  const ThemeSettings({
    this.themeMode = ThemeMode.system,
    this.useDynamicColor = true,
    this.seedColorValue = kDefaultSeedColor,
    this.useAmoled = false,
    this.style = AppThemeStyle.material,
    this.mosixAccent = MosixAccent.red,
    this.useSystemFont = false,
    this.customFontId = '',
    this.customFontName = '',
    this.lyricsTextScale = 1,
    this.mosixGlassClarity = kDefaultMosixGlassClarity,
    this.mosixGlassOutlines = true,
  });

  Color get seedColor => Color(seedColorValue);

  ThemeSettings copyWith({
    ThemeMode? themeMode,
    bool? useDynamicColor,
    int? seedColorValue,
    bool? useAmoled,
    AppThemeStyle? style,
    MosixAccent? mosixAccent,
    bool? useSystemFont,
    String? customFontId,
    String? customFontName,
    double? lyricsTextScale,
    double? mosixGlassClarity,
    bool? mosixGlassOutlines,
  }) {
    return ThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      useDynamicColor: useDynamicColor ?? this.useDynamicColor,
      seedColorValue: seedColorValue ?? this.seedColorValue,
      useAmoled: useAmoled ?? this.useAmoled,
      style: style ?? this.style,
      mosixAccent: mosixAccent ?? this.mosixAccent,
      useSystemFont: useSystemFont ?? this.useSystemFont,
      customFontId: customFontId ?? this.customFontId,
      customFontName: customFontName ?? this.customFontName,
      lyricsTextScale: normalizeLyricsTextScale(
        lyricsTextScale ?? this.lyricsTextScale,
      ),
      mosixGlassClarity: normalizeMosixGlassClarity(
        mosixGlassClarity ?? this.mosixGlassClarity,
      ),
      mosixGlassOutlines: mosixGlassOutlines ?? this.mosixGlassOutlines,
    );
  }

  Map<String, dynamic> toJson() => {
    kThemeModeKey: themeMode.name,
    kUseDynamicColorKey: useDynamicColor,
    kSeedColorKey: seedColorValue,
    kUseAmoledKey: useAmoled,
    kThemeStyleKey: style.name,
    kMosixAccentKey: mosixAccent.name,
    kUseSystemFontKey: useSystemFont,
    kCustomFontIdKey: customFontId,
    kCustomFontNameKey: customFontName,
    kLyricsTextScaleKey: lyricsTextScale,
    kMosixGlassClarityKey: mosixGlassClarity,
    kMosixGlassOutlinesKey: mosixGlassOutlines,
  };

  factory ThemeSettings.fromJson(Map<String, dynamic> json) {
    return ThemeSettings(
      themeMode: themeModeFromString(json[kThemeModeKey] as String?),
      useDynamicColor: json[kUseDynamicColorKey] as bool? ?? true,
      seedColorValue: json[kSeedColorKey] as int? ?? kDefaultSeedColor,
      useAmoled: json[kUseAmoledKey] as bool? ?? false,
      style: themeStyleFromString(json[kThemeStyleKey] as String?),
      mosixAccent: mosixAccentFromString(
        (json[kMosixAccentKey] ?? json[kLegacyMosixAccentKey]) as String?,
      ),
      useSystemFont: json[kUseSystemFontKey] as bool? ?? false,
      customFontId: json[kCustomFontIdKey] as String? ?? '',
      customFontName: json[kCustomFontNameKey] as String? ?? '',
      lyricsTextScale: normalizeLyricsTextScale(
        json[kLyricsTextScaleKey] as num?,
      ),
      mosixGlassClarity: normalizeMosixGlassClarity(
        (json[kMosixGlassClarityKey] ?? json[kLegacyMosixGlassClarityKey])
            as num?,
      ),
      mosixGlassOutlines:
          (json[kMosixGlassOutlinesKey] ?? json[kLegacyMosixGlassOutlinesKey])
              as bool? ??
          true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ThemeSettings &&
        other.themeMode == themeMode &&
        other.useDynamicColor == useDynamicColor &&
        other.seedColorValue == seedColorValue &&
        other.useAmoled == useAmoled &&
        other.style == style &&
        other.mosixAccent == mosixAccent &&
        other.useSystemFont == useSystemFont &&
        other.customFontId == customFontId &&
        other.customFontName == customFontName &&
        other.lyricsTextScale == lyricsTextScale &&
        other.mosixGlassClarity == mosixGlassClarity &&
        other.mosixGlassOutlines == mosixGlassOutlines;
  }

  @override
  int get hashCode =>
      themeMode.hashCode ^
      useDynamicColor.hashCode ^
      seedColorValue.hashCode ^
      useAmoled.hashCode ^
      style.hashCode ^
      mosixAccent.hashCode ^
      useSystemFont.hashCode ^
      customFontId.hashCode ^
      customFontName.hashCode ^
      lyricsTextScale.hashCode ^
      mosixGlassClarity.hashCode ^
      mosixGlassOutlines.hashCode;
}

ThemeMode themeModeFromString(String? value) {
  if (value == null) return ThemeMode.system;
  return ThemeMode.values.firstWhere(
    (e) => e.name == value,
    orElse: () => ThemeMode.system,
  );
}
